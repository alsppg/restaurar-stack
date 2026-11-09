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
    [switch]$Limpar,
    [switch]$Drivers,
    [switch]$SomenteDrivers,
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

$MsiLogDir   = Join-Path $BaseDir 'msi-logs'

New-Item -ItemType Directory -Force -Path $BaseDir, $DownloadDir, $MsiLogDir | Out-Null

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
        $argsShow = @('show', '--id', $a.winget, '--exact', '--disable-interactivity')
        if ($a.PSObject.Properties.Name -contains 'origem' -and $a.origem) {
            $argsShow += @('--source', $a.origem)
        }
        & winget @argsShow 1>$null 2>$null
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


# ============================================================ remover bloatware
function Get-ChavesDesinstalacao {
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
                $props = $it.PSObject.Properties.Name
                # Valores calculados antes: o PS 5.1 nao aceita "if" na posicao
                # de valor de um literal de hashtable.
                $ver = ''
                if ($props -contains 'DisplayVersion')       { $ver = [string]$it.DisplayVersion }
                $cmd = ''
                if ($props -contains 'UninstallString')      { $cmd = [string]$it.UninstallString }
                $qui = ''
                if ($props -contains 'QuietUninstallString') { $qui = [string]$it.QuietUninstallString }
                [void]$lista.Add([pscustomobject]@{
                    Nome       = [string]$it.DisplayName
                    Versao     = $ver
                    Codigo     = [string]$it.PSChildName
                    Comando    = $cmd
                    Silencioso = $qui
                })
            }
        } catch { }
    }
    return $lista
}

function Find-Bloatware {
    <# Devolve so o que realmente existe nesta maquina. #>
    param($Definicoes)

    $chaves    = Get-ChavesDesinstalacao
    $achados   = New-Object Collections.ArrayList
    $temAppx   = [bool](Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)

    foreach ($def in $Definicoes) {
        foreach ($padrao in $def.registro) {
            foreach ($k in $chaves) {
                if ($k.Nome -like $padrao) {
                    [void]$achados.Add([pscustomobject]@{
                        Id = $def.id; Nome = $k.Nome; Versao = $k.Versao
                        Tipo = 'registro'; Codigo = $k.Codigo
                        Comando = $k.Comando; Silencioso = $k.Silencioso
                    })
                }
            }
        }
        if ($temAppx -and $def.appx) {
            foreach ($nomeAppx in $def.appx) {
                try {
                    $pacotes = Get-AppxPackage -Name $nomeAppx -ErrorAction SilentlyContinue
                    foreach ($pk in $pacotes) {
                        [void]$achados.Add([pscustomobject]@{
                            Id = $def.id; Nome = "$($pk.Name) (app da Store)"; Versao = [string]$pk.Version
                            Tipo = 'appx'; Codigo = [string]$pk.PackageFullName
                            Comando = ''; Silencioso = ''
                        })
                    }
                } catch { }
            }
        }
    }
    return $achados
}

function Remove-ItemBloat {
    param([Parameter(Mandatory)]$Item)

    if ($Item.Tipo -eq 'appx') {
        Remove-AppxPackage -Package $Item.Codigo -ErrorAction Stop
        return
    }

    # MSI: converter /I{GUID} em /X{GUID} silencioso.
    if ($Item.Codigo -match '^\{[0-9A-Fa-f-]{36}\}$' -or $Item.Comando -match 'msiexec') {
        $guid = $null
        if ($Item.Codigo -match '^\{[0-9A-Fa-f-]{36}\}$') { $guid = $Item.Codigo }
        elseif ($Item.Comando -match '(\{[0-9A-Fa-f-]{36}\})') { $guid = $Matches[1] }

        if ($guid) {
            $tentativa = 0
            $p = $null
            while ($tentativa -lt 12) {
                $tentativa++
                $p = Start-Process -FilePath 'msiexec.exe' `
                                   -ArgumentList @('/x', $guid, '/qn', '/norestart') `
                                   -Wait -PassThru
                if ($p.ExitCode -ne 1618) { break }
                Write-Log ("{0}: Windows Installer ocupado; nova tentativa em 15s ({1}/12)" -f $Item.Nome, $tentativa) 'AVISO'
                Start-Sleep -Seconds 15
            }
            # 1605 = o produto nao esta instalado; ja era o que queriamos.
            if ($p.ExitCode -notin @(0, 1605, 3010)) {
                throw "msiexec /x terminou com codigo $($p.ExitCode)"
            }
            return
        }
    }

    if ($Item.Silencioso) {
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $Item.Silencioso) -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "desinstalador terminou com codigo $($p.ExitCode)" }
        return
    }

    throw 'nao ha desinstalacao silenciosa publicada; remova por Aplicativos e Recursos'
}

