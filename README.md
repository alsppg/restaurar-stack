# Restaurar stack

Reinstala a stack de programas depois de formatar/restaurar a maquina.

## Comando unico

### Windows

Abra o PowerShell e cole isto. Instala o Git se faltar, clona ou atualiza o
repositorio e abre a tela de selecao. Serve tanto na primeira vez quanto nas
seguintes.

```powershell
$d="$env:USERPROFILE\restaurar-stack"; if(-not(Get-Command git -ErrorAction SilentlyContinue)){winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements; $env:Path+=";$env:ProgramFiles\Git\cmd"}; if(Test-Path "$d\.git"){git -C $d pull -q}else{git clone -q https://github.com/alsppg/restaurar-stack.git $d}; powershell -NoProfile -ExecutionPolicy Bypass -File "$d\Restaurar-Stack.ps1"
```

### macOS

```bash
d=~/restaurar-stack; if [ -d "$d/.git" ]; then git -C "$d" pull -q; else git clone -q https://github.com/alsppg/restaurar-stack.git "$d"; fi; bash "$d/restaurar-stack.sh"
```

Em Mac recem-formatado, `git` e `python3` vem das Command Line Tools da Apple.
Se faltarem, o script abre o instalador da Apple e pede para voce rodar o
comando de novo depois. O Homebrew tambem nao vem de fabrica: o script
pergunta se quer instalar (script oficial de brew.sh, pede sua senha). Se voce
recusar, os apps do ArtCraft instalam normalmente e os demais sao pulados.

Como o repositorio e privado, o `git clone` pede autenticacao na primeira vez
em cada maquina. Tornando o repositorio publico em Settings > Danger Zone >
Change repository visibility, o comando passa a rodar sem nenhuma interacao.

## Windows

Arquivos: `Restaurar-Stack.cmd`, `Restaurar-Stack.ps1`, `catalog.json` — os tres
na mesma pasta (pen drive, OneDrive/Drive, ou clone do repositorio).

Clique duplo em `Restaurar-Stack.cmd`.

Ele primeiro varre os repositorios para descobrir a versao disponivel de cada
app e consulta o registro do Windows para ver o que ja esta instalado. Isso
leva poucos segundos e mostra o progresso. So entao abre a janela, com o estado
de cada item ao lado do nome:

    WordCraft  -  Word        [instalar 0.16.0]
    GridCraft  -  Excel       [0.16.0 -> 0.17.0]
    PhotoCraft -  Photoshop   [em dia (0.21.0)]
    Visual Studio Code        [instalado (1.106.2)]

O que esta em dia nasce **desmarcado** — nao ha o que fazer com ele. O que
falta ou esta desatualizado nasce marcado. Os botoes **Marcar todos** /
**Desmarcar todos** continuam valendo, entao em maquina recem-formatada e um
clique so. Ao clicar em **Instalar**, baixa e instala tudo numa passada, sem
refazer as consultas que a varredura ja tinha feito.

Sem janela, para quando voce quiser deixar rodando:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\Restaurar-Stack.ps1 -Tudo

So alguns, pelo id do catalogo:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\Restaurar-Stack.ps1 -Apenas wordcraft,gridcraft,vscode

Conferir se todos os ids do winget no catalogo existem de fato:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\Restaurar-Stack.ps1 -VerificarIds

Listar o catalogo sem instalar nada:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\Restaurar-Stack.ps1 -Listar

## Como ele resolve as versoes

Nao ha numero de versao em lugar nenhum do script. Para cada app do ArtCraft
ele le `releases/latest/download/SHA256SUMS.txt` do repositorio, acha a linha do
`-windows-<arquitetura>.msi`, e monta a URL de download a partir do mesmo
caminho. Isso sempre pega a release mais recente, nao gasta cota da API do
GitHub e nao quebra quando sai versao nova.

A arquitetura e detectada sozinha (x64, arm64 ou x86).

## Seguranca

- Todo MSI do ArtCraft e conferido contra o SHA-256 publicado **antes** de
  rodar o instalador. Divergiu, o arquivo e apagado e o app e marcado como
  falha — nada e executado.
- O nome de arquivo lido do `SHA256SUMS.txt` so e aceito se casar com
  `^[A-Za-z0-9._-]+$` e nao contiver caminho, para que um nome malicioso no
  arquivo de hashes nunca vire caminho no disco.
- TLS 1.2/1.3 forcado.
- Downloads vao para `%LOCALAPPDATA%\RestaurarStack\downloads`, fora de
  qualquer pasta servida pela web, e sao apagados apos a instalacao.
