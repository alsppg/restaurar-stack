<#
    Restaurar-Stack.ps1
    Reinstala a stack de programas apos formatar/restaurar o Windows.

    Apps do ArtCraft: baixados direto do GitHub Releases e conferidos
    contra o SHA-256 publicado antes de instalar.
    Demais apps: instalados pelo winget, que faz a propria verificacao.

    Uso:
      .\Restaurar-Stack.ps1              -> abre a janela de selecao
      .\Restaurar-Stack.ps1 -Tudo        -> instala tudo, sem janela
      .\Restaurar-Stack.ps1 -Apenas a,b  -> instala so esses ids
      .\Restaurar-Stack.ps1 -Listar      -> so lista o catalogo e sai
#>

[CmdletBinding()]
param(
    [switch]$Tudo,
    [string[]]$Apenas,
    [switch]$Listar,
    [switch]$VerificarIds,
    [string]$Catalogo
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# TLS moderno; algumas instalacoes antigas ainda negociam TLS 1.0 por padrao.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# ---------------------------------------------------------------- pastas e log
# Tudo fora de qualquer pasta publicada: perfil local do usuario.
$BaseDir     = Join-Path $env:LOCALAPPDATA 'RestaurarStack'
$DownloadDir = Join-Path $BaseDir 'downloads'
$LogFile     = Join-Path $BaseDir 'restaurar-stack.log'
$MaxLogBytes = 1MB

New-Item -ItemType Directory -Force -Path $BaseDir, $DownloadDir | Out-Null

function Write-Log {
    param([string]$Mensagem, [ValidateSet('INFO','AVISO','ERRO')][string]$Nivel = 'INFO')
    $linha = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Mensagem)
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt $MaxLogBytes)) {
            Move-Item $LogFile "$LogFile.1" -Force
        }
        Add-Content -Path $LogFile -Value $linha -Encoding UTF8
    } catch { }
    switch ($Nivel) {
        'ERRO'  { Write-Host $linha -ForegroundColor Red }
        'AVISO' { Write-Host $linha -ForegroundColor Yellow }
        default { Write-Host $linha }
    }
}

# ------------------------------------------------------------------- catalogo
if (-not $Catalogo) {
    $raiz = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $Catalogo = Join-Path $raiz 'catalog.json'
}
if (-not (Test-Path -LiteralPath $Catalogo)) {
    throw "Catalogo nao encontrado: $Catalogo"
}
$cat = Get-Content -LiteralPath $Catalogo -Raw -Encoding UTF8 | ConvertFrom-Json

$TodosApps = foreach ($g in $cat.grupos) {
    foreach ($a in $g.apps) {
        $a | Add-Member -NotePropertyName grupoNome -NotePropertyValue $g.nome -Force -PassThru
    }
}

if ($Listar) {
    foreach ($g in $cat.grupos) {
        Write-Host "`n$($g.nome)" -ForegroundColor Cyan
        foreach ($a in $g.apps) {
            $eq = if ($a.PSObject.Properties.Name -contains 'equivale' -and $a.equivale) { " ($($a.equivale))" } else { '' }
            '  {0,-20} {1}{2}' -f $a.id, $a.nome, $eq
        }
    }
    return
}

if ($VerificarIds) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget nao encontrado; instale o "Instalador de Aplicativo" pela Microsoft Store.'
    }
    $alvos = @($TodosApps | Where-Object { $_.fonte -eq 'gerenciador' })
    $maus  = @()
    $n = 0
    foreach ($a in $alvos) {
        $n++
        Write-Progress -Activity 'Conferindo ids do winget' -Status $a.nome -PercentComplete ([int](100 * $n / $alvos.Count))
        & winget show --id $a.winget --exact --disable-interactivity 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) {
            '{0,-12} {1,-34} ok'      -f $a.id, $a.winget
        } else {
            '{0,-12} {1,-34} NAO EXISTE' -f $a.id, $a.winget
            $maus += $a
        }
    }
    Write-Progress -Activity 'Conferindo ids do winget' -Completed
    Write-Host ''
    if ($maus.Count) {
        Write-Host ("{0} id(s) invalido(s). Procure o certo com:" -f $maus.Count) -ForegroundColor Yellow
        foreach ($m in $maus) { Write-Host ("  winget search ""{0}""" -f $m.nome) }
    } else {
        Write-Host 'Todos os ids do catalogo existem no winget.' -ForegroundColor Green
    }
    return
}