function Show-JanelaLimpeza {
    param([Parameter(Mandatory)]$Achados)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $script:formL = New-Object Windows.Forms.Form
    $f = $script:formL
    $f.Text          = 'Remover programas'
    $f.Size          = New-Object Drawing.Size(560, 460)
    $f.StartPosition = 'CenterScreen'

    $cab          = New-Object Windows.Forms.Label
    $cab.Text     = "Encontrados nesta maquina. Marque o que remover - tudo comeca desmarcado."
    $cab.Dock     = 'Top'
    $cab.Height   = 34
    $cab.Padding  = New-Object Windows.Forms.Padding(12, 10, 12, 0)
    $f.Controls.Add($cab)

    $painel            = New-Object Windows.Forms.Panel
    $painel.Dock       = 'Fill'
    $painel.AutoScroll = $true
    $painel.Padding    = New-Object Windows.Forms.Padding(12, 4, 12, 4)
    $f.Controls.Add($painel)
    $painel.BringToFront()

    $rodape        = New-Object Windows.Forms.FlowLayoutPanel
    $rodape.Dock   = 'Bottom'
    $rodape.Height = 52
    $rodape.Padding= New-Object Windows.Forms.Padding(10, 10, 10, 10)
    $f.Controls.Add($rodape)

    $script:caixasL = New-Object Collections.ArrayList
    $y = 6
    foreach ($a in $Achados) {
        $cb          = New-Object Windows.Forms.CheckBox
        $v = if ($a.Versao) { " $($a.Versao)" } else { '' }
        $cb.Text     = '{0}{1}' -f $a.Nome, $v
        $cb.AutoSize = $true
        $cb.Checked  = $false
        $cb.Location = New-Object Drawing.Point(16, $y)
        $cb.Tag      = $a
        $painel.Controls.Add($cb)
        [void]$script:caixasL.Add($cb)
        $y += 24
    }

    $btTodos = New-Object Windows.Forms.Button; $btTodos.Text = 'Marcar todos'; $btTodos.Width = 110; $btTodos.Height = 30
    $btNada  = New-Object Windows.Forms.Button; $btNada.Text  = 'Desmarcar todos'; $btNada.Width = 125; $btNada.Height = 30
    $btOk    = New-Object Windows.Forms.Button; $btOk.Text    = 'Remover'; $btOk.Width = 110; $btOk.Height = 30
    $btSair  = New-Object Windows.Forms.Button; $btSair.Text  = 'Cancelar'; $btSair.Width = 90; $btSair.Height = 30

    $btTodos.Add_Click({ foreach ($c in $script:caixasL) { $c.Checked = $true  } })
    $btNada.Add_Click({  foreach ($c in $script:caixasL) { $c.Checked = $false } })

    $script:confirmadoL = $false
    $btOk.Add_Click({ $script:confirmadoL = $true; $script:formL.Close() })
    $btSair.Add_Click({ $script:confirmadoL = $false; $script:formL.Close() })

    $rodape.Controls.AddRange(@($btTodos, $btNada, $btOk, $btSair))
    $f.CancelButton = $btSair
    [void]$f.ShowDialog()

    if (-not $script:confirmadoL) { return @() }
    return @($script:caixasL | Where-Object { $_.Checked } | ForEach-Object { $_.Tag })
}

