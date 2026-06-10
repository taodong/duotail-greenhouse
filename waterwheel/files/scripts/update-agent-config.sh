#!/usr/bin/env bash

set -euo pipefail

MODE_FILE=""
MODEL_VALUE=""
CONFIG_FILE=""
EXTRA_SETTINGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode-file)
      MODE_FILE="${2:?--mode-file requires a value}"
      shift 2
      ;;
    --model)
      MODEL_VALUE="${2:?--model requires a value}"
      shift 2
      ;;
    --config)
      CONFIG_FILE="${2:?--config requires a value}"
      shift 2
      ;;
    --set)
      EXTRA_SETTINGS+=("${2:?--set requires a KEY=VALUE value}")
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $(basename "$0") --mode-file <path> --model <value> --config <json-path> [--set KEY=VALUE ...]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$MODE_FILE" || -z "$MODEL_VALUE" || -z "$CONFIG_FILE" ]]; then
  echo "Error: --mode-file, --model, and --config are all required." >&2
  echo "Usage: $(basename "$0") --mode-file <path> --model <value> --config <json-path> [--set KEY=VALUE ...]" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: $CONFIG_FILE not found. Please pull a new image." >&2
  exit 1
fi

tmp="$(mktemp)"
cp "$CONFIG_FILE" "$tmp"

while IFS= read -r line; do
  [[ "$line" =~ ^# ]] && continue
  [[ -z "${line// }" ]] && continue
  if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    tmp2="$(mktemp)"
    jq --arg k "$key" --arg v "$value" \
      '.["env-params"] |= map(if .name == $k then .default = $v else . end)' \
      "$tmp" > "$tmp2"
    mv "$tmp2" "$tmp"
  fi
done < "$MODE_FILE"

tmp2="$(mktemp)"
jq --arg v "$MODEL_VALUE" \
  '.["env-params"] |= map(if .name == "AI_MODEL" then .default = $v else . end)' \
  "$tmp" > "$tmp2"
mv "$tmp2" "$tmp"

for setting in "${EXTRA_SETTINGS[@]+"${EXTRA_SETTINGS[@]}"}"; do
  if [[ "$setting" =~ ^([^=]+)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    tmp2="$(mktemp)"
    jq --arg k "$key" --arg v "$value" \
      '.["env-params"] |= map(if .name == $k then .default = $v else . end)' \
      "$tmp" > "$tmp2"
    mv "$tmp2" "$tmp"
  fi
done

# Use cat to preserve original inode, ownership, and permissions
cat "$tmp" > "$CONFIG_FILE"
rm -f "$tmp"

echo "Updated $CONFIG_FILE"