# ---------------------------------------------------------------- arquitetura
function Get-ArquiteturaWindows {
    $a = $env:PROCESSOR_ARCHITECTURE
    if (-not $a) { $a = 'AMD64' }
    switch ($a.ToUpperInvariant()) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        'X86'   { if ($env:PROCESSOR_ARCHITEW6432) { 'x64' } else { 'x86' } }
        default { 'x64' }
    }
}
$Arch = Get-ArquiteturaWindows

# ------------------------------------------------- resolucao do asset ArtCraft
$script:CacheAsset = @{}

function Get-VersaoDoArquivo {
    param([string]$Nome)
    if ($Nome -match '-(\d+(?:\.\d+)+)-windows-') { return $Matches[1] }
    return ''
}

function Resolve-AssetArtCraft {
    <#
      Le o SHA256SUMS.txt da release mais recente e devolve nome do arquivo,
      hash esperado e URL de download. Sem versao fixa, sem cota de API.
    #>
    param([Parameter(Mandatory)][string]$Repo,
          [Parameter(Mandatory)][string]$Arquitetura,
          [string]$PrefixoArquivo)

    if ($script:CacheAsset.ContainsKey($Repo)) { return $script:CacheAsset[$Repo] }

    $base  = "https://github.com/storytold/$Repo/releases/latest/download"
    $sums  = Invoke-WebRequest -Uri "$base/SHA256SUMS.txt" -UseBasicParsing -TimeoutSec 60
    $bruto = $sums.Content
    # PowerShell 5.1 entrega texto como String; o 7 pode entregar byte[].
    $texto = if ($bruto -is [byte[]]) { [Text.Encoding]::UTF8.GetString($bruto) } else { [string]$bruto }

    $prefixo = if ($PrefixoArquivo) { $PrefixoArquivo } else { $Repo }
    $alvo    = $null

    foreach ($linha in ($texto -split "`r?`n")) {
        if ($linha -notmatch '^([0-9a-fA-F]{64})\s+(\S+)$') { continue }
        $hash = $Matches[1].ToLowerInvariant()
        $nome = $Matches[2]

        # Nome tem de ser um nome de arquivo simples: barra, ".." ou caractere
        # estranho vindo do arquivo de hashes nao vira caminho no disco.
        if ($nome -notmatch '^[A-Za-z0-9._-]+$') { continue }
        if ($nome -ne [IO.Path]::GetFileName($nome)) { continue }
        if ($nome -notlike "$prefixo-*")            { continue }
        if ($nome -notlike "*-windows-$Arquitetura.msi") { continue }

        $alvo = [pscustomobject]@{
            Nome   = $nome
            Hash   = $hash
            Url    = "$base/$nome"
            Versao = Get-VersaoDoArquivo $nome
        }
        break
    }

    if (-not $alvo) {
        throw "nenhum MSI para windows-$Arquitetura encontrado na release mais recente de $Repo"
    }
    $script:CacheAsset[$Repo] = $alvo
    return $alvo
}