if ($Limpar) {
    if (-not ($cat.PSObject.Properties.Name -contains 'remover') -or -not $cat.remover) {
        throw 'o catalogo nao tem a secao "remover"'
    }

    Write-Host 'Procurando os programas da lista de remocao nesta maquina...'
    $achados = @(Find-Bloatware -Definicoes $cat.remover)

    if ($achados.Count -eq 0) {
        Write-Host 'Nenhum deles esta instalado. Nada a fazer.' -ForegroundColor Green
        return
    }

    $escolhidos = @(Show-JanelaLimpeza -Achados $achados)
    if ($escolhidos.Count -eq 0) { Write-Host 'Nada selecionado. Nenhuma alteracao feita.'; return }

    Add-Type -AssemblyName System.Windows.Forms
    $texto = "Isto vai DESINSTALAR da maquina:`n`n" +
             (($escolhidos | ForEach-Object { " - $($_.Nome)" }) -join "`n") +
             "`n`nConfirma?"
    $r = [Windows.Forms.MessageBox]::Show($texto, 'Confirmar remocao',
         [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -ne [Windows.Forms.DialogResult]::Yes) { Write-Host 'Cancelado.'; return }

    $okR = 0; $falhasR = @()
    foreach ($item in $escolhidos) {
        Write-Host ''
        Write-Log "removendo $($item.Nome)"
        try { Remove-ItemBloat -Item $item; $okR++; Write-Log "$($item.Nome): removido" }
        catch {
            $falhasR += ('{0} ({1})' -f $item.Nome, $_.Exception.Message)
            Write-Log "$($item.Nome): FALHOU - $($_.Exception.Message)" ERRO
        }
    }

    Write-Host ''
    Write-Host '================ resumo ================'
    Write-Host ("removidos : {0}" -f $okR)
    if ($falhasR.Count) {
        Write-Host ("falharam  : {0}" -f $falhasR.Count) -ForegroundColor Red
        foreach ($x in $falhasR) { Write-Host "  - $x" -ForegroundColor Red }
    }
    Write-Host ("log       : {0}" -f $LogFile)
    Write-Log "Limpeza - removidos=$okR falhas=$($falhasR.Count)"
    return
}


# ================================================= drivers pelo Windows Update
function Test-Administrador {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-DriversWindowsUpdate {
    <#
      Usa a API do Windows Update Agent, filtrando so drivers. Nada de pacote
      de terceiro: os drivers vem assinados e homologados pela Microsoft
      (WHQL), enviados pelos proprios fabricantes. Exige elevacao - sem ela a
      chamada falha com HRESULT 0x80240044.
    #>
    if (-not (Test-Administrador)) {
        throw 'a instalacao de drivers exige PowerShell como administrador'
    }

    Write-Log 'procurando drivers aplicaveis a esta maquina...'

    $sessao   = New-Object -ComObject Microsoft.Update.Session
    $buscador = $sessao.CreateUpdateSearcher()
    $buscador.ServerSelection = 1        # ssWindowsUpdate, nao WSUS da empresa
    $achado   = $buscador.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")

    if ($achado.Updates.Count -eq 0) {
        Write-Log 'nenhum driver pendente; o sistema ja esta com os drivers que a Microsoft oferece'
        return
    }

    Write-Host ''
    Write-Host ("Drivers encontrados ({0}):" -f $achado.Updates.Count) -ForegroundColor Cyan
    $colecao = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $achado.Updates) {
        Write-Host ("  - {0}" -f $u.Title)
        if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch { } }
        [void]$colecao.Add($u)
    }

    Write-Host ''
    Write-Log 'baixando...'
    $baixador = $sessao.CreateUpdateDownloader()
    $baixador.Updates = $colecao
    [void]$baixador.Download()

    $prontos = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $achado.Updates) { if ($u.IsDownloaded) { [void]$prontos.Add($u) } }

    if ($prontos.Count -eq 0) {
        Write-Log 'nenhum driver pode ser baixado' ERRO
        return
    }

    Write-Log ("instalando {0} driver(es)..." -f $prontos.Count)
    $instalador = $sessao.CreateUpdateInstaller()
    $instalador.Updates = $prontos
    $r = $instalador.Install()

    # 2 = concluido, 3 = concluido com erros, 4 = falhou, 5 = cancelado
    switch ($r.ResultCode) {
        2 { Write-Log ("drivers instalados: {0}" -f $prontos.Count) }
        3 { Write-Log 'drivers instalados, com erros em alguns itens' AVISO }
        default { Write-Log ("a instalacao de drivers terminou com codigo {0}" -f $r.ResultCode) ERRO }
    }
    if ($r.RebootRequired) {
        Write-Log 'e preciso reiniciar o computador para concluir' AVISO
    }
}

