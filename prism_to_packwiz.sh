#!/usr/bin/env bash
# =============================================================================
# prism_to_packwiz.sh
# Migra mods de um modpack do Prism Launcher para o packwiz.
#
# Uso:
#   ./prism_to_packwiz.sh <caminho_para_pasta_mods> [caminho_saida_packwiz] [--reset]
#
# Exemplos:
#   ./prism_to_packwiz.sh ~/modpacks/meu-pack/mods
#   ./prism_to_packwiz.sh ~/modpacks/meu-pack/mods ~/packwiz-output
#   ./prism_to_packwiz.sh ~/modpacks/meu-pack/mods ~/packwiz-output --reset
#
# Requisitos:
#   - packwiz  (https://packwiz.infra.link)
#   - python3
#   - curl (para mods CurseForge)
#
# Variáveis de ambiente:
#   CURSEFORGE_API_KEY  → obrigatória para mods CurseForge
#
# Formatos suportados (campo download.mode nos .toml do .index):
#   - "url"                  → Modrinth (via update.modrinth.mod-id / version)
#   - "metadata:curseforge"  → CurseForge (via update.curseforge.project-id / file-id)
# =============================================================================

set -euo pipefail

# ── Cores ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
RST='\033[0m'

# ── Argumentos ────────────────────────────────────────────────────────────────
MODS_DIR="${1:-./mods}"
OUTPUT_DIR="${2:-.}"
RESET_MODE="${3:-}"   # passe --reset como 3º argumento para recriar o modpack

INDEX_DIR="$MODS_DIR/.index"

if [[ ! -d "$INDEX_DIR" ]]; then
    echo -e "${RED}Erro: pasta .index não encontrada em '$MODS_DIR'${RST}"
    exit 1
fi

# ── Verificar dependências ────────────────────────────────────────────────────
for cmd in packwiz python3 curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}Erro: '$cmd' não está instalado ou não está no PATH.${RST}"
        exit 1
    fi
done

# ── Função: ler valor de um campo TOML via Python ────────────────────────────
toml_get() {
    local file="$1"
    local key="$2"
    python3 - "$file" "$key" <<'PYEOF'
import sys, re

path = sys.argv[1]
key  = sys.argv[2]

try:
    import tomllib
    with open(path, "rb") as f:
        data = tomllib.load(f)
except ModuleNotFoundError:
    try:
        import tomli as tomllib
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except ModuleNotFoundError:
        data = {}
        current_section = []
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                m = re.match(r'^\[([^\]]+)\]$', line)
                if m:
                    current_section = m.group(1).split('.')
                    continue
                m = (re.match(r"^([\w\-]+)\s*=\s*'([^']*)'", line) or
                     re.match(r'^([\w\-]+)\s*=\s*"([^"]*)"', line) or
                     re.match(r'^([\w\-]+)\s*=\s*(\S+)', line))
                if m:
                    node = data
                    for part in current_section:
                        node = node.setdefault(part, {})
                    node[m.group(1)] = m.group(2).strip("'\"")

parts = key.split('.')
node = data
for part in parts:
    if not isinstance(node, dict) or part not in node:
        sys.exit(1)
    node = node[part]
print(node)
PYEOF
}

# ── Obter URL de download do CurseForge via API ───────────────────────────────
# Bug corrigido: recebia project_id e file_id como argumentos mas não eram passados
cf_get_download_url() {
    local project_id="$1"
    local file_id="$2"
    local api_key="${CURSEFORGE_API_KEY:-}"

    [[ -z "$api_key" ]] && return 1

    # Uma única chamada à API — reutilizamos a resposta para downloadUrl e fileName
    local response
    response=$(curl -sf \
        -H 'Accept: application/json' \
        -H "x-api-key: $api_key" \
        "https://api.curseforge.com/v1/mods/${project_id}")

    local slug
    slug=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d['data']['slug'] or '')" \
          "$response" 2>/dev/null || echo "")
    [[ -z "$slug" || "$slug" == "None" ]] && return 1
    echo "https://www.curseforge.com/minecraft/mc-mods/${slug}/files/${file_id}"
    return 0
}