function Install-AppArtCraft {
    param([Parameter(Mandatory)]$App)

    $prefixo = if ($App.PSObject.Properties.Name -contains 'arquivo' -and $App.arquivo) { $App.arquivo } else { $App.repo }
    $asset   = Resolve-AssetArtCraft -Repo $App.repo -Arquitetura $Arch -PrefixoArquivo $prefixo
    $destino = Join-Path $DownloadDir $asset.Nome

    Write-Log "$($App.nome): baixando $($asset.Nome)"
    Invoke-WebRequest -Uri $asset.Url -OutFile $destino -UseBasicParsing -TimeoutSec 900

    $real = (Get-FileHash -LiteralPath $destino -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($real -ne $asset.Hash) {
        Remove-Item -LiteralPath $destino -Force -ErrorAction SilentlyContinue
        throw "SHA-256 nao confere (esperado $($asset.Hash), obtido $real) - arquivo descartado"
    }
    Write-Log "$($App.nome): SHA-256 confere"

    # MSI dos apps Craft instala no perfil do usuario; nao exige admin.
    # 1618 = ERROR_INSTALL_ALREADY_RUNNING: o Windows Installer aceita uma
    # instalacao por vez e o MSI anterior ainda nao soltou o lock. Nao e erro
    # definitivo: espera e repete.
    $maxTentativas = 12
    $tentativa     = 0
    $p             = $null

    while ($tentativa -lt $maxTentativas) {
        $tentativa++
        $p = Start-Process -FilePath 'msiexec.exe' `
                           -ArgumentList @('/i', "`"$destino`"", '/qn', '/norestart') `
                           -Wait -PassThru
        if ($p.ExitCode -ne 1618) { break }
        if ($tentativa -lt $maxTentativas) {
            Write-Log ("{0}: Windows Installer ocupado; nova tentativa em 15s ({1}/{2})" -f $App.nome, $tentativa, $maxTentativas) 'AVISO'
            Start-Sleep -Seconds 15
        }
    }

    # 3010 = instalado, pede reinicio.
    if ($p.ExitCode -eq 1618) {
        throw "Windows Installer seguiu ocupado apos $maxTentativas tentativas (codigo 1618). Feche outras instalacoes ou o Windows Update e rode de novo."
    }
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw "msiexec terminou com codigo $($p.ExitCode)"
    }
    Remove-Item -LiteralPath $destino -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -eq 3010) { Write-Log "$($App.nome): instalado (pede reinicio)" 'AVISO' }
}

function Install-AppWinget {
    param([Parameter(Mandatory)]$App)

    if (-not $App.winget) { throw "sem pacote winget definido no catalogo" }

    $saida = & winget install --id $App.winget --exact --silent `
                --accept-package-agreements --accept-source-agreements `
                --disable-interactivity 2>&1
    $codigo = $LASTEXITCODE

    # 0x8A150061 = ja instalado; 0x8A15002B = nenhuma atualizacao aplicavel.
    $jaInstalado = @(-1978335135, -1978335189)
    if ($codigo -ne 0 -and $jaInstalado -notcontains $codigo) {
        throw "winget terminou com codigo $codigo : $($saida | Select-Object -Last 1)"
    }
    if ($jaInstalado -contains $codigo) { Write-Log "$($App.nome): ja estava instalado" }
}

# ------------------------------------ o que ja esta instalado nesta maquina
function Get-InventarioInstalado {
    $caminhos = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $lista = New-Object Collections.ArrayList
    foreach ($c in $caminhos) {
        try {
            $itens = Get-ItemProperty -Path $c -ErrorAction SilentlyContinue |
                     Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName }
            foreach ($it in $itens) {
                $ver = ''
                if ($it.PSObject.Properties.Name -contains 'DisplayVersion' -and $it.DisplayVersion) { $ver = [string]$it.DisplayVersion }
                [void]$lista.Add([pscustomobject]@{ Nome = [string]$it.DisplayName; Versao = $ver })
            }
        } catch { }
    }
    return $lista
}

function Find-VersaoInstalada {
    param($Inventario, [string]$Nome)
    foreach ($i in $Inventario) {
        if ($i.Nome -like "$Nome*") { return $i.Versao }
    }
    return $null
}

function Invoke-VarreduraAtualizacoes {
    <#
      Consulta a release mais recente de cada app do ArtCraft e compara com o
      que ja esta instalado. Anota 'estado' (texto da tela) e 'marcar' (se
      nasce marcado) em cada app. O resultado fica em cache: a instalacao
      depois nao refaz as mesmas requisicoes.
    #>
    param($Apps)

    $inv   = Get-InventarioInstalado
    $total = @($Apps).Count
    $n     = 0

    foreach ($a in $Apps) {
        $n++
        Write-Progress -Activity 'Verificando versoes disponiveis' `
                       -Status "$($a.nome) ($n de $total)" `
                       -PercentComplete ([int](100 * $n / $total))

        $instalada = Find-VersaoInstalada -Inventario $inv -Nome $a.nome
        $estado = ''
        $marcar = $true

        if ($a.fonte -eq 'artcraft') {
            $disponivel = $null
            try {
                $prefixo = if ($a.PSObject.Properties.Name -contains 'arquivo' -and $a.arquivo) { $a.arquivo } else { $a.repo }
                $disponivel = (Resolve-AssetArtCraft -Repo $a.repo -Arquitetura $Arch -PrefixoArquivo $prefixo).Versao
            } catch { $disponivel = $null }

            if (-not $disponivel)             { $estado = 'nao consegui verificar'; $marcar = $true }
            elseif (-not $instalada)          { $estado = "instalar $disponivel";    $marcar = $true }
            elseif ($instalada -eq $disponivel) { $estado = "em dia ($instalada)";   $marcar = $false }
            else                              { $estado = "$instalada -> $disponivel"; $marcar = $true }
        }
        else {
            if ($instalada) { $estado = "instalado ($instalada)"; $marcar = $false }
            else            { $estado = 'instalar';               $marcar = $true }
        }

        $a | Add-Member -NotePropertyName estado -NotePropertyValue $estado -Force
        $a | Add-Member -NotePropertyName marcar -NotePropertyValue $marcar -Force
    }

    Write-Progress -Activity 'Verificando versoes disponiveis' -Completed
}