if ($SomenteDrivers) {
    try { Install-DriversWindowsUpdate }
    catch { Write-Log "drivers: FALHOU - $($_.Exception.Message)" ERRO }
    Write-Host ''
    Write-Host 'Pressione Enter para fechar.'
    [void](Read-Host)
    return
}

if ($Drivers) {
    if (Test-Administrador) {
        try { Install-DriversWindowsUpdate }
        catch { Write-Log "drivers: FALHOU - $($_.Exception.Message)" ERRO }
    }
    else {
        Write-Log 'abrindo uma janela elevada so para os drivers (o UAC vai perguntar)'
        $caminho = $MyInvocation.MyCommand.Path
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$caminho`"", '-SomenteDrivers')
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

function Get-CausaDoLogMsi {
    <#
      O codigo 1603 e generico. A causa fica no log verboso: a acao que
      retornou 3 e a linha de "Error status". Devolve as linhas uteis.
    #>
    param([string]$Caminho)
    if (-not (Test-Path -LiteralPath $Caminho)) { return @() }
    try {
        $linhas = Get-Content -LiteralPath $Caminho -Tail 4000 -ErrorAction Stop
    } catch { return @() }

    $uteis = $linhas | Where-Object {
        $_ -match 'Error status:' -or
        $_ -match 'Product: .*Error' -or
        $_ -match 'Installation failed' -or
        $_ -match 'returned actual error' -or
        $_ -match 'MainEngineThread is returning' -or
        $_ -match 'Error 1[0-9]{3}\.' -or
        $_ -match 'cannot install.*higher version' -or
        $_ -match 'Another version of this product is already installed'
    }
    return @($uteis | Select-Object -Last 6)
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
    $logMsi = Join-Path $MsiLogDir ('{0}.log' -f [IO.Path]::GetFileNameWithoutExtension($asset.Nome))
    $argsBase = @('/i', "`"$destino`"", '/norestart', '/l*v', "`"$logMsi`"")

    $maxTentativas = 12
    $tentativa     = 0
    $p             = $null
    $modo          = '/qn'

    while ($tentativa -lt $maxTentativas) {
        $tentativa++
        $p = Start-Process -FilePath 'msiexec.exe' `
                           -ArgumentList ($argsBase + @($modo)) `
                           -Wait -PassThru

        if ($p.ExitCode -eq 1618) {
            if ($tentativa -lt $maxTentativas) {
                Write-Log ("{0}: Windows Installer ocupado; nova tentativa em 15s ({1}/{2})" -f $App.nome, $tentativa, $maxTentativas) 'AVISO'
                Start-Sleep -Seconds 15
            }
            continue
        }

        # 1603 totalmente silencioso pode ser so falta de interface para um
        # prompt que o pacote precisa mostrar. Vale uma tentativa com /qb.
        if ($p.ExitCode -eq 1603 -and $modo -eq '/qn') {
            Write-Log "$($App.nome): codigo 1603 em modo silencioso; repetindo com interface basica" 'AVISO'
            $modo = '/qb'
            continue
        }

        break
    }

    # 3010 = instalado, pede reinicio.
    if ($p.ExitCode -eq 1618) {
        throw "Windows Installer seguiu ocupado apos $maxTentativas tentativas (codigo 1618). Feche outras instalacoes ou o Windows Update e rode de novo."
    }
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        $causa = Get-CausaDoLogMsi -Caminho $logMsi
        foreach ($c in $causa) { Write-Log ("  msi: {0}" -f $c.Trim()) 'AVISO' }
        $extra = ''
        if ($causa.Count -eq 0) { $extra = " Log completo em $logMsi" }
        throw "msiexec terminou com codigo $($p.ExitCode).$extra"
    }
    Remove-Item -LiteralPath $destino -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -eq 3010) { Write-Log "$($App.nome): instalado (pede reinicio)" 'AVISO' }
}

