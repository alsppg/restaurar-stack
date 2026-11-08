#!/usr/bin/env bash
# restaurar-stack.sh - reinstala a stack de programas no macOS.
#
# Apps do ArtCraft: baixados do GitHub Releases e conferidos contra o SHA-256
# publicado antes de instalar. Demais apps: via Homebrew.
#
#   ./restaurar-stack.sh           abre a janela de selecao
#   ./restaurar-stack.sh --tudo    instala tudo, sem janela
#   ./restaurar-stack.sh --apenas wordcraft,gridcraft
#   ./restaurar-stack.sh --listar

set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOGO="${CATALOGO:-$AQUI/catalog.json}"

BASE_DIR="$HOME/Library/Application Support/RestaurarStack"
DOWNLOAD_DIR="$BASE_DIR/downloads"
LOG="$BASE_DIR/restaurar-stack.log"
LOG_MAX=1048576            # 1 MB
APP_DIR="/Applications"

mkdir -p "$BASE_DIR" "$DOWNLOAD_DIR"
chmod 700 "$BASE_DIR"

log() {
  local nivel="${2:-INFO}" linha
  linha="$(date '+%Y-%m-%d %H:%M:%S') [$nivel] $1"
  if [[ -f "$LOG" ]]; then
    local tam
    tam=$(wc -c < "$LOG" | tr -d ' ')
    (( tam > LOG_MAX )) && mv -f "$LOG" "$LOG.1"
  fi
  printf '%s\n' "$linha" >> "$LOG"
  printf '%s\n' "$linha"
}

morrer() { log "$1" ERRO; exit 1; }

command -v python3 >/dev/null 2>&1 || morrer "python3 nao encontrado (vem com as Command Line Tools: xcode-select --install)"
[[ -f "$CATALOGO" ]] || morrer "catalogo nao encontrado: $CATALOGO"

# --------------------------------------------------------- leitura do catalogo
# Cada linha: id \t nome \t fonte \t repo|brew \t cask \t padrao \t rotulo
LINHAS=()
while IFS= read -r __l; do LINHAS+=("$__l"); done < <(python3 -I -c '
import json,sys
cat=json.load(open(sys.argv[1]))
for g in cat["grupos"]:
    for a in g["apps"]:
        rot=a["nome"]
        if a.get("equivale"): rot="%s  -  %s" % (a["nome"], a["equivale"])
        if a["fonte"]=="artcraft":
            alvo=a.get("arquivo") or a["repo"]; cask="0"; extra=a["repo"]+"|"+alvo
        else:
            extra=a.get("brew") or ""; cask="1" if a.get("cask") else "0"
        print("\t".join([a["id"],a["nome"],a["fonte"],extra,cask,
                         "1" if a.get("padrao") else "0", g["nome"]+" > "+rot]))
' "$CATALOGO")

(( ${#LINHAS[@]} )) || morrer "catalogo vazio"

campo() { printf '%s' "$1" | cut -d$'\t' -f"$2"; }

MODO="janela"; APENAS=""
while (( $# )); do
  case "$1" in
    --tudo)   MODO="tudo" ;;
    --listar) MODO="listar" ;;
    --apenas) MODO="apenas"; APENAS="${2:-}"; shift ;;
    *) morrer "opcao desconhecida: $1" ;;
  esac
  shift
done

if [[ "$MODO" == "listar" ]]; then
  for l in "${LINHAS[@]}"; do printf '  %-20s %s\n' "$(campo "$l" 1)" "$(campo "$l" 7)"; done
  exit 0
fi

# ------------------------------------------------------------ janela de selecao
escolher() {
  local rotulos=() padroes=() l
  for l in "${LINHAS[@]}"; do
    rotulos+=("$(campo "$l" 7)")
    [[ "$(campo "$l" 6)" == "1" ]] && padroes+=("$(campo "$l" 7)")
  done

  local lista="" pad="" r
  for r in "${rotulos[@]}"; do lista+="\"${r//\"/\\\"}\","; done
  for r in "${padroes[@]}"; do pad+="\"${r//\"/\\\"}\","; done
  lista="${lista%,}"; pad="${pad%,}"

  # Tudo ja vem marcado. Cmd+A marca todos; Cmd+clique desmarca um.
  osascript <<OSA 2>/dev/null || true
set escolhas to choose from list {$lista} ¬
  with title "Restaurar stack" ¬
  with prompt "Tudo ja esta marcado. Cmd+clique desmarca; Cmd+A marca todos." ¬
  default items {$pad} ¬
  with multiple selections allowed
if escolhas is false then return ""
set txt to ""
repeat with e in escolhas
  set txt to txt & (e as text) & linefeed
end repeat
return txt
OSA
}

SELECIONADOS=()
case "$MODO" in
  tudo)
    for l in "${LINHAS[@]}"; do SELECIONADOS+=("$l"); done ;;
  apenas)
    IFS=',' read -r -a ids <<< "$APENAS"
    for l in "${LINHAS[@]}"; do
      for id in "${ids[@]}"; do
        [[ "$(campo "$l" 1)" == "$id" ]] && SELECIONADOS+=("$l")
      done
    done ;;
  janela)
    saida="$(escolher)"
    [[ -n "$saida" ]] || { echo "Nada selecionado. Nenhuma alteracao feita."; exit 0; }
    while IFS= read -r rot; do
      [[ -n "$rot" ]] || continue
      for l in "${LINHAS[@]}"; do
        [[ "$(campo "$l" 7)" == "$rot" ]] && SELECIONADOS+=("$l")
      done
    done <<< "$saida" ;;
esac

