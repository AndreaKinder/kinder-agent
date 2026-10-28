#!/usr/bin/env bash
# ==============================================================================
# kinder-agent: Motor de Memoria de 5 Capas en SQLite (Ultra-Optimizado)
# ==============================================================================
# Capas:
#   1. messages       : Conversación literal en bruto (solo se inyecta ventana deslizante)
#   2. context_cards  : Fichas de contexto comprimidas + índice FTS5 para búsqueda rápida
#   3. profile        : Retrato del usuario (clave-valor persistente)
#   4. facts          : Hechos puntuales fechados + índice FTS5
#   5. diary          : Diario automatizado por sesión / día
# ==============================================================================

MEMORY_DB="${MEMORY_DB:-${SCRIPT_DIR}/memory.db}"
SESSION_ID="${SESSION_ID:-$(date +%Y%m%d_%H%M%S)_$$}"

# Escapar comillas simples para SQL seguro
sql_escape() {
  local val="${1:-}"
  echo "${val//\'/\'\'}"
}

# Inicializar esquema SQLite con modo WAL y tablas FTS5
memory_init() {
  sqlite3 "$MEMORY_DB" <<'EOF' >/dev/null
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

-- 1. Conversación en bruto
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    compacted INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now', 'localtime'))
);

-- 2. Fichas de contexto (resúmenes comprimidos de bloques pasados)
CREATE TABLE IF NOT EXISTS context_cards (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    summary TEXT NOT NULL,
    keywords TEXT DEFAULT '',
    created_at TEXT DEFAULT (datetime('now', 'localtime'))
);

CREATE VIRTUAL TABLE IF NOT EXISTS context_cards_fts USING fts5(
    summary,
    keywords,
    content='context_cards',
    content_rowid='id'
);

-- Triggers para mantener FTS5 de fichas sincronizado
CREATE TRIGGER IF NOT EXISTS context_cards_ai AFTER INSERT ON context_cards BEGIN
    INSERT INTO context_cards_fts(rowid, summary, keywords) VALUES (new.id, new.summary, new.keywords);
END;

-- 3. El Retrato (perfil persistente del usuario)
CREATE TABLE IF NOT EXISTS profile (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT DEFAULT (datetime('now', 'localtime'))
);

-- 4. Hechos sueltos con fecha
CREATE TABLE IF NOT EXISTS facts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    fact TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now', 'localtime'))
);

CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(
    fact,
    content='facts',
    content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS facts_ai AFTER INSERT ON facts BEGIN
    INSERT INTO facts_fts(rowid, fact) VALUES (new.id, new.fact);
END;

-- 5. Diario automatizado
CREATE TABLE IF NOT EXISTS diary (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    entry TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now', 'localtime'))
);
EOF
}

# Guardar un mensaje en la conversación en bruto (Capa 1)
memory_add_message() {
  local role="$1"
  local content="$2"
  local esc_role
  local esc_content
  esc_role="$(sql_escape "$role")"
  esc_content="$(sql_escape "$content")"

  sqlite3 "$MEMORY_DB" \
    "INSERT INTO messages (session_id, role, content) VALUES ('${SESSION_ID}', '${esc_role}', '${esc_content}');"
}