- Os MSIs dos apps Craft instalam no perfil do usuario: nao pedem admin.
- Nenhum segredo, token ou credencial em lugar nenhum.
- Log em `%LOCALAPPDATA%\RestaurarStack\restaurar-stack.log`, limitado a 1 MB
  com uma rotacao, sem dado pessoal.
- `-ExecutionPolicy Bypass` vale so para aquele processo; nao altera a politica
  da maquina.
- Os apps que nao sao do ArtCraft vao pelo winget, que faz a propria
  verificacao de hash e assinatura.

## Por que nao e um .exe

Um `.exe` sem certificado de assinatura de codigo e barrado pelo SmartScreen
com "nao e comumente baixado", normalmente sem opcao visivel de continuar — ou
seja, pior que o `.ps1`, nao melhor. O que remove esse aviso e um certificado
de assinatura (centenas de dolares por ano), nao o formato do arquivo. Alem
disso, as ferramentas que empacotam PowerShell em `.exe` (PS2EXE e afins) sao
rotineiramente detectadas como malware pelos antivirus, porque e a mesma
tecnica que malware usa.

Baixar o repositorio pelo GitHub resolve o problema de distribuicao sem nada
disso.

## Editar o catalogo

`catalog.json` e a unica fonte. Cada entrada:

    { "id": "vscode", "nome": "Visual Studio Code", "fonte": "gerenciador",
      "winget": "Microsoft.VisualStudioCode", "brew": "visual-studio-code",
      "cask": true, "padrao": true }

- `fonte`: `artcraft` (GitHub + SHA-256) ou `gerenciador` (winget / Homebrew)
- `padrao`: se nasce marcado na janela
- `repo` / `arquivo`: so para `artcraft` — repositorio e prefixo do arquivo

## O que foi testado

- Os 14 repositorios do ArtCraft resolvem o MSI correto em x64 e arm64, e as
  14 URLs devolvem HTTP 200.
- Download real do `figcraft-0.16.0-windows-x64.msi` (80,8 MB): SHA-256 bateu
  com o publicado; o arquivo e um MSI valido (WiX Toolset).
- Nao foi possivel executar o script num Windows real a partir do ambiente
  onde ele foi escrito. A logica de resolucao e de verificacao foi validada
  reimplementada e rodada contra os dados reais; a camada de janela
  (WinForms) nao teve execucao de teste.

## macOS

Arquivos: `restaurar-stack.sh` e `catalog.json` na mesma pasta.

    chmod +x restaurar-stack.sh
    ./restaurar-stack.sh

Abre a janela de selecao nativa do macOS com tudo ja marcado. Cmd+clique
desmarca um item; Cmd+A marca todos de novo. OK instala a selecao.

    ./restaurar-stack.sh --tudo
    ./restaurar-stack.sh --apenas wordcraft,gridcraft,vscode
    ./restaurar-stack.sh --listar

Os apps do ArtCraft vem como DMG universal (Apple silicon e Intel no mesmo
arquivo), assinado e notarizado pela Apple. O script monta o DMG em modo
somente leitura, copia o `.app` para `/Applications` e desmonta. Sem permissao
ali, cai para `~/Applications` e avisa. A quarentena do Gatekeeper **nao** e
removida: como os DMGs sao notarizados, o sistema libera sozinho, e tirar o
atributo enfraqueceria a verificacao.

Os demais apps vao pelo Homebrew. Se o `brew` nao estiver instalado, o script
avisa, pula esses e segue com os do ArtCraft normalmente.

Log em `~/Library/Application Support/RestaurarStack/restaurar-stack.log`,
limitado a 1 MB com uma rotacao. A pasta nasce com permissao 700.

Compativel com o bash 3.2 que a Apple distribui — nao precisa de Homebrew so
para rodar o script.

### O que foi testado no macOS

- Os 14 repositorios resolvem o DMG universal correto com o mesmo `awk` do
  script, e as 14 URLs devolvem HTTP 200.
- Leitura do catalogo e `--listar`: 31 apps nos 5 grupos.
- Verificado que o script nao usa nenhuma construcao exclusiva de bash 4
  (`mapfile`, `declare -A`, `${v^^}`), que quebraria no bash 3.2 do macOS.
- `bash -n` passa.
- Nao houve execucao num macOS real: `hdiutil`, `shasum`, `osascript` e `brew`
  nao existem no ambiente onde o script foi escrito. A copia do `.app` e a
  janela do AppleScript nao tiveram execucao de teste.
