#!/usr/bin/env bash
# Location: /usr/local/bin/config-ai-provider
# Description: Non-interactively applies an AI provider mode and model to agent-config.json.
set -euo pipefail

AGENT_PATH="/agent"
CONFIG_HELPERS_PATH="/config-helpers"
PROVIDER=""
MODEL=""
MODE=""

# Source shared libs co-located with this script (repo scripts/ in dev,
# /usr/local/bin in the container). The .sh suffix only exists in dev.
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _name in agent-file-perms-lib; do
  _path="${_LIB}/${_name}"
  [ -f "${_path}.sh" ] && _path="${_path}.sh"
  # shellcheck disable=SC1090
  source "${_path}"
done

usage() {
  cat <<EOF
Usage: $(basename "$0") --provider <provider> --model <model> --mode <default|efficiency> [-ap <agent-path>] [-cp <config-helpers-path>] [help|h|--help|-h]

Options:
  -p, --provider <value>              AI provider value to write to AI_PROVIDER (for example: openai)
  -m, --model <value>                 AI model value to write to AI_MODEL
      --mode <default|efficiency>     Mode selector mapped to <provider>-default.env or <provider>-token-efficiency.env
  -ap, --agent-path <path>            Override agent path (default: /agent)
  -cp, --config-helpers-path <path>   Override config helpers path (default: /config-helpers)
  -h, --help                          Show this help message
  h, help                             Show this help message

Notes:
  - This command mirrors the config_ai_mode update flow without interactive prompts.
  - Once a provider is configured, switching to a different provider is blocked just like config-agent.
  - Gemma extra-instruction handling is intentionally skipped.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -ap|--agent-path)
      AGENT_PATH="${2:?--agent-path requires a value}"
      shift 2
      ;;
    -cp|--config-helpers-path)
      CONFIG_HELPERS_PATH="${2:?--config-helpers-path requires a value}"
      shift 2
      ;;
    -p|--provider)
      PROVIDER="${2:?--provider requires a value}"
      shift 2
      ;;
    -m|--model)
      MODEL="${2:?--model requires a value}"
      shift 2
      ;;
    --mode)
      MODE="${2:?--mode requires a value}"
      shift 2
      ;;
    -h|--help|h|help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$PROVIDER" || -z "$MODEL" || -z "$MODE" ]]; then
  echo "Error: --provider, --model, and --mode are all required." >&2
  usage >&2
  exit 1
fi

EXTRA_INSTRUCTION_FILE="${AGENT_PATH}/instructions/extra-instructions.md"
STATUS_FILE="${CONFIG_HELPERS_PATH}/agent-config-status.yaml"
AGENT_CONFIG_FILE="${AGENT_PATH}/config/agent-config.json"
DEFAULT_AGENT_CONFIG_FILE="${CONFIG_HELPERS_PATH}/default-agent-config.json"
MODES_DIR="${CONFIG_HELPERS_PATH}/modes"

# Resolve update-agent-config: prefer same directory (local dev), fall back to PATH (container)
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_SCRIPT_DIR}/update-agent-config.sh" ]]; then
  UPDATE_CONFIG_CMD="${_SCRIPT_DIR}/update-agent-config.sh"
else
  UPDATE_CONFIG_CMD="update-agent-config"
fi

status_remove_entry() {
  local entry="$1"
  if [[ ! -f "$STATUS_FILE" ]]; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  grep -vF "  - ${entry}" "$STATUS_FILE" > "$tmp"
  mv "$tmp" "$STATUS_FILE"

  if ! grep -qE "^  - " "$STATUS_FILE"; then
    if ! grep -qvE "^(extra-instructions:|[[:space:]]*$)" "$STATUS_FILE"; then
      rm -f "$STATUS_FILE"
      rm -f "$EXTRA_INSTRUCTION_FILE"
    else
      # List is now empty but other keys remain; drop the dangling header.
      tmp="$(mktemp)"
      grep -vE "^extra-instructions:[[:space:]]*$" "$STATUS_FILE" > "$tmp"
      mv "$tmp" "$STATUS_FILE"
    fi
  fi
}