# ── Listar mods do .index e extrair informações ───────────────────────────────
listar_mods_do_index_com_info() {
    if [[ ! -d "$INDEX_DIR" ]]; then
        return 1
    fi

    for toml_file in "$INDEX_DIR"/*.pw.toml; do
        [[ -f "$toml_file" ]] || continue

        # Bug corrigido: variável era $toml_path em vez de $toml_file
        local mod_name
        mod_name=$(toml_get "$toml_file" "name" 2>/dev/null || basename "$toml_file" .pw.toml)

        local jar_filename
        jar_filename=$(toml_get "$toml_file" "filename" 2>/dev/null || echo "")

        # Remover TOML órfão (JAR não existe)
        if [[ -n "$jar_filename" && ! -f "$MODS_DIR/$jar_filename" ]]; then
            rm -f "$toml_file"
            continue
        fi

        # Bug corrigido: grep -o com ^ não funciona bem para detectar seções;
        # usamos toml_get para verificar qual seção [update.*] existe
        local mod_repo=""
        local url=""
        local extra=""   # project-id, file-id ou version-id conforme o repo

        if toml_get "$toml_file" "update.modrinth.mod-id" &>/dev/null; then
            mod_repo="modrinth"
            local mod_id version
            mod_id=$(toml_get "$toml_file" "update.modrinth.mod-id" 2>/dev/null || echo "")
            version=$(toml_get "$toml_file" "update.modrinth.version" 2>/dev/null || echo "")
            url=$(toml_get "$toml_file" "download.url" 2>/dev/null || echo "")
            extra="${mod_id}:${version}"

        elif toml_get "$toml_file" "update.curseforge.project-id" &>/dev/null; then
            mod_repo="curseforge"
            local project_id file_id
            project_id=$(toml_get "$toml_file" "update.curseforge.project-id" 2>/dev/null || echo "")
            file_id=$(toml_get "$toml_file" "update.curseforge.file-id" 2>/dev/null || echo "")
            url=$(cf_get_download_url "$project_id" "$file_id" 2>/dev/null || echo "")
            extra="${project_id}:${file_id}"
        else
            mod_repo="unknown"
        fi

        # mod_name vem por ÚLTIMO — pode conter espaços, read consome o resto da linha
        echo "${mod_repo}|${extra}|${url}|${mod_name}"
    done
}

# ── Recriar o modpack packwiz do zero preservando os dados do pack.toml ───────
# Apaga todos os arquivos gerados pelo packwiz (mods/*.pw.toml, index.toml e
# pack.toml) e reinicia com `packwiz init` usando os mesmos metadados.
recriar_modpack() {
    local pack_file="$OUTPUT_DIR/pack.toml"

    # ── Ler metadados do pack.toml existente, se houver ───────────────────
    local pack_name pack_author pack_version mc_version modloader modloader_version
    pack_name=""
    pack_author=""
    pack_version=""
    mc_version=""
    modloader=""
    modloader_version=""

    if [[ -f "$pack_file" ]]; then
        echo -e "${CYN}  Lendo metadados do pack.toml existente...${RST}"
        pack_name=$(toml_get "$pack_file" "name" 2>/dev/null || echo "")
        pack_author=$(toml_get "$pack_file" "author" 2>/dev/null || echo "")
        pack_version=$(toml_get "$pack_file" "version" 2>/dev/null || echo "")
        mc_version=$(toml_get "$pack_file" "versions.minecraft" 2>/dev/null || echo "")
        # Detectar modloader: tenta forge, neoforge, fabric, quilt
        for loader in forge neoforge fabric quilt; do
            local v
            v=$(toml_get "$pack_file" "versions.${loader}" 2>/dev/null || echo "")
            if [[ -n "$v" ]]; then
                modloader="$loader"
                modloader_version="$v"
                break
            fi
        done
    fi

    # ── Confirmação ───────────────────────────────────────────────────────
    echo ""
    echo -e "${YEL}  Os seguintes arquivos serão apagados em '${OUTPUT_DIR}':${RST}"
    echo -e "    pack.toml, index.toml e todos os *.pw.toml dentro de mods/"
    echo ""
    echo -e "${YEL}  Metadados recuperados:${RST}"
    echo -e "    Nome       : ${pack_name:-<será solicitado pelo packwiz init>}"
    echo -e "    Autor      : ${pack_author:-<será solicitado pelo packwiz init>}"
    echo -e "    Versão     : ${pack_version:-<será solicitado pelo packwiz init>}"
    echo -e "    Minecraft  : ${mc_version:-<será solicitado pelo packwiz init>}"
    echo -e "    Modloader  : ${modloader:-<será solicitado pelo packwiz init>} ${modloader_version}"
    echo ""
    read -rp "  Confirmar recriação? [s/N] " confirm
    [[ "$confirm" =~ ^[sS]$ ]] || { echo -e "${YEL}  Cancelado.${RST}"; return 0; }

    # ── Apagar arquivos gerados pelo packwiz ──────────────────────────────
    echo -e "${CYN}  Removendo arquivos antigos...${RST}"
    rm -f "$OUTPUT_DIR/pack.toml"
    rm -f "$OUTPUT_DIR/index.toml"
    if [[ -d "$OUTPUT_DIR/mods" ]]; then
        find "$OUTPUT_DIR/mods" -maxdepth 1 -name "*.pw.toml" -delete
    fi

    # ── Recriar com packwiz init ──────────────────────────────────────────
    echo -e "${CYN}  Recriando modpack com packwiz init...${RST}"
    cd "$OUTPUT_DIR"

    # Montar argumentos para passar os metadados diretamente, sem interação,
    # quando todas as informações estiverem disponíveis
    local init_args=()
    [[ -n "$pack_name" ]]         && init_args+=(--name "$pack_name")
    [[ -n "$pack_author" ]]       && init_args+=(--author "$pack_author")
    [[ -n "$pack_version" ]]      && init_args+=(--version "$pack_version")
    [[ -n "$mc_version" ]]        && init_args+=(--mc-version "$mc_version")
    [[ -n "$modloader" ]]         && init_args+=(--modloader "$modloader")
    [[ -n "$modloader_version" ]] && init_args+=(--${modloader}-version "$modloader_version")

    if [[ ${#init_args[@]} -gt 0 ]]; then
        # Todos os dados disponíveis — init não-interativo
        packwiz init "${init_args[@]}"
    else
        # Algum dado faltando — init interativo normal
        packwiz init
    fi

    echo -e "${GRN}  ✔ Modpack recriado com sucesso.${RST}"
}

# ── Wrapper: nega todos os prompts de dependência do packwiz ──────────────────
packwiz_no_deps() {
    yes n 2>/dev/null | packwiz "$@" 2>/dev/null
    return "${PIPESTATUS[1]}"
}

# ── Preparar diretório de saída ───────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

# ── Contadores e listas ───────────────────────────────────────────────────────
TOTAL=0
OK=0
declare -a FAILED_MODS=()

# ── Cabeçalho ─────────────────────────────────────────────────────────────────
echo -e "${BLU}╔═══════════════════════════════════════════════════════╗${RST}"
echo -e "${BLU}║   Prism Launcher → packwiz  |  Importação de Mods     ║${RST}"
echo -e "${BLU}╚═══════════════════════════════════════════════════════╝${RST}"
echo ""
echo -e "${CYN}Pasta de origem : ${RST}$INDEX_DIR"
echo -e "${CYN}Pasta de saída  : ${RST}$(pwd)"
echo ""

# ── Processamento ────────────]─────────────────────────────────────────────────
processar_todos_mods() {
    local -a mods_info
    mapfile -t mods_info < <(listar_mods_do_index_com_info)

    if [[ ${#mods_info[@]} -eq 0 ]]; then
        echo -e "${YEL}⚠ Nenhum mod encontrado no .index${RST}"
        return
    fi

    for mod_entry in "${mods_info[@]}"; do
        TOTAL=$(( TOTAL + 1 ))

        # Ordem: mod_repo|extra|url|mod_name
        # mod_name é o último pois pode conter espaços (read consome o resto da linha)
        local mod_repo extra url mod_name
        IFS='|' read -r mod_repo extra url mod_name <<< "$mod_entry"

        echo -e "  ${YEL}▶${RST} ${mod_name}"
        echo -e "     Origem : ${mod_repo}"

        if [[ "$mod_repo" == "modrinth" ]]; then
            # extra = "mod_id:version"
            local mod_id version
            IFS=':' read -r mod_id version <<< "$extra"

            echo -e "     ID     : ${mod_id}  versão: ${version:-latest}"

            # Bug corrigido: packwiz modrinth add não aceita URL como argumento;
            # usa --project-id e --version-id. URL direta usa packwiz url add.
            if [[ -n "$mod_id" && -n "$version" ]] && \
               packwiz_no_deps modrinth add --project-id "$mod_id" --version-id "$version"; then
                echo -e "     ${GRN}✔$mod_name Importado (versão específica)${RST}"
                OK=$(( OK + 1 ))
            elif [[ -n "$mod_id" ]] && \
               packwiz_no_deps modrinth add --project-id "$mod_id"; then
                echo -e "     ${GRN}✔$mod_name Importado (versão mais recente)${RST}"
                OK=$(( OK + 1 ))
            elif [[ -n "$url" ]] && \
               packwiz_no_deps url add "$mod_name" "$url"; then
                echo -e "     ${GRN}✔$mod_name Importado via URL direta ($url) ${RST}"
                OK=$(( OK + 1 ))
            else
                echo -e "     ${RED}✘$mod_name Falhou${RST}"
                FAILED_MODS+=("${mod_name}  [Modrinth id=${mod_id}]")
            fi

        elif [[ "$mod_repo" == "curseforge" ]]; then
            # extra = "project_id:file_id"
            local project_id file_id
            IFS=':' read -r project_id file_id <<< "$extra"

            echo -e "     ID     : project=${project_id}  file=${file_id}"
            if [[ -n "$url" ]] && \
               packwiz_no_deps curseforge add "$url"; then
                echo -e "     ${GRN}✔ Importado via URL da API CurseForge${RST}"
                OK=$(( OK + 1 ))
            else
                echo -e "     ${RED}✘$mod_name Falhou [URL: $url]${RST}"
                FAILED_MODS+=("${mod_name}  [CurseForge project=${project_id} file=${file_id}]")
            fi

        else
            echo -e "     ${RED}✘ Repositório desconhecido — não foi possível importar${RST}"
            FAILED_MODS+=("${mod_name}  [repositório desconhecido]")
        fi

        echo ""
    done
}

if [[ "$RESET_MODE" == "--reset" ]]; then
    echo -e "${YEL}╔═══════════════════════════════════════════════════════╗${RST}"
    echo -e "${YEL}║            Modo de recriação do modpack               ║${RST}"
    echo -e "${YEL}╚═══════════════════════════════════════════════════════╝${RST}"
    recriar_modpack
    echo ""
elif [[ ! -f "$OUTPUT_DIR/pack.toml" ]]; then
    packwiz init
fi

processar_todos_mods

# ── Resumo ────────────────────────────────────────────────────────────────────
FAILED_COUNT=$(( TOTAL - OK ))

echo -e "${BLU}═══════════════════════════════════════════════════════${RST}"
echo -e "${BLU}  RESUMO FINAL${RST}"
echo -e "${BLU}═══════════════════════════════════════════════════════${RST}"
printf "  Total de mods encontrados  : %d\n" "$TOTAL"
printf "  ✔ Importados com sucesso   : %d\n" "$OK"
printf "  ✘ Falhas                   : %d\n" "$FAILED_COUNT"
echo ""

if [[ ${#FAILED_MODS[@]} -gt 0 ]]; then
    echo -e "${RED}╔══════════════════════════════════════════════════════╗${RST}"
    echo -e "${RED}║         Mods que NÃO foram transferidos              ║${RST}"
    echo -e "${RED}╠══════════════════════════════════════════════════════╣${RST}"
    for entry in "${FAILED_MODS[@]}"; do
        echo -e "${RED}║  ✘  ${entry}${RST}"
    done
    echo -e "${RED}╚══════════════════════════════════════════════════════╝${RST}"
    echo ""
    echo -e "${YEL}━━━ Dicas para resolver as falhas ━━━${RST}"
    echo ""
    echo -e "${CYN}CurseForge:${RST}"
    echo -e "  O packwiz exige uma API key. Configure com:"
    echo -e "    export CURSEFORGE_API_KEY='sua-chave-aqui'"
    echo -e "  Ou adicione em ~/.config/packwiz/config.toml:"
    echo -e "    curseforge-api-key = 'sua-chave-aqui'"
    echo ""
    echo -e "${CYN}Modrinth:${RST}"
    echo -e "  Verifique se o mod/versão ainda existe no Modrinth."
    echo -e "  Tente: packwiz modrinth add <slug-do-mod>"
    echo ""
    echo -e "${CYN}Repositório desconhecido:${RST}"
    echo -e "  Adicione manualmente: packwiz url add <nome> <url-direta>"
    exit 1
else
    echo -e "${GRN}✔ Todos os mods foram importados com sucesso!${RST}"
    exit 0
fi