(( ${#SELECIONADOS[@]} )) || { echo "Nada selecionado. Nenhuma alteracao feita."; exit 0; }

# ----------------------------------------------------------- instalacao ArtCraft
instalar_artcraft() {
  local repo="$1" prefixo="$2" nome="$3"
  local base="https://github.com/storytold/$repo/releases/latest/download"
  local sums arquivo esperado destino montagem obtido

  sums="$(curl -fsSL --max-time 60 "$base/SHA256SUMS.txt")" \
    || { log "$nome: FALHOU - nao consegui ler SHA256SUMS.txt" ERRO; return 1; }

  # So aceita nome de arquivo simples: nada de barra, '..' ou caractere estranho.
  local linha
  linha="$(printf '%s\n' "$sums" | awk -v p="$prefixo-" '
      $1 ~ /^[0-9a-fA-F]{64}$/ &&
      $2 ~ /^[A-Za-z0-9._-]+$/ &&
      index($2,p)==1 &&
      $2 ~ /-macos-universal\.dmg$/ { print; exit }')"
  [[ -n "$linha" ]] || { log "$nome: FALHOU - nenhum DMG universal na release mais recente" ERRO; return 1; }

  esperado="$(printf '%s' "$linha" | awk '{print tolower($1)}')"
  arquivo="$(printf '%s' "$linha" | awk '{print $2}')"
  destino="$DOWNLOAD_DIR/$arquivo"

  log "$nome: baixando $arquivo"
  curl -fsSL --max-time 900 -o "$destino" "$base/$arquivo" \
    || { rm -f "$destino"; log "$nome: FALHOU - download" ERRO; return 1; }

  obtido="$(shasum -a 256 "$destino" | awk '{print tolower($1)}')"
  if [[ "$obtido" != "$esperado" ]]; then
    rm -f "$destino"
    log "$nome: FALHOU - SHA-256 nao confere (esperado $esperado, obtido $obtido); arquivo descartado" ERRO
    return 1
  fi
  log "$nome: SHA-256 confere"

  montagem="$(mktemp -d "${TMPDIR:-/tmp}/rstack.XXXXXX")"
  if ! hdiutil attach -nobrowse -readonly -noautoopen -quiet -mountpoint "$montagem" "$destino"; then
    rm -rf "$montagem"; rm -f "$destino"; log "$nome: FALHOU - nao consegui montar o DMG" ERRO; return 1
  fi

  local rc=0 origem
  origem="$(find "$montagem" -maxdepth 1 -name '*.app' -print -quit)"
  if [[ -z "$origem" ]]; then
    log "$nome: FALHOU - nenhum .app dentro do DMG" ERRO; rc=1
  else
    local alvo="$APP_DIR/$(basename "$origem")"
    rm -rf "$alvo" 2>/dev/null || true
    if ! cp -R "$origem" "$APP_DIR/" 2>/dev/null; then
      log "$nome: sem permissao em $APP_DIR, instalando em ~/Applications" AVISO
      mkdir -p "$HOME/Applications"
      cp -R "$origem" "$HOME/Applications/" || rc=1
    fi
  fi

  hdiutil detach "$montagem" -quiet || true
  rm -rf "$montagem"
  rm -f "$destino"
  return $rc
}

instalar_brew() {
  local pacote="$1" cask="$2"
  [[ -n "$pacote" ]] || return 1
  if [[ "$cask" == "1" ]]; then
    brew install --cask "$pacote"
  else
    brew install "$pacote"
  fi
}

# ------------------------------------------------------------------ Homebrew
PRECISA_BREW=0
for l in "${SELECIONADOS[@]}"; do
  [[ "$(campo "$l" 3)" == "gerenciador" ]] && PRECISA_BREW=1
done
TEM_BREW=0
command -v brew >/dev/null 2>&1 && TEM_BREW=1
if (( PRECISA_BREW )) && (( ! TEM_BREW )); then
  log 'Homebrew nao encontrado. Instale por https://brew.sh e rode de novo; os apps do ArtCraft seguem normalmente.' AVISO
fi

# ------------------------------------------------------------------ instalacao
log "Inicio - ${#SELECIONADOS[@]} app(s)"
ok=0; falhas=(); pulados=()
i=0
for l in "${SELECIONADOS[@]}"; do
  i=$((i+1))
  id="$(campo "$l" 1)"; nome="$(campo "$l" 2)"; fonte="$(campo "$l" 3)"
  extra="$(campo "$l" 4)"; cask="$(campo "$l" 5)"
  echo
  log "[$i/${#SELECIONADOS[@]}] $nome"

  if [[ "$fonte" == "artcraft" ]]; then
    repo="${extra%%|*}"; prefixo="${extra##*|}"
    if instalar_artcraft "$repo" "$prefixo" "$nome"; then ok=$((ok+1))
    else falhas+=("$nome"); fi
  else
    if (( ! TEM_BREW )); then
      pulados+=("$nome"); log "$nome: pulado (sem Homebrew)" AVISO
    elif instalar_brew "$extra" "$cask" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      falhas+=("$nome"); log "$nome: FALHOU - brew" ERRO
    fi
  fi
done

echo
echo '================ resumo ================'
echo "instalados : $ok"
(( ${#pulados[@]} )) && echo "pulados    : ${#pulados[@]} -> ${pulados[*]}"
if (( ${#falhas[@]} )); then
  echo "falharam   : ${#falhas[@]}"
  for f in "${falhas[@]}"; do echo "  - $f"; done
fi
echo "log        : $LOG"
log "Fim - ok=$ok falhas=${#falhas[@]} pulados=${#pulados[@]}"
(( ${#falhas[@]} )) && exit 1 || exit 0