# ------------------------------------------------------------- janela de selecao
function Show-JanelaSelecao {
    param([Parameter(Mandatory)]$Grupos)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $script:form          = New-Object Windows.Forms.Form
    $form                 = $script:form
    $form.Text            = 'Restaurar stack'
    $form.Size            = New-Object Drawing.Size(560, 680)
    $form.StartPosition   = 'CenterScreen'
    $form.MinimumSize     = New-Object Drawing.Size(460, 420)

    $cabecalho            = New-Object Windows.Forms.Label
    $cabecalho.Text       = "Marque o que instalar neste computador ($Arch). O que ja esta em dia vem desmarcado."
    $cabecalho.Dock       = 'Top'
    $cabecalho.Height     = 34
    $cabecalho.Padding    = New-Object Windows.Forms.Padding(12, 10, 12, 0)
    $form.Controls.Add($cabecalho)

    $painel               = New-Object Windows.Forms.Panel
    $painel.Dock          = 'Fill'
    $painel.AutoScroll    = $true
    $painel.Padding       = New-Object Windows.Forms.Padding(12, 4, 12, 4)
    $form.Controls.Add($painel)
    $painel.BringToFront()

    $rodape               = New-Object Windows.Forms.FlowLayoutPanel
    $rodape.Dock          = 'Bottom'
    $rodape.Height        = 52
    $rodape.FlowDirection = 'LeftToRight'
    $rodape.Padding       = New-Object Windows.Forms.Padding(10, 10, 10, 10)
    $form.Controls.Add($rodape)

    $script:caixas = New-Object Collections.ArrayList
    $caixas = $script:caixas
    $y = 6
    foreach ($g in $Grupos) {
        $titulo           = New-Object Windows.Forms.Label
        $titulo.Text      = $g.nome
        $titulo.Font      = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Bold)
        $titulo.AutoSize  = $true
        $titulo.Location  = New-Object Drawing.Point(4, $y)
        $painel.Controls.Add($titulo)
        $y += 26

        foreach ($a in $g.apps) {
            $cb          = New-Object Windows.Forms.CheckBox
            $rotulo      = $a.nome
            if ($a.PSObject.Properties.Name -contains 'equivale' -and $a.equivale) {
                $rotulo = '{0}  -  {1}' -f $a.nome, $a.equivale
            }
            if ($a.PSObject.Properties.Name -contains 'estado' -and $a.estado) {
                $rotulo = '{0}   [{1}]' -f $rotulo, $a.estado
            }
            $cb.Text     = $rotulo
            $cb.AutoSize = $true
            # PowerShell 5.1 nao aceita atribuir um "if" direto a uma propriedade.
            $marcado = [bool]$a.padrao
            if ($a.PSObject.Properties.Name -contains 'marcar') { $marcado = [bool]$a.marcar }
            $cb.Checked  = $marcado
            $cb.Location = New-Object Drawing.Point(20, $y)
            $cb.Tag      = $a
            $painel.Controls.Add($cb)
            [void]$caixas.Add($cb)
            $y += 24
        }
        $y += 10
    }

    function New-Botao($texto, $largura) {
        $b        = New-Object Windows.Forms.Button
        $b.Text   = $texto
        $b.Width  = $largura
        $b.Height = 30
        return $b
    }

    $btMarcar    = New-Botao 'Marcar todos'    110
    $btDesmarcar = New-Botao 'Desmarcar todos' 125
    $btInstalar  = New-Botao 'Instalar'        110
    $btCancelar  = New-Botao 'Cancelar'        90

    $btMarcar.Add_Click({    foreach ($c in $script:caixas) { $c.Checked = $true  } })
    $btDesmarcar.Add_Click({ foreach ($c in $script:caixas) { $c.Checked = $false } })

    $script:confirmado = $false
    $btInstalar.Add_Click({ $script:confirmado = $true; $script:form.Close() })
    $btCancelar.Add_Click({ $script:confirmado = $false; $script:form.Close() })

    $rodape.Controls.AddRange(@($btMarcar, $btDesmarcar, $btInstalar, $btCancelar))
    $form.AcceptButton = $btInstalar
    $form.CancelButton = $btCancelar

    [void]$form.ShowDialog()

    if (-not $script:confirmado) { return @() }
    return @($script:caixas | Where-Object { $_.Checked } | ForEach-Object { $_.Tag })
}