status_set_provider_mode() {
  local mode_slug="$1"
  if [[ ! -f "$STATUS_FILE" ]]; then
    printf "provider-mode: %s\n" "$mode_slug" > "$STATUS_FILE"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  if grep -qE "^provider-mode:" "$STATUS_FILE"; then
    sed "s|^provider-mode:.*|provider-mode: ${mode_slug}|" "$STATUS_FILE" > "$tmp"
  else
    cat "$STATUS_FILE" > "$tmp"
    echo "provider-mode: ${mode_slug}" >> "$tmp"
  fi
  mv "$tmp" "$STATUS_FILE"
}

get_provider_mode() {
  if [[ ! -f "$STATUS_FILE" ]]; then
    printf ''
    return 0
  fi

  grep "^provider-mode:" "$STATUS_FILE" 2>/dev/null | awk '{print $2}' || printf ''
}

get_current_provider() {
  local slug
  slug="$(get_provider_mode)"
  if [[ -z "$slug" ]]; then
    printf ''
    return 0
  fi

  if [[ "$slug" == "manual" ]]; then
    echo "manual"
    return 0
  fi

  local mode_file="${MODES_DIR}/${slug}.env"
  if [[ -f "$mode_file" ]]; then
    grep "^AI_PROVIDER=" "$mode_file" | sed 's/^AI_PROVIDER=//' || printf ''
  else
    printf ''
  fi
}

is_mode_configured() {
  [[ -f "$STATUS_FILE" ]] && grep -qE "^provider-mode: .+" "$STATUS_FILE"
}

is_gemma_extra_enabled() {
  [[ -f "$STATUS_FILE" ]] && grep -qE "^  - gemma$" "$STATUS_FILE"
}

disable_gemma_extra() {
  if [[ -f "$EXTRA_INSTRUCTION_FILE" ]]; then
    local tmp
    tmp="$(mktemp)"
    awk '
      /^<!-- gemma-start -->$/ { skip=1; next }
      skip && /^<!-- gemma-end -->$/ { skip=0; next }
      skip { next }
      { print }
    ' "$EXTRA_INSTRUCTION_FILE" > "$tmp"
    mv "$tmp" "$EXTRA_INSTRUCTION_FILE"
    enforce_managed_file_perms "$EXTRA_INSTRUCTION_FILE"
  fi

  status_remove_entry "gemma"
}

resolve_mode_file() {
  case "$MODE" in
    default)
      MODE_SLUG="${PROVIDER}-default"
      MODE_FILE="${MODES_DIR}/${MODE_SLUG}.env"
      ;;
    efficiency)
      MODE_SLUG="${PROVIDER}-token-efficiency"
      MODE_FILE="${MODES_DIR}/${MODE_SLUG}.env"
      ;;
    *)
      echo "Error: --mode must be 'default' or 'efficiency'." >&2
      exit 1
      ;;
  esac

  if [[ ! -f "$MODE_FILE" ]]; then
    echo "Error: mode file not found for provider '${PROVIDER}' and mode '${MODE}': $MODE_FILE" >&2
    exit 1
  fi
}

resolve_mode_file

if is_mode_configured; then
  current_provider="$(get_current_provider)"
  if [[ "$current_provider" == "manual" ]]; then
    echo "Error: current provider mode is manually customized. Create a new container to switch providers." >&2
    exit 1
  fi
  if [[ -n "$current_provider" && "$current_provider" != "$PROVIDER" ]]; then
    echo "Error: current provider is locked to '${current_provider}'. Create a new container to switch to '${PROVIDER}'." >&2
    exit 1
  fi
fi

if is_gemma_extra_enabled; then
  disable_gemma_extra
fi

update_args=(
  --template "$DEFAULT_AGENT_CONFIG_FILE"
  --mode-file "$MODE_FILE"
  --model "$MODEL"
  --config "$AGENT_CONFIG_FILE"
)

if ! "$UPDATE_CONFIG_CMD" "${update_args[@]}"; then
  echo "Error: failed to update agent config." >&2
  exit 1
fi

status_set_provider_mode "$MODE_SLUG"

label="$(grep "^# label:" "$MODE_FILE" | sed 's/^# label: *//' || echo "$MODE_SLUG")"

echo "Mode set to: ${label}"
echo "Applied settings:"
echo "  AI_PROVIDER=${PROVIDER}"
echo "  AI_MODEL=${MODEL}"
while IFS= read -r line; do
  [[ "$line" =~ ^# ]] && continue
  [[ -z "${line// }" ]] && continue
  [[ "$line" =~ ^AI_PROVIDER= ]] && continue
  echo "  ${line}"
done < "$MODE_FILE"


