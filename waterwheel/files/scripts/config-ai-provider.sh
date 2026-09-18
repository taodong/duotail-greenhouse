#!/usr/bin/env bash
# Location: /usr/local/bin/config-ai-provider
# Description: Non-interactively applies an AI provider mode and model to agent-config.json.
set -euo pipefail

AGENT_PATH="/agent"
CONFIG_HELPERS_PATH="/config-helpers"
PROVIDER=""
MODEL=""
MODE=""
BASE_URL=""
EXTRA_HEADERS=""
TEMPERATURE=""
TEMPERATURE_ENABLED=""

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
Usage: $(basename "$0") --provider <provider> --model <model> --mode <default|efficiency> [options] [help|h|--help|-h]

Options:
  -p, --provider <value>              AI provider value to write to AI_PROVIDER (for example: openai)
  -m, --model <value>                 AI model value to write to AI_MODEL
      --mode <default|efficiency>     Mode selector mapped to <provider>-default.env or <provider>-token-efficiency.env
  -b, --base-url <url>                Value to write to AI_BASE_URL. Required for provider 'openai-compatible';
                                      honored by 'gemma'; ignored (with a warning) by every other provider.
      --extra-headers <json>          JSON object of string values to write to AI_EXTRA_HEADERS.
                                      Used only by provider 'openai-compatible'.
      --temperature <value>           Value to write to AI_TEMPERATURE.
                                      Sent only by provider 'openai-compatible'.
      --temperature-enabled <bool>    'true' or 'false', written to AI_TEMPERATURE_ENABLED. Set 'false' for
                                      reasoning models that reject a temperature field.
                                      Used only by provider 'openai-compatible'.
  -ap, --agent-path <path>            Override agent path (default: /agent)
  -cp, --config-helpers-path <path>   Override config helpers path (default: /config-helpers)
  -h, --help                          Show this help message
  h, help                             Show this help message

Notes:
  - This command mirrors the config_ai_mode update flow without interactive prompts.
  - Once a provider is configured, switching to a different provider is blocked just like config-agent.
  - Gemma extra-instruction handling is intentionally skipped.
  - AI_EXTRA_HEADERS is sensitive and routinely carries credentials: its value is never echoed,
    not even in validation errors.
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
    -b|--base-url)
      BASE_URL="${2:?--base-url requires a value}"
      shift 2
      ;;
    --extra-headers)
      EXTRA_HEADERS="${2:?--extra-headers requires a value}"
      shift 2
      ;;
    --temperature)
      TEMPERATURE="${2:?--temperature requires a value}"
      shift 2
      ;;
    --temperature-enabled)
      TEMPERATURE_ENABLED="${2:?--temperature-enabled requires a value}"
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

# Reads an env-param's current default out of the live agent-config.json.
# Empty when the file does not exist yet (first configuration).
current_config_value() {
  local key="$1"
  [[ -f "$AGENT_CONFIG_FILE" ]] || { printf ''; return 0; }
  jq -r --arg k "$key" '
    (."env-params" // []) | map(select(.name == $k)) | .[0].default // ""
  ' "$AGENT_CONFIG_FILE" 2>/dev/null || printf ''
}

# Trims surrounding whitespace (including tabs and CR from pasted input) and
# strips trailing slashes. The agent appends '/chat/completions' verbatim, so a
# trailing slash would produce a double slash that several gateways reject.
normalize_base_url() {
  local url="$1"
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"
  while [[ "$url" == */ ]]; do
    url="${url%/}"
  done
  printf '%s' "$url"
}

# Providers that consume each optional flag. A flag aimed at a provider that
# ignores it is a warning, not an error: the value is inert in agent-config.json,
# and erroring would make this command stricter than the agent it configures.
warn_if_ignored() {
  local flag="$1" used_by="$2"
  case " ${used_by} " in
    *" ${PROVIDER} "*) return 0 ;;
  esac
  echo "Warning: ${flag} is ignored by provider '${PROVIDER}' (used by: ${used_by// /, })." >&2
}