function Install-AppWinget {
    param([Parameter(Mandatory)]$App)

    if (-not $App.winget) { throw "sem pacote winget definido no catalogo" }

    $argumentos = @('install', '--id', $App.winget, '--exact', '--silent',
                    '--accept-package-agreements', '--accept-source-agreements',
                    '--disable-interactivity')
    # Alguns pacotes so existem na Microsoft Store e exigem a fonte explicita.
    if ($App.PSObject.Properties.Name -contains 'origem' -and $App.origem) {
        $argumentos += @('--source', $App.origem)
    }
    $saida = & winget @argumentos 2>&1
    $codigo = $LASTEXITCODE

    # 0x8A150061 = ja instalado; 0x8A15002B = nenhuma atualizacao aplicavel.
    $jaInstalado = @(-1978335135, -1978335189)
    # -1978335212 = APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND: o id nao
    # existe no winget. Erro de catalogo, nao da maquina.
    if ($codigo -eq -1978335212) {
        throw "o id '$($App.winget)' nao existe no winget. Procure o certo com: winget search ""$($App.nome)"""
    }
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

function Get-IdsWingetInstalados {
    <#
      Pergunta ao winget o que esta instalado, em vez de adivinhar pelo nome no
      registro. O "winget export" sai em JSON e cobre tanto programa classico
      quanto app da Microsoft Store. Uma chamada so para todos os apps.
    #>
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return @() }

    $tmp = Join-Path $BaseDir 'winget-export.json'
    $ids = New-Object Collections.ArrayList
    try {
        & winget export --output $tmp --include-versions `
                        --accept-source-agreements --disable-interactivity 1>$null 2>$null
        if (-not (Test-Path -LiteralPath $tmp)) { return @() }

        $j = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($src in $j.Sources) {
            foreach ($pk in $src.Packages) {
                $nomesProp = $pk.PSObject.Properties.Name
                if ($nomesProp -notcontains 'PackageIdentifier') { continue }
                $v = ''
                if ($nomesProp -contains 'Version') { $v = [string]$pk.Version }
                [void]$ids.Add([pscustomobject]@{
                    Id     = [string]$pk.PackageIdentifier
                    Versao = $v
                })
            }
        }
    } catch { }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    return $ids
}

function Find-VersaoPorIdWinget {
    param($IdsInstalados, [string]$Id)
    if (-not $Id) { return $null }
    foreach ($i in $IdsInstalados) {
        if ($i.Id -and $i.Id.ToLowerInvariant() -eq $Id.ToLowerInvariant()) {
            if ($i.Versao) { return $i.Versao }
            return 'instalado'
        }
    }
    return $null
}

function Find-VersaoAppx {
    <#
      Terceira via de deteccao: app da Microsoft Store nao cria chave de
      desinstalacao no registro, e so aparece no "winget export" se a fonte
      msstore estiver configurada na maquina. Get-AppxPackage sempre ve.
    #>
    param($App)
    if ($App.PSObject.Properties.Name -notcontains 'appx' -or -not $App.appx) { return $null }
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { return $null }
    foreach ($nomeAppx in $App.appx) {
        try {
            $pk = Get-AppxPackage -Name $nomeAppx -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pk) {
                if ($pk.Version) { return [string]$pk.Version }
                return 'instalado'
            }
        } catch { }
    }
    return $null
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

    $inv      = Get-InventarioInstalado
    $idsWinget = Get-IdsWingetInstalados
    $total    = @($Apps).Count
    $n        = 0

    foreach ($a in $Apps) {
        $n++
        Write-Progress -Activity 'Verificando versoes disponiveis' `
                       -Status "$($a.nome) ($n de $total)" `
                       -PercentComplete ([int](100 * $n / $total))

        # Para app de gerenciador, a resposta do winget vale mais que o nome no
        # registro: cobre app da Store e nao depende de o nome bater.
        $instalada = $null
        if ($a.fonte -eq 'gerenciador' -and $a.winget) {
            $instalada = Find-VersaoPorIdWinget -IdsInstalados $idsWinget -Id $a.winget
        }
        if (-not $instalada) {
            $instalada = Find-VersaoAppx -App $a
        }
        if (-not $instalada) {
            # O nome no registro nem sempre e o do catalogo (uTorrent se
            # registra com mu grego; o VS Code, como "Microsoft Visual
            # Studio Code"). O campo "nomes" lista as variantes conhecidas.
            $candidatos = @($a.nome)
            if ($a.PSObject.Properties.Name -contains 'nomes' -and $a.nomes) {
                $candidatos = @($a.nomes) + $candidatos
            }
            foreach ($cand in $candidatos) {
                $instalada = Find-VersaoInstalada -Inventario $inv -Nome $cand
                if ($instalada) { break }
            }
        }

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
        elseif ($a.fonte -eq 'manual') {
            if ($instalada) { $estado = "instalado ($instalada)";  $marcar = $false }
            else            { $estado = 'instalar manualmente';    $marcar = $true }
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

    # Extra: drivers. Comeca desmarcado - exige elevacao e mexe no sistema.
    $tituloExtra          = New-Object Windows.Forms.Label
    $tituloExtra.Text     = 'Extras'
    $tituloExtra.Font     = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Bold)
    $tituloExtra.AutoSize = $true
    $tituloExtra.Location = New-Object Drawing.Point(4, $y)
    $painel.Controls.Add($tituloExtra)
    $y += 26

    $script:cbDrivers          = New-Object Windows.Forms.CheckBox
    $script:cbDrivers.Text     = 'Instalar / atualizar drivers tambem (Windows Update, pede administrador)'
    $script:cbDrivers.AutoSize = $true
    $script:cbDrivers.Checked  = $false
    $script:cbDrivers.Location = New-Object Drawing.Point(20, $y)
    $painel.Controls.Add($script:cbDrivers)
    $y += 28

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

    if (-not $script:confirmado) { $script:marcarDrivers = $false; return @() }
    $script:marcarDrivers = [bool]$script:cbDrivers.Checked
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
    $script:marcarDrivers = $false
    Write-Host 'Verificando versoes disponiveis e o que ja esta instalado...'
    Invoke-VarreduraAtualizacoes -Apps $TodosApps
    $selecionados = @(Show-JanelaSelecao -Grupos $cat.grupos)
}

$querDrivers = $false
if (Get-Variable -Name 'marcarDrivers' -Scope Script -ErrorAction SilentlyContinue) {
    $querDrivers = [bool]$script:marcarDrivers
}

if ((-not $selecionados -or $selecionados.Count -eq 0) -and -not $querDrivers) {
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
$ok = @(); $falhou = @(); $pulou = @(); $manuais = @()
$i = 0

foreach ($app in $selecionados) {
    $i++
    Write-Host ''
    Write-Log ("[{0}/{1}] {2}" -f $i, $selecionados.Count, $app.nome)
    try {
        switch ($app.fonte) {
            'artcraft'    { Install-AppArtCraft -App $app; $ok += $app.nome }
            'manual' {
                $manuais += $app
                Write-Log "$($app.nome): sem pacote em gerenciador; instalacao manual" 'AVISO'
            }
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
if ($manuais.Count) {
    Write-Host ''
    Write-Host 'Instale estes na mao (nao existem em gerenciador de pacotes):' -ForegroundColor Yellow
    foreach ($m in $manuais) {
        $endereco = ''
        if ($m.PSObject.Properties.Name -contains 'url' -and $m.url) { $endereco = "  $($m.url)" }
        Write-Host ("  - {0}{1}" -f $m.nome, $endereco)
    }
}
if ($falhou.Count) {
    Write-Host ("falharam   : {0}" -f $falhou.Count) -ForegroundColor Red
    foreach ($f in $falhou) { Write-Host "  - $f" -ForegroundColor Red }
}
Write-Host ("log        : {0}" -f $LogFile)
Write-Log "Fim - ok=$($ok.Count) falhas=$($falhou.Count) pulados=$($pulou.Count)"

if ($querDrivers) {
    Write-Host ''
    Write-Host '================ drivers ================'
    if (Test-Administrador) {
        try { Install-DriversWindowsUpdate }
        catch { Write-Log "drivers: FALHOU - $($_.Exception.Message)" ERRO }
    }
    else {
        Write-Log 'abrindo uma janela elevada so para os drivers (o UAC vai perguntar)'
        $caminho = $MyInvocation.MyCommand.Path
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$caminho`"", '-SomenteDrivers')
    }
}

if ($falhou.Count) { exit 1 }
