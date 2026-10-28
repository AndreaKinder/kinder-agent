# kinder-agent

REPL interactivo y ultraligero en Bash para dialogar con modelos locales en [Ollama](https://ollama.com/), equipado con un **motor de memoria persistente de 5 capas sobre SQLite y FTS5**.

Diseñado bajo una filosofía de cero dependencias pesadas (*zero-framework*): sin runtimes de Python ni Node.js, sin bases de datos vectoriales externas y con un consumo mínimo de tokens en cada turno.

---

## Arquitectura de Memoria de 5 Capas

El problema habitual al ejecutar modelos pequeños en local (`4B`–`7B` parámetros con contextos de `4096` tokens) es que el historial de conversación satura rápidamente la ventana de contexto o degrada la latencia. `kinder-agent` resuelve esto dividiendo el estado en cinco estructuras SQLite sincronizadas en modo `WAL`:

1. **`messages` (Ventana Deslizante en Bruto):** Almacena toda la transcripción literal, pero solo inyecta en el prompt los últimos `sliding_window` mensajes no compactados para mantener el contexto inmediato limpio.
2. **`context_cards` (Fichas de Contexto + FTS5):** Cuando los mensajes activos alcanzan el umbral `chunk_threshold`, el bloque más antiguo se resume automáticamente en una ficha concisa con palabras clave indexadas mediante `FTS5` y se marca como compactado (`compacted = 1`).
3. **`profile` (Retrato del Usuario):** Tabla clave-valor (`UPSERT`) con atributos permanentes del entorno y preferencias del usuario (sistema operativo, herramientas, stack, idioma).
4. **`facts` (Hechos Fechados + FTS5):** Registro cronológico de eventos o decisiones puntuales indexado con búsqueda de texto completo (`FTS5`).
5. **`diary` (Diario de Sesión):** Al cerrar el REPL (`exit`, `quit` o `EOF`), sintetiza lo trabajado durante la sesión en una entrada de diario para conservar continuidad entre ejecuciones.

### Ciclo de Ejecución por Turno

```text
[ Entrada del Usuario ]
         │
         ├──► 1. Guarda mensaje literal en `messages` (Capa 1)
         │
         ├──► 2. Ensambla Payload en RAM (`memory_build_payload`):
         │       ├─ Extrae términos (>= 4 letras) y consulta `facts_fts` y `context_cards_fts`
         │       ├─ Inyecta System Prompt dinámico: Retrato + Hechos + Fichas + Último Diario
         │       └─ Adjunta ventana deslizante estricta (`SLIDING_WINDOW` mensajes)
         │
         ├──► 3. Streaming vía `/api/chat` de Ollama
         │
         └──► 4. Destilación asíncrona en background (`memory_distill_turn &`):
                 ├─ Extrae JSON estructurado (`profile` y `facts`) vía `/api/generate`
                 └─ Si `uncompacted >= CHUNK_THRESHOLD` ──► Compacta bloque en `context_cards`
```

Toda la destilación semántica y la compactación ocurren en un subproceso en segundo plano (`&`), de modo que el prompt vuelve a estar disponible al instante tras terminar la respuesta en streaming.

---

## Estructura del Proyecto

- [`repl.sh`](./repl.sh): Bucle interactivo principal, validación de dependencias, streaming de respuestas y ciclo de vida de la sesión.
- [`memory.sh`](./memory.sh): Motor SQLite de 5 capas, construcción de consultas `FTS5`, ensamblado de payloads JSON en memoria y destilación asíncrona.
- [`model.json`](./model.json): Parámetros del modelo, prompt base y umbrales de la ventana de memoria.
- [`theme.sh`](./theme.sh): Paleta de colores ANSI adaptable a variables de entorno `$KINDER_THEME_*`.

---

## Requisitos

- `bash`
- `sqlite3` (con soporte para extensión `FTS5` y salida `-json`)
- `jq`
- `curl`
- [Ollama](https://ollama.com/) ejecutándose localmente (`http://127.0.0.1:11434`)

---

## Configuración (`model.json`)

```json
{
  "model": "gemma3:4b",
  "system_prompt": "Eres Kinder Agent, un asistente de programación local preciso, directo y técnico ejecutándose en Ollama. Responde siempre en español de forma concisa y utiliza la información de tu memoria para personalizar tus respuestas al entorno del usuario.",
  "endpoint": "http://127.0.0.1:11434",
  "temperature": 0.3,
  "num_ctx": 4096,
  "sliding_window": 6,
  "chunk_threshold": 8
}
```

| Parámetro | Descripción |
| :--- | :--- |
| `model` | Identificador del modelo en Ollama (ej. `gemma3:4b`, `qwen2.5-coder:7b`). |
| `system_prompt` | Instrucción base del sistema a la que se concatenan las capas de memoria. |
| `endpoint` | URL o IP del servidor Ollama. |
| `temperature` | Temperatura de generación para la conversación principal (`0.3` por defecto). |
| `num_ctx` | Tamaño máximo de la ventana de contexto enviada a Ollama (`4096`). |
| `sliding_window` | Número máximo de mensajes recientes no compactados que se envían en bruto. |
| `chunk_threshold` | Umbral de mensajes acumulados que dispara la compactación en una ficha de contexto. |

---

## Uso

```bash
# Iniciar el REPL con la configuración por defecto
./repl.sh

# Usar un archivo de configuración alternativo
CONFIG_FILE=./custom_model.json ./repl.sh

# Usar una base de datos de memoria distinta
MEMORY_DB=./proyecto_x.db ./repl.sh
```

Para finalizar la sesión y permitir que el agente escriba la entrada en el diario (`diary`), escribe `exit`, `quit` o pulsa `Ctrl+D`.