# ----------------------------------------------------------------- escolha dos apps
if ($Apenas) {
    $selecionados = @($TodosApps | Where-Object { $Apenas -contains $_.id })
    $faltando = @($Apenas | Where-Object { $sel = $_; -not ($TodosApps | Where-Object { $_.id -eq $sel }) })
    if ($faltando) { Write-Log "ids inexistentes no catalogo: $($faltando -join ', ')" 'AVISO' }
}
elseif ($Tudo) {
    $selecionados = @($TodosApps)
}
else {
    Write-Host 'Verificando versoes disponiveis e o que ja esta instalado...'
    Invoke-VarreduraAtualizacoes -Apps $TodosApps
    $selecionados = @(Show-JanelaSelecao -Grupos $cat.grupos)
}

if (-not $selecionados -or $selecionados.Count -eq 0) {
    Write-Host 'Nada selecionado. Nenhuma alteracao feita.'
    return
}

# ------------------------------------------------------ checagem do winget
$precisaWinget = @($selecionados | Where-Object { $_.fonte -eq 'gerenciador' }).Count -gt 0
$temWinget     = [bool](Get-Command winget -ErrorAction SilentlyContinue)
if ($precisaWinget -and -not $temWinget) {
    Write-Log 'winget nao encontrado. Instale o "Instalador de Aplicativo" pela Microsoft Store; os apps do ArtCraft seguem normalmente.' 'AVISO'
}

# ----------------------------------------------------------------- instalacao
Write-Log "Inicio - $($selecionados.Count) app(s), arquitetura $Arch"
$ok = @(); $falhou = @(); $pulou = @()
$i = 0

foreach ($app in $selecionados) {
    $i++
    Write-Host ''
    Write-Log ("[{0}/{1}] {2}" -f $i, $selecionados.Count, $app.nome)
    try {
        switch ($app.fonte) {
            'artcraft'    { Install-AppArtCraft -App $app; $ok += $app.nome }
            'gerenciador' {
                if (-not $temWinget) {
                    $pulou += $app.nome
                    Write-Log "$($app.nome): pulado (sem winget)" 'AVISO'
                }
                else {
                    Install-AppWinget -App $app
                    $ok += $app.nome
                }
            }
            default { throw "fonte desconhecida: $($app.fonte)" }
        }
    }
    catch {
        $falhou += ('{0} ({1})' -f $app.nome, $_.Exception.Message)
        Write-Log "$($app.nome): FALHOU - $($_.Exception.Message)" 'ERRO'
    }
}

Write-Host ''
Write-Host '================ resumo ================'
Write-Host ("instalados : {0}" -f $ok.Count)
if ($pulou.Count)  { Write-Host ("pulados    : {0} -> {1}" -f $pulou.Count, ($pulou -join ', ')) -ForegroundColor Yellow }
if ($falhou.Count) {
    Write-Host ("falharam   : {0}" -f $falhou.Count) -ForegroundColor Red
    foreach ($f in $falhou) { Write-Host "  - $f" -ForegroundColor Red }
}
Write-Host ("log        : {0}" -f $LogFile)
Write-Log "Fim - ok=$($ok.Count) falhas=$($falhou.Count) pulados=$($pulou.Count)"

if ($falhou.Count) { exit 1 }
