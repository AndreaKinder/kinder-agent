#!/usr/bin/env bash
# ==============================================================================
# kinder-agent: REPL interactivo con Memoria de 5 Capas en SQLite
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/model.json}"
THEME_FILE="${THEME_FILE:-${SCRIPT_DIR}/theme.sh}"
MEMORY_MODULE="${MEMORY_MODULE:-${SCRIPT_DIR}/memory.sh}"

# 1. Cargar paleta de colores
if [[ ! -f "$THEME_FILE" ]]; then
  echo "Error: No se encontró el archivo de tema: ${THEME_FILE}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$THEME_FILE"

# 2. Verificar dependencias
for cmd in curl jq sqlite3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${COLOR_ERROR}Error: Se requiere '$cmd' pero no está instalado.${COLOR_RESET}" >&2
    exit 1
  fi
done

# 3. Cargar configuración desde model.json
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "${COLOR_ERROR}Error: No se encontró el archivo de configuración: ${CONFIG_FILE}${COLOR_RESET}" >&2
  exit 1
fi

MODEL="$(jq -er '.model' "$CONFIG_FILE")"
SYSTEM_PROMPT="$(jq -er '.system_prompt' "$CONFIG_FILE")"
TEMPERATURE="$(jq -er '.temperature' "$CONFIG_FILE")"
RAW_ENDPOINT="$(jq -er '.endpoint' "$CONFIG_FILE")"
NUM_CTX="$(jq -er '.num_ctx' "$CONFIG_FILE")"
SLIDING_WINDOW="$(jq -er '.sliding_window' "$CONFIG_FILE")"
CHUNK_THRESHOLD="$(jq -er '.chunk_threshold' "$CONFIG_FILE")"

# Normalizar endpoint
if [[ "$RAW_ENDPOINT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$RAW_ENDPOINT" == "localhost" ]]; then
  API_URL="http://${RAW_ENDPOINT}:11434"
elif [[ "$RAW_ENDPOINT" =~ ^https?:// ]]; then
  API_URL="$RAW_ENDPOINT"
else
  API_URL="http://${RAW_ENDPOINT}"
fi
API_URL="${API_URL%/}"

# 4. Cargar motor de memoria SQLite
if [[ ! -f "$MEMORY_MODULE" ]]; then
  echo -e "${COLOR_ERROR}Error: No se encontró el módulo de memoria: ${MEMORY_MODULE}${COLOR_RESET}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$MEMORY_MODULE"
memory_init

print_header() {
  echo -e "${COLOR_BORDER}╭──────────────────────────────────────────────────────────╮${COLOR_RESET}"
  echo -e "${COLOR_BORDER}│  ${COLOR_BOLD}${COLOR_SYSTEM}🤖 KINDER-AGENT · Local REPL (5-Layer SQLite Memory)${COLOR_RESET}${COLOR_BORDER}    │${COLOR_RESET}"
  printf "${COLOR_BORDER}│  ${COLOR_RESET}Modelo:  %-46s ${COLOR_BORDER}│${COLOR_RESET}\n" "${MODEL} (ctx: ${NUM_CTX})"
  printf "${COLOR_BORDER}│  ${COLOR_RESET}Ventana: %-46s ${COLOR_BORDER}│${COLOR_RESET}\n" "Últimos ${SLIDING_WINDOW} msgs | Compactación: cada ${CHUNK_THRESHOLD}"
  echo -e "${COLOR_BORDER}╰──────────────────────────────────────────────────────────╯${COLOR_RESET}"
}

send_message() {
  local user_input="$1"

  # 1. Guardar mensaje del usuario en Capa 1 (conversación en bruto)
  memory_add_message "user" "$user_input"

  # 2. Construir el payload ultra-optimizado en RAM combinando las 5 capas
  local payload
  payload="$(memory_build_payload "$user_input")"

  echo -ne "\n${COLOR_BOLD}${COLOR_ASSISTANT}Kinder › ${COLOR_RESET}"

  local full_reply=""

  # 3. Petición streaming a Ollama
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      local chunk
      chunk="$(echo "$line" | jq -r '.message.content // empty' 2>/dev/null || true)"
      if [[ -n "$chunk" ]]; then
        echo -ne "$chunk"
        full_reply+="$chunk"
      fi
    fi
  done < <(curl -s -N -X POST "${API_URL}/api/chat" \
    -H "Content-Type: application/json" \
    -d "$payload")

  echo ""

  if [[ -n "$full_reply" ]]; then
    # 4. Guardar respuesta del asistente en Capa 1
    memory_add_message "assistant" "$full_reply"

    # 5. Destilación en segundo plano (actualiza Perfil, Hechos y Fichas sin bloquear el REPL)
    memory_distill_turn "$user_input" "$full_reply" >/dev/null 2>&1 &
  else
    echo -e "${COLOR_ERROR}(Sin respuesta de Ollama)${COLOR_RESET}"
  fi
}

on_exit() {
  echo -ne "\n${COLOR_DIM}Sincronizando memoria y diario de sesión...${COLOR_RESET}"
  wait 2>/dev/null || true
  memory_write_diary
  echo -e " ${COLOR_SYSTEM}¡Listo!${COLOR_RESET}"
}

main() {
  print_header

  while true; do
    local user_prompt=""
    echo -ne "\n${COLOR_BOLD}${COLOR_USER}Tú › ${COLOR_RESET}"
    if ! IFS= read -r user_prompt; then
      on_exit
      break
    fi

    local trimmed="${user_prompt#"${user_prompt%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

    [[ -z "$trimmed" ]] && continue

    if [[ "$trimmed" == "exit" || "$trimmed" == "quit" ]]; then
      on_exit
      break
    fi

    send_message "$trimmed"
  done
}

main "$@"