# Extraer palabras clave limpias de una consulta para FTS5
memory_build_fts_query() {
  local raw="$1"
  # Limpiar puntuación, quedarse con palabras de >= 4 letras y unirlas con OR
  local cleaned
  cleaned="$(echo "$raw" | tr -cs '[:alnum:]áéíóúÁÉÍÓÚñÑ' ' ' | tr '[:upper:]' '[:lower:]')"
  local terms=()
  for word in $cleaned; do
    if [[ ${#word} -ge 4 ]]; then
      terms+=("\"${word}\"")
    fi
  done
  if [[ ${#terms[@]} -eq 0 ]]; then
    echo ""
  else
    local IFS=" OR "
    echo "${terms[*]}"
  fi
}

# Ensamblar el payload JSON ultra-optimizado para Ollama (sin archivos temporales)
memory_build_payload() {
  local current_query="$1"
  local fts_query
  fts_query="$(memory_build_fts_query "$current_query")"

  # A. Capa 3: Retrato del usuario
  local profile_block=""
  profile_block="$(sqlite3 "$MEMORY_DB" "SELECT '- ' || key || ': ' || value FROM profile ORDER BY key;" 2>/dev/null || true)"

  # B. Capa 4: Hechos relevantes (FTS5 + últimos recientes ponderados por fecha)
  local facts_block=""
  if [[ -n "$fts_query" ]]; then
    local esc_fts
    esc_fts="$(sql_escape "$fts_query")"
    facts_block="$(sqlite3 "$MEMORY_DB" "
      SELECT DISTINCT '[' || f.created_at || '] ' || f.fact
      FROM facts_fts fts
      JOIN facts f ON f.id = fts.rowid
      WHERE facts_fts MATCH '${esc_fts}'
      ORDER BY f.id DESC LIMIT 4;" 2>/dev/null || true)"
  fi
  if [[ -z "$facts_block" ]]; then
    facts_block="$(sqlite3 "$MEMORY_DB" "
      SELECT '[' || created_at || '] ' || fact
      FROM facts ORDER BY id DESC LIMIT 4;" 2>/dev/null || true)"
  fi

  # C. Capa 2: Fichas de contexto relevantes (FTS5 o última ficha de sesión)
  local cards_block=""
  if [[ -n "$fts_query" ]]; then
    local esc_fts
    esc_fts="$(sql_escape "$fts_query")"
    cards_block="$(sqlite3 "$MEMORY_DB" "
      SELECT '[' || c.created_at || '] ' || c.summary
      FROM context_cards_fts fts
      JOIN context_cards c ON c.id = fts.rowid
      WHERE context_cards_fts MATCH '${esc_fts}'
      ORDER BY c.id DESC LIMIT 2;" 2>/dev/null || true)"
  fi
  if [[ -z "$cards_block" ]]; then
    cards_block="$(sqlite3 "$MEMORY_DB" "
      SELECT '[' || created_at || '] ' || summary
      FROM context_cards ORDER BY id DESC LIMIT 2;" 2>/dev/null || true)"
  fi

  # D. Capa 5: Última entrada del diario
  local diary_block=""
  diary_block="$(sqlite3 "$MEMORY_DB" "
    SELECT '[' || created_at || '] ' || entry
    FROM diary ORDER BY id DESC LIMIT 1;" 2>/dev/null || true)"

  # Construir System Prompt enriquecido de bajo coste en tokens
  local dynamic_system="$SYSTEM_PROMPT"
  if [[ -n "$profile_block" ]]; then
    dynamic_system+=$'\n\n[RETRATO DEL USUARIO]\n'"$profile_block"
  fi
  if [[ -n "$facts_block" ]]; then
    dynamic_system+=$'\n\n[HECHOS CONOCIDOS CON FECHA]\n'"$facts_block"
  fi
  if [[ -n "$cards_block" ]]; then
    dynamic_system+=$'\n\n[FICHAS DE CONTEXTO RELEVANTES]\n'"$cards_block"
  fi
  if [[ -n "$diary_block" ]]; then
    dynamic_system+=$'\n\n[ÚLTIMA ENTRADA DEL DIARIO]\n'"$diary_block"
  fi

  # E. Capa 1: Ventana deslizante estricta (últimos SLIDING_WINDOW mensajes no compactados)
  local recent_msgs_json
  recent_msgs_json="$(sqlite3 -json "$MEMORY_DB" "
    SELECT role, content FROM (
      SELECT id, role, content FROM messages
      WHERE session_id = '${SESSION_ID}' AND compacted = 0
      ORDER BY id DESC LIMIT ${SLIDING_WINDOW}
    ) ORDER BY id ASC;" 2>/dev/null || echo "[]")"
  [[ -z "$recent_msgs_json" ]] && recent_msgs_json="[]"

  # Generar JSON final en memoria con jq
  jq -n \
    --arg model "$MODEL" \
    --arg sys "$dynamic_system" \
    --argjson recent "$recent_msgs_json" \
    --argjson temp "$TEMPERATURE" \
    --argjson ctx "$NUM_CTX" \
    '{
      model: $model,
      messages: ([{role: "system", content: $sys}] + $recent),
      stream: true,
      options: {
        temperature: $temp,
        num_ctx: $ctx
      }
    }'
}

# Destilación automática: extrae Retrato (Capa 3) y Hechos (Capa 4) + Compacta en Fichas (Capa 2)
memory_distill_turn() {
  local user_msg="$1"
  local assistant_msg="$2"

  # 1. Extraer perfil o hechos nuevos de la interacción (JSON estructurado desde el LLM)
  local extractor_prompt
  extractor_prompt="Analiza este intercambio entre Usuario y Asistente.
Extrae ÚNICAMENTE datos permanentes sobre el usuario (nombre, sistema operativo, herramientas, gustos, proyectos) o hechos puntuales importantes.
Si no hay datos nuevos relevantes sobre el usuario o hechos clave, devuelve listas vacías.
Intercambio:
Usuario: ${user_msg}
Asistente: ${assistant_msg}

Responde ESTRICTAMENTE con este formato JSON:
{\"profile\": [{\"key\": \"clave_corta\", \"value\": \"valor\"}], \"facts\": [\"hecho conciso\"]}"

  local extract_payload
  extract_payload="$(jq -n \
    --arg model "$MODEL" \
    --arg prompt "$extractor_prompt" \
    '{
      model: $model,
      prompt: $prompt,
      format: "json",
      stream: false,
      options: { temperature: 0.1, num_ctx: 2048 }
    }')"

  local raw_extract
  raw_extract="$(curl -s -X POST "${API_URL}/api/generate" \
    -H "Content-Type: application/json" \
    -d "$extract_payload" | jq -r '.response // empty' 2>/dev/null || true)"

  if [[ -n "$raw_extract" ]]; then
    # Insertar claves de perfil (Capa 3)
    while IFS=$'\t' read -r k v; do
      if [[ -n "$k" && -n "$v" && "$k" != "null" && "$v" != "null" ]]; then
        local ek ev
        ek="$(sql_escape "$k")"
        ev="$(sql_escape "$v")"
        sqlite3 "$MEMORY_DB" "
          INSERT INTO profile (key, value, updated_at)
          VALUES ('${ek}', '${ev}', datetime('now', 'localtime'))
          ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;" 2>/dev/null || true
      fi
    done < <(echo "$raw_extract" | jq -r '.profile[]? | [.key, .value] | @tsv' 2>/dev/null || true)

    # Insertar hechos fechados (Capa 4)
    while IFS= read -r fact_item; do
      if [[ -n "$fact_item" && "$fact_item" != "null" ]]; then
        local ef
        ef="$(sql_escape "$fact_item")"
        sqlite3 "$MEMORY_DB" "INSERT INTO facts (fact) VALUES ('${ef}');" 2>/dev/null || true
      fi
    done < <(echo "$raw_extract" | jq -r '.facts[]?' 2>/dev/null || true)
  fi

  # 2. Comprobar si superamos el umbral para compactar en una Ficha de Contexto (Capa 2)
  local uncompacted_count
  uncompacted_count="$(sqlite3 "$MEMORY_DB" "
    SELECT COUNT(*) FROM messages
    WHERE session_id = '${SESSION_ID}' AND compacted = 0;")"

  if (( uncompacted_count >= CHUNK_THRESHOLD )); then
    memory_compact_chunk
  fi
}

# Compactar los mensajes más antiguos de la ventana en una Ficha de Contexto (Capa 2)
memory_compact_chunk() {
  local chunk_size=$(( CHUNK_THRESHOLD / 2 ))
  local old_Dialog
  old_Dialog="$(sqlite3 "$MEMORY_DB" "
    SELECT role || ': ' || content FROM (
      SELECT id, role, content FROM messages
      WHERE session_id = '${SESSION_ID}' AND compacted = 0
      ORDER BY id ASC LIMIT ${chunk_size}
    );" 2>/dev/null || true)"

  [[ -z "$old_Dialog" ]] && return 0

  local sum_prompt="Resume de forma ultra-compacta los puntos técnicos clave y decisiones de este fragmento de conversación.
Devuelve JSON estricto: {\"summary\": \"resumen conciso en 1-2 frases\", \"keywords\": \"palabras clave separadas por espacio\"}

Fragmento:
${old_Dialog}"

  local sum_payload
  sum_payload="$(jq -n \
    --arg model "$MODEL" \
    --arg prompt "$sum_prompt" \
    '{
      model: $model,
      prompt: $prompt,
      format: "json",
      stream: false,
      options: { temperature: 0.1, num_ctx: 2048 }
    }')"

  local raw_sum
  raw_sum="$(curl -s -X POST "${API_URL}/api/generate" \
    -H "Content-Type: application/json" \
    -d "$sum_payload" | jq -r '.response // empty' 2>/dev/null || true)"

  if [[ -n "$raw_sum" ]]; then
    local summary keywords
    summary="$(echo "$raw_sum" | jq -r '.summary // empty' 2>/dev/null || true)"
    keywords="$(echo "$raw_sum" | jq -r '.keywords // empty' 2>/dev/null || true)"

    if [[ -n "$summary" ]]; then
      local es ek
      es="$(sql_escape "$summary")"
      ek="$(sql_escape "$keywords")"
      sqlite3 "$MEMORY_DB" "
        INSERT INTO context_cards (session_id, summary, keywords)
        VALUES ('${SESSION_ID}', '${es}', '${ek}');
        UPDATE messages SET compacted = 1
        WHERE id IN (
          SELECT id FROM messages
          WHERE session_id = '${SESSION_ID}' AND compacted = 0
          ORDER BY id ASC LIMIT ${chunk_size}
        );" 2>/dev/null || true
    fi
  fi
}

# Generar entrada en el Diario Automatizado al cerrar sesión (Capa 5)
memory_write_diary() {
  local session_msgs
  session_msgs="$(sqlite3 "$MEMORY_DB" "
    SELECT role || ': ' || content FROM messages
    WHERE session_id = '${SESSION_ID}'
    ORDER BY id ASC LIMIT 20;" 2>/dev/null || true)"

  [[ -z "$session_msgs" ]] && return 0

  local diary_prompt="Escribe una entrada de diario en 1 o 2 frases resumiendo qué hemos hecho o hablado en esta sesión:
${session_msgs}"

  local diary_payload
  diary_payload="$(jq -n \
    --arg model "$MODEL" \
    --arg prompt "$diary_prompt" \
    '{
      model: $model,
      prompt: $prompt,
      stream: false,
      options: { temperature: 0.2, num_ctx: 2048 }
    }')"

  local entry
  entry="$(curl -s -X POST "${API_URL}/api/generate" \
    -H "Content-Type: application/json" \
    -d "$diary_payload" | jq -r '.response // empty' 2>/dev/null || true)"

  if [[ -n "$entry" ]]; then
    local ee
    ee="$(sql_escape "$entry")"
    sqlite3 "$MEMORY_DB" "INSERT INTO diary (session_id, entry) VALUES ('${SESSION_ID}', '${ee}');" 2>/dev/null || true
  fi
}