validate_optional_args() {
  if [[ "$PROVIDER" == "openai-compatible" && -z "$BASE_URL" ]]; then
    echo "Error: --base-url is required for provider 'openai-compatible'." >&2
    exit 1
  fi

  if [[ -n "$BASE_URL" ]]; then
    BASE_URL="$(normalize_base_url "$BASE_URL")"
    if [[ ! "$BASE_URL" =~ ^https?:// ]]; then
      echo "Error: --base-url must start with http:// or https://, received: '${BASE_URL}'." >&2
      exit 1
    fi
    if [[ "$BASE_URL" =~ [[:space:]] ]]; then
      echo "Error: --base-url must not contain whitespace, received: '${BASE_URL}'." >&2
      exit 1
    fi
    warn_if_ignored "--base-url" "gemma openai-compatible"
  fi

  if [[ -n "$EXTRA_HEADERS" ]]; then
    # Never echo the value: AI_EXTRA_HEADERS is sensitive and routinely carries
    # credentials. The agent omits it from its own errors for the same reason.
    if ! printf '%s' "$EXTRA_HEADERS" \
      | jq -e 'type == "object" and ([.[] | type] | all(. == "string"))' >/dev/null 2>&1; then
      echo "Error: --extra-headers must be a JSON object of string values (value omitted -- it is sensitive)." >&2
      exit 1
    fi
    warn_if_ignored "--extra-headers" "openai-compatible"
  fi

  if [[ -n "$TEMPERATURE" ]]; then
    if [[ ! "$TEMPERATURE" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
      echo "Error: --temperature must be a number, received: '${TEMPERATURE}'." >&2
      exit 1
    fi
    warn_if_ignored "--temperature" "openai-compatible"
  fi

  if [[ -n "$TEMPERATURE_ENABLED" ]]; then
    TEMPERATURE_ENABLED="$(printf '%s' "$TEMPERATURE_ENABLED" | tr '[:upper:]' '[:lower:]')"
    if [[ "$TEMPERATURE_ENABLED" != "true" && "$TEMPERATURE_ENABLED" != "false" ]]; then
      echo "Error: --temperature-enabled must be 'true' or 'false'." >&2
      exit 1
    fi
    warn_if_ignored "--temperature-enabled" "openai-compatible"
  fi
}

resolve_mode_file
validate_optional_args

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

# update-agent-config always rebuilds from the template, so any value not
# re-supplied here reverts to the template default. None of these four can come
# from a mode file, so carry the current config's values forward unless this
# invocation overrides them -- otherwise switching modes within a provider would
# silently drop a gateway's auth headers or a reasoning model's temperature opt-out.
# Written out per value rather than through a helper: a helper would have to run
# in a command substitution to return the value, and a subshell cannot record
# which values were carried.
CARRIED=()

EFFECTIVE_BASE_URL="$BASE_URL"
if [[ -z "$EFFECTIVE_BASE_URL" ]]; then
  EFFECTIVE_BASE_URL="$(current_config_value AI_BASE_URL)"
  [[ -n "$EFFECTIVE_BASE_URL" ]] && CARRIED+=("AI_BASE_URL")
fi

EFFECTIVE_EXTRA_HEADERS="$EXTRA_HEADERS"
if [[ -z "$EFFECTIVE_EXTRA_HEADERS" ]]; then
  EFFECTIVE_EXTRA_HEADERS="$(current_config_value AI_EXTRA_HEADERS)"
  [[ -n "$EFFECTIVE_EXTRA_HEADERS" ]] && CARRIED+=("AI_EXTRA_HEADERS")
fi

EFFECTIVE_TEMPERATURE="$TEMPERATURE"
if [[ -z "$EFFECTIVE_TEMPERATURE" ]]; then
  EFFECTIVE_TEMPERATURE="$(current_config_value AI_TEMPERATURE)"
  [[ -n "$EFFECTIVE_TEMPERATURE" ]] && CARRIED+=("AI_TEMPERATURE")
fi

EFFECTIVE_TEMPERATURE_ENABLED="$TEMPERATURE_ENABLED"
if [[ -z "$EFFECTIVE_TEMPERATURE_ENABLED" ]]; then
  EFFECTIVE_TEMPERATURE_ENABLED="$(current_config_value AI_TEMPERATURE_ENABLED)"
  [[ -n "$EFFECTIVE_TEMPERATURE_ENABLED" ]] && CARRIED+=("AI_TEMPERATURE_ENABLED")
fi

was_carried() {
  local key="$1" k
  for k in "${CARRIED[@]+"${CARRIED[@]}"}"; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

[[ -n "$EFFECTIVE_BASE_URL" ]] && update_args+=(--set "AI_BASE_URL=${EFFECTIVE_BASE_URL}")
[[ -n "$EFFECTIVE_EXTRA_HEADERS" ]] && update_args+=(--set "AI_EXTRA_HEADERS=${EFFECTIVE_EXTRA_HEADERS}")
[[ -n "$EFFECTIVE_TEMPERATURE" ]] && update_args+=(--set "AI_TEMPERATURE=${EFFECTIVE_TEMPERATURE}")
[[ -n "$EFFECTIVE_TEMPERATURE_ENABLED" ]] && update_args+=(--set "AI_TEMPERATURE_ENABLED=${EFFECTIVE_TEMPERATURE_ENABLED}")

if ! "$UPDATE_CONFIG_CMD" "${update_args[@]}"; then
  echo "Error: failed to update agent config." >&2
  exit 1
fi

status_set_provider_mode "$MODE_SLUG"

label="$(grep "^# label:" "$MODE_FILE" | sed 's/^# label: *//' || echo "$MODE_SLUG")"

# Keys a --set override already accounts for. A mode file line for any of these
# is superseded, so print the override once instead of both values.
overridden_keys=("AI_PROVIDER")
[[ -n "$EFFECTIVE_BASE_URL" ]] && overridden_keys+=("AI_BASE_URL")
[[ -n "$EFFECTIVE_EXTRA_HEADERS" ]] && overridden_keys+=("AI_EXTRA_HEADERS")
[[ -n "$EFFECTIVE_TEMPERATURE" ]] && overridden_keys+=("AI_TEMPERATURE")
[[ -n "$EFFECTIVE_TEMPERATURE_ENABLED" ]] && overridden_keys+=("AI_TEMPERATURE_ENABLED")

is_overridden() {
  local key="$1" k
  for k in "${overridden_keys[@]}"; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

echo "Mode set to: ${label}"
echo "Applied settings:"
echo "  AI_PROVIDER=${PROVIDER}"
echo "  AI_MODEL=${MODEL}"
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^# ]] && continue
  [[ -z "${line// }" ]] && continue
  is_overridden "${line%%=*}" && continue
  echo "  ${line}"
done < "$MODE_FILE"
# A carried-forward value is called out so it is never a silent surprise.
suffix_for() {
  was_carried "$1" && printf '%s' "   (kept from current config)" || printf ''
}

[[ -n "$EFFECTIVE_BASE_URL" ]] && echo "  AI_BASE_URL=${EFFECTIVE_BASE_URL}$(suffix_for AI_BASE_URL)"
[[ -n "$EFFECTIVE_TEMPERATURE" ]] && echo "  AI_TEMPERATURE=${EFFECTIVE_TEMPERATURE}$(suffix_for AI_TEMPERATURE)"
[[ -n "$EFFECTIVE_TEMPERATURE_ENABLED" ]] && echo "  AI_TEMPERATURE_ENABLED=${EFFECTIVE_TEMPERATURE_ENABLED}$(suffix_for AI_TEMPERATURE_ENABLED)"
# Value deliberately masked: AI_EXTRA_HEADERS is sensitive.
[[ -n "$EFFECTIVE_EXTRA_HEADERS" ]] && echo "  AI_EXTRA_HEADERS=<set>$(suffix_for AI_EXTRA_HEADERS)"

exit 0


