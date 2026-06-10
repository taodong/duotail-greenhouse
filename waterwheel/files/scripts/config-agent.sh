#!/usr/bin/env bash

set -euo pipefail

AGENT_PATH="/agent"
CONFIG_HELPERS_PATH="/config-helpers"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -ap|--agent-path)
      AGENT_PATH="${2:?--agent-path requires a value}"
      shift 2
      ;;
    -cp|--config-helpers-path)
      CONFIG_HELPERS_PATH="${2:?--config-helpers-path requires a value}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $(basename "$0") [-ap|--agent-path <path>] [-cp|--config-helpers-path <path>]" >&2
      exit 1
      ;;
  esac
done

ALLOWED_DOMAINS_FILE="${AGENT_PATH}/instructions/allowed-domains.yaml"
EXTRA_INSTRUCTION_FILE="${AGENT_PATH}/instructions/extra-instruction.md"
EXTRA_LOCAL_FILE="${CONFIG_HELPERS_PATH}/extra-local.md"
EXTRA_GEMMA_FILE="${CONFIG_HELPERS_PATH}/extra-gemma.md"
STATUS_FILE="${CONFIG_HELPERS_PATH}/agent-config-status.yaml"
SYSTEM_PROMPT_FILE="${AGENT_PATH}/config/system.prompt.md"
SYSTEM_PROMPT_CN="${CONFIG_HELPERS_PATH}/system-prompt-cn.md"
SYSTEM_PROMPT_DEFAULT="${CONFIG_HELPERS_PATH}/system-prompt-default.md"
AGENT_CONFIG_FILE="${AGENT_PATH}/config/agent-config.json"
MODES_DIR="${CONFIG_HELPERS_PATH}/modes"

# Resolve update-agent-config: prefer same directory (local dev), fall back to PATH (container)
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_SCRIPT_DIR}/update-agent-config.sh" ]]; then
  UPDATE_CONFIG_CMD="${_SCRIPT_DIR}/update-agent-config.sh"
else
  UPDATE_CONFIG_CMD="update-agent-config"
fi

HOST_TESTING_START="<!-- host-testing-start -->"
HOST_TESTING_END="<!-- host-testing-end -->"
GEMMA_START="<!-- gemma-start -->"
GEMMA_END="<!-- gemma-end -->"

# ── helpers ──────────────────────────────────────────────────────────────────

print_header() {
  echo ""
  echo "========================================"
  echo "  Waterwheel Agent Configuration"
  echo "========================================"
  echo ""
}

print_divider() {
  echo "----------------------------------------"
}

# ── status file ───────────────────────────────────────────────────────────────

# Add an entry to the extra-instructions array in the status file.
status_add_entry() {
  local entry="$1"
  if [[ ! -f "$STATUS_FILE" ]]; then
    printf "extra-instructions:\n  - %s\n" "$entry" > "$STATUS_FILE"
  elif ! grep -qF "  - ${entry}" "$STATUS_FILE"; then
    if ! grep -qE "^extra-instructions:" "$STATUS_FILE"; then
      echo "extra-instructions:" >> "$STATUS_FILE"
    fi
    echo "  - ${entry}" >> "$STATUS_FILE"
  fi
}

# Remove an entry from the status file. If no entries remain, delete the
# status file and extra-instruction.md.
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
    fi
  fi
}

# ── provider mode status ──────────────────────────────────────────────────────

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
    echo ""
    return 0
  fi
  grep "^provider-mode:" "$STATUS_FILE" 2>/dev/null | awk '{print $2}' || echo ""
}

get_provider_mode_label() {
  local slug
  slug="$(get_provider_mode)"
  if [[ -z "$slug" ]]; then
    echo "not set"
    return 0
  fi
  if [[ "$slug" == "manual" ]]; then
    echo "Manual customized"
    return 0
  fi
  local mode_file="${MODES_DIR}/${slug}.env"
  if [[ -f "$mode_file" ]]; then
    grep "^# label:" "$mode_file" | sed 's/^# label: *//' || echo "$slug"
  else
    echo "$slug"
  fi
}

get_current_provider() {
  local slug
  slug="$(get_provider_mode)"
  if [[ -z "$slug" ]]; then
    echo ""
    return 0
  fi
  if [[ "$slug" == "manual" ]]; then
    echo "manual"
    return 0
  fi
  local mode_file="${MODES_DIR}/${slug}.env"
  if [[ -f "$mode_file" ]]; then
    grep "^# provider:" "$mode_file" | sed 's/^# provider: *//' || echo ""
  else
    echo ""
  fi
}

is_mode_configured() {
  [[ -f "$STATUS_FILE" ]] && grep -qE "^provider-mode: .+" "$STATUS_FILE"
}

# ── gemma extra instruction ───────────────────────────────────────────────────

is_gemma_extra_enabled() {
  [[ -f "$STATUS_FILE" ]] && grep -qE "^  - gemma$" "$STATUS_FILE"
}

enable_gemma_extra() {
  if [[ ! -f "$EXTRA_GEMMA_FILE" ]]; then
    echo "  Error: $EXTRA_GEMMA_FILE not found."
    return 1
  fi

  if [[ ! -f "$EXTRA_INSTRUCTION_FILE" ]]; then
    local dir
    dir="$(dirname "$EXTRA_INSTRUCTION_FILE")"
    if [[ ! -d "$dir" ]]; then
      mkdir -p "$dir"
    fi
    printf "# Extra Test Instruction\n\n## Global Rules\n" > "$EXTRA_INSTRUCTION_FILE"
  fi

  {
    printf "\n%s\n" "$GEMMA_START"
    cat "$EXTRA_GEMMA_FILE"
    printf "\n%s\n" "$GEMMA_END"
  } >> "$EXTRA_INSTRUCTION_FILE"

  status_add_entry "gemma"
}

disable_gemma_extra() {
  if [[ -f "$EXTRA_INSTRUCTION_FILE" ]]; then
    local tmp
    tmp="$(mktemp)"
    awk "
      /^<!-- gemma-start -->$/ { skip=1; next }
      skip && /^<!-- gemma-end -->$/ { skip=0; next }
      skip { next }
      { print }
    " "$EXTRA_INSTRUCTION_FILE" > "$tmp"
    mv "$tmp" "$EXTRA_INSTRUCTION_FILE"
  fi

  status_remove_entry "gemma"
}

# ── system prompt ────────────────────────────────────────────────────────────

is_cn_prompt_enabled() {
  [[ -f "$STATUS_FILE" ]] && grep -qE "^system-prompt: cn" "$STATUS_FILE"
}

status_set_system_prompt() {
  local value="$1"
  if [[ ! -f "$STATUS_FILE" ]]; then
    printf "system-prompt: %s\n" "$value" > "$STATUS_FILE"
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  if grep -qE "^system-prompt:" "$STATUS_FILE"; then
    sed "s|^system-prompt:.*|system-prompt: ${value}|" "$STATUS_FILE" > "$tmp"
  else
    cat "$STATUS_FILE" > "$tmp"
    echo "system-prompt: ${value}" >> "$tmp"
  fi
  mv "$tmp" "$STATUS_FILE"
}

status_clear_system_prompt() {
  if [[ ! -f "$STATUS_FILE" ]]; then
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  grep -vE "^system-prompt:" "$STATUS_FILE" > "$tmp"
  mv "$tmp" "$STATUS_FILE"
}

enable_cn_prompt() {
  if [[ ! -f "$SYSTEM_PROMPT_CN" ]]; then
    echo "  Error: $SYSTEM_PROMPT_CN not found."
    return 1
  fi
  if [[ ! -f "$SYSTEM_PROMPT_FILE" ]]; then
    echo "  Warning: $SYSTEM_PROMPT_FILE not found. Cannot set Chinese prompt."
    return 1
  fi
  cat "$SYSTEM_PROMPT_CN" > "$SYSTEM_PROMPT_FILE"
  status_set_system_prompt "cn"
  echo "  Chinese system prompt enabled."
}

disable_cn_prompt() {
  if [[ ! -f "$SYSTEM_PROMPT_DEFAULT" ]]; then
    echo "  Warning: $SYSTEM_PROMPT_DEFAULT not found. Cannot restore default prompt."
    return 1
  fi
  if [[ -f "$SYSTEM_PROMPT_FILE" ]]; then
    cat "$SYSTEM_PROMPT_DEFAULT" > "$SYSTEM_PROMPT_FILE"
  fi
  status_clear_system_prompt
  echo "  Default system prompt restored."
}

# ── ai mode config ────────────────────────────────────────────────────────────

config_ai_mode() {
  while true; do
    local is_initial=false
    if ! is_mode_configured; then
      is_initial=true
    fi

    local mode_files=()
    for f in "${MODES_DIR}"/*.env; do
      [[ -f "$f" ]] && mode_files+=("$f")
    done

    local current_label
    current_label="$(get_provider_mode_label)"

    echo ""
    echo "=== AI Provider Mode [${current_label}] ==="
    echo ""

    if [[ ${#mode_files[@]} -eq 0 ]]; then
      echo "  No mode files found in ${MODES_DIR}."
      echo ""
      print_divider
      if [[ "$is_initial" == false ]]; then
        echo "  0) Back"
        print_divider
      fi
      printf "  Choice: "
      read -r _unused
      return 0
    fi

    # In normal mode, filter to same-provider options only.
    local display_files=()
    if [[ "$is_initial" == false ]]; then
      local current_provider
      current_provider="$(get_current_provider)"
      if [[ -n "$current_provider" ]]; then
        if [[ "$current_provider" == "manual" ]]; then
          echo "  To switch to a different AI provider, please create a new container."
          echo ""
          print_divider
          echo "  0) Back"
          print_divider
          printf "  Choice: "
          read -r _unused
          return 0
        fi
        for f in "${mode_files[@]}"; do
          local fp
          fp="$(grep "^# provider:" "$f" | sed 's/^# provider: *//' || echo "")"
          [[ "$fp" == "$current_provider" ]] && display_files+=("$f")
        done
        if [[ ${#display_files[@]} -le 1 ]]; then
          echo "  To switch to a different AI provider, please create a new container."
          echo ""
          print_divider
          echo "  0) Back"
          print_divider
          printf "  Choice: "
          read -r _unused
          return 0
        fi
      else
        display_files=("${mode_files[@]}")
      fi
    else
      display_files=("${mode_files[@]}")
    fi

    echo "  Select a mode:"
    echo ""
    local i=1
    for f in "${display_files[@]}"; do
      local label
      label="$(grep "^# label:" "$f" | sed 's/^# label: *//')"
      printf "  %d) %s\n" "$i" "$label"
      ((i++))
    done
    local manual_opt=$i
    if [[ "$is_initial" == true ]]; then
      printf "  %d) Manual customized\n" "$manual_opt"
    fi
    echo ""
    print_divider
    if [[ "$is_initial" == false ]]; then
      echo "  0) Back"
    fi
    print_divider
    printf "  Choice: "
    read -r choice

    if [[ "$is_initial" == false ]] && [[ "$choice" == "0" ]]; then
      return 0
    elif [[ "$is_initial" == true ]] && [[ "$choice" == "0" ]]; then
      echo "  Please select an AI provider mode before continuing."
      continue
    elif [[ "$is_initial" == true ]] && [[ "$choice" == "$manual_opt" ]]; then
      echo ""
      echo "  ⚠  Note: Once saved, switching to a different AI provider requires creating a new container."
      echo ""
      printf "  Mark mode as manually customized? [y/N]: "
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if is_gemma_extra_enabled; then
          disable_gemma_extra
        fi
        if is_cn_prompt_enabled; then
          disable_cn_prompt
        fi
        status_set_provider_mode "manual"
        echo "  Mode set to: Manual customized"
        [[ "$is_initial" == true ]] && return 0
      fi
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < manual_opt )); then
      local selected_file="${display_files[$((choice-1))]}"
      local label
      label="$(grep "^# label:" "$selected_file" | sed 's/^# label: *//')"
      local recommended
      recommended="$(grep "^# recommendation:" "$selected_file" | sed 's/^# recommendation: *//' || echo "")"
      local notes
      notes="$(grep "^# notes:" "$selected_file" | sed 's/^# notes: *//' || echo "")"

      if [[ -n "$notes" ]]; then
        echo ""
        echo "  Notes: ${notes}"
      fi

      printf "  Enter AI model"
      [[ -n "$recommended" ]] && printf " [recommended: %s]" "$recommended"
      printf ": "
      read -r model_input
      local model="${model_input:-$recommended}"
      if [[ -z "$model" ]]; then
        echo "  No model provided, skipping."
        continue
      fi

      local is_gemma=false
      local base_url=""
      if grep -q "^AI_PROVIDER=gemma" "$selected_file"; then
        is_gemma=true
        printf "  Enter Ollama base URL (e.g. http://host.docker.internal:11434): "
        read -r base_url
      fi

      if [[ "$is_initial" == true ]]; then
        echo ""
        echo "  ⚠  Note: Once saved, switching to a different AI provider requires creating a new container."
        echo ""
      fi

      if [[ "$is_gemma" == true && -n "$base_url" ]]; then
        printf "  Apply '%s' with model '%s' and base URL '%s'? [y/N]: " "$label" "$model" "$base_url"
      else
        printf "  Apply '%s' with model '%s'? [y/N]: " "$label" "$model"
      fi
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if is_gemma_extra_enabled; then
          disable_gemma_extra
        fi

        local update_args=(--mode-file "$selected_file" --model "$model" --config "$AGENT_CONFIG_FILE")
        [[ "$is_gemma" == true && -n "$base_url" ]] && update_args+=(--set "AI_BASE_URL=${base_url}")

        if ! "$UPDATE_CONFIG_CMD" "${update_args[@]}"; then
          echo "  Failed to update agent config."
          continue
        fi

        local slug
        slug="$(basename "$selected_file" .env)"
        status_set_provider_mode "$slug"

        if [[ "$is_gemma" == true ]]; then
          enable_gemma_extra
        fi

        local is_deepseek=false
        if grep -q "^AI_PROVIDER=deepseek" "$selected_file"; then
          is_deepseek=true
        fi

        if [[ "$is_deepseek" == true ]]; then
          echo ""
          printf "  Use Chinese system prompt? [y/N]: "
          read -r cn_choice
          if [[ "$cn_choice" =~ ^[Yy]$ ]]; then
            enable_cn_prompt
          elif is_cn_prompt_enabled; then
            disable_cn_prompt
          fi
        elif is_cn_prompt_enabled; then
          disable_cn_prompt
        fi

        echo ""
        echo "  Mode set to: ${label} (model: ${model})"
        echo ""
        echo "  Applied settings:"
        while IFS= read -r line; do
          [[ "$line" =~ ^# ]] && continue
          [[ -z "${line// }" ]] && continue
          echo "    ${line}"
        done < "$selected_file"
        echo "    AI_MODEL=${model}"
        [[ "$is_gemma" == true && -n "$base_url" ]] && echo "    AI_BASE_URL=${base_url}"

        [[ "$is_initial" == true ]] && return 0
      fi
    else
      echo "  Unknown option: $choice"
    fi
  done
}

# ── domain config ─────────────────────────────────────────────────────────────

load_domains() {
  DOMAINS=()
  if [[ ! -f "$ALLOWED_DOMAINS_FILE" ]]; then
    return 0
  fi
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
      domain="${BASH_REMATCH[1]}"
      [[ -n "$domain" ]] && DOMAINS+=("$domain")
    fi
  done < "$ALLOWED_DOMAINS_FILE"
}

save_domains() {
  if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    rm -f "$ALLOWED_DOMAINS_FILE"
    echo ""
    echo "  (only empty page is allowed)"
    return 0
  fi

  local dir
  dir="$(dirname "$ALLOWED_DOMAINS_FILE")"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
  fi

  {
    echo "allowed:"
    for d in "${DOMAINS[@]}"; do
      echo "  - $d"
    done
  } > "$ALLOWED_DOMAINS_FILE"

  echo ""
  echo "Saved to $ALLOWED_DOMAINS_FILE"
}

config_domain_permissions() {
  load_domains
  local working=("${DOMAINS[@]+"${DOMAINS[@]}"}")
  local changed=false

  while true; do
    echo ""
    echo "=== Config Domain Permissions ==="
    echo ""

    if [[ ${#working[@]} -eq 0 ]]; then
      echo "  (only empty page is allowed)"
    else
      echo "  Current allowed domains:"
      local i=1
      for d in "${working[@]}"; do
        printf "    %d. %s\n" "$i" "$d"
        ((i++))
      done
    fi

    echo ""
    print_divider
    echo "  1) Add domain"
    [[ ${#working[@]} -gt 0 ]] && echo "  2) Delete domain"
    [[ "$changed" == true ]] && echo "  3) Save changes"
    echo "  0) Back"
    print_divider
    printf "  Choice: "
    read -r choice

    case "$choice" in
      1)
        printf "  Enter domain URL (e.g. https://example.com): "
        read -r new_domain
        new_domain="${new_domain// /}"
        if [[ -z "$new_domain" ]]; then
          echo "  No domain entered, skipping."
        else
          local dup=false
          for d in "${working[@]+"${working[@]}"}"; do
            [[ "$d" == "$new_domain" ]] && dup=true && break
          done
          if [[ "$dup" == true ]]; then
            echo "  Domain already exists."
          else
            working+=("$new_domain")
            changed=true
            echo "  Added: $new_domain"
            if [[ "$new_domain" == *localhost* ]]; then
              echo ""
              echo "  ⚠  Warning: localhost is not reachable inside the container."
              echo "     If the website runs on the host machine, use host.docker.internal"
              echo "     instead and enable 'Test web app on host' (item 3) from the main menu."
              echo ""
            fi
          fi
        fi
        ;;

      2)
        if [[ ${#working[@]} -eq 0 ]]; then
          echo "  Nothing to delete."
          continue
        fi
        printf "  Enter the number of the domain to delete: "
        read -r idx
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#working[@]} )); then
          echo "  Invalid selection."
        else
          local removed="${working[$((idx-1))]}"
          working=("${working[@]:0:$((idx-1))}" "${working[@]:$((idx))}")
          changed=true
          echo "  Removed: $removed"
        fi
        ;;

      3)
        if [[ "$changed" != true ]]; then
          echo "  No changes to save."
          continue
        fi
        printf "  Save %d domain(s) to %s? [y/N]: " "${#working[@]}" "$ALLOWED_DOMAINS_FILE"
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          DOMAINS=("${working[@]+"${working[@]}"}")
          save_domains
          changed=false
        fi
        ;;

      0)
        if [[ "$changed" == true ]]; then
          printf "  You have unsaved changes. Discard and go back? [y/N]: "
          read -r confirm
          if [[ "$confirm" =~ ^[Yy]$ ]]; then
            return 0
          fi
        else
          return 0
        fi
        ;;

      *)
        echo "  Unknown option: $choice"
        ;;
    esac
  done
}

# ── host testing config ───────────────────────────────────────────────────────

is_host_testing_enabled() {
  [[ -f "$STATUS_FILE" ]] && grep -qF "  - host-testing" "$STATUS_FILE"
}

enable_host_testing() {
  if [[ ! -f "$EXTRA_LOCAL_FILE" ]]; then
    echo "  Error: $EXTRA_LOCAL_FILE not found."
    return 1
  fi

  if [[ ! -f "$EXTRA_INSTRUCTION_FILE" ]]; then
    local dir
    dir="$(dirname "$EXTRA_INSTRUCTION_FILE")"
    if [[ ! -d "$dir" ]]; then
      mkdir -p "$dir"
    fi
    printf "# Extra Test Instruction\n\n## Global Rules\n" > "$EXTRA_INSTRUCTION_FILE"
  fi

  {
    printf "\n%s\n" "$HOST_TESTING_START"
    cat "$EXTRA_LOCAL_FILE"
    printf "\n%s\n" "$HOST_TESTING_END"
  } >> "$EXTRA_INSTRUCTION_FILE"

  status_add_entry "host-testing"

  if [[ -f "$ALLOWED_DOMAINS_FILE" ]] && grep -q "localhost" "$ALLOWED_DOMAINS_FILE"; then
    local tmp
    tmp="$(mktemp)"
    sed 's/localhost/host.docker.internal/g' "$ALLOWED_DOMAINS_FILE" > "$tmp"
    mv "$tmp" "$ALLOWED_DOMAINS_FILE"
    echo "  Updated allowed-domains.yaml: localhost -> host.docker.internal"
  fi

  echo "  Host testing enabled."
}

disable_host_testing() {
  if [[ -f "$EXTRA_INSTRUCTION_FILE" ]]; then
    local tmp
    tmp="$(mktemp)"
    awk "
      /^<!-- host-testing-start -->$/ { skip=1; next }
      skip && /^<!-- host-testing-end -->$/ { skip=0; next }
      skip { next }
      { print }
    " "$EXTRA_INSTRUCTION_FILE" > "$tmp"
    mv "$tmp" "$EXTRA_INSTRUCTION_FILE"
  fi

  # Removes the entry and deletes both status file + extra-instruction.md if
  # no entries remain.
  status_remove_entry "host-testing"

  if [[ -f "$ALLOWED_DOMAINS_FILE" ]] && grep -q "host\.docker\.internal" "$ALLOWED_DOMAINS_FILE"; then
    local tmp
    tmp="$(mktemp)"
    sed 's/host\.docker\.internal/localhost/g' "$ALLOWED_DOMAINS_FILE" > "$tmp"
    mv "$tmp" "$ALLOWED_DOMAINS_FILE"
    echo "  Updated allowed-domains.yaml: host.docker.internal -> localhost"
  fi

  echo "  Host testing disabled."
}

config_host_testing() {
  while true; do
    echo ""
    if is_host_testing_enabled; then
      echo "=== Test Web App on Host [enabled] ==="
      echo ""
      echo "  Host testing is currently enabled."
      echo ""
      print_divider
      echo "  1) Disable host testing"
      echo "  0) Back"
    else
      echo "=== Test Web App on Host [disabled] ==="
      echo ""
      echo "  Host testing is currently disabled."
      echo ""
      print_divider
      echo "  1) Enable host testing"
      echo "  0) Back"
    fi
    print_divider
    printf "  Choice: "
    read -r choice

    case "$choice" in
      1)
        if is_host_testing_enabled; then
          printf "  Disable host testing? [y/N]: "
          read -r confirm
          if [[ "$confirm" =~ ^[Yy]$ ]]; then
            disable_host_testing
          fi
        else
          printf "  Enable host testing? [y/N]: "
          read -r confirm
          if [[ "$confirm" =~ ^[Yy]$ ]]; then
            enable_host_testing
          fi
        fi
        ;;

      0)
        return 0
        ;;

      *)
        echo "  Unknown option: $choice"
        ;;
    esac
  done
}

# ── main menu ─────────────────────────────────────────────────────────────────

main() {
  if ! is_mode_configured; then
    echo ""
    echo "  No AI provider mode is configured. Please select one to continue."
    echo ""
    config_ai_mode
  fi

  while true; do
    local mode_label
    mode_label="$(get_provider_mode_label)"
    local host_testing_status
    if is_host_testing_enabled; then
      host_testing_status="enabled"
    else
      host_testing_status="disabled"
    fi

    print_header
    echo "  Select an item to configure:"
    echo ""
    echo "  1. AI provider mode [${mode_label}]"
    echo "  2. Config domain permissions"
    echo "  3. Test web app on host [${host_testing_status}]"
    echo "  0. Exit"
    echo ""
    print_divider
    printf "  Choice: "
    read -r choice

    case "$choice" in
      1) config_ai_mode ;;
      2) config_domain_permissions ;;
      3) config_host_testing ;;
      0|q|Q|exit|quit)
        if ! is_mode_configured && [[ -z "${AI_MODEL:-}" || -z "${AI_API_KEY:-}" ]]; then
          echo ""
          echo "  ⚠  Warning: No AI provider mode is configured."
          echo "     Select option 1 to configure, or ensure AI_PROVIDER, AI_MODEL,"
          echo "     and AI_API_KEY are set as environment variables before running the agent."
          echo ""
          printf "  Exit anyway? [y/N]: "
          read -r confirm
          if [[ "$confirm" =~ ^[Yy]$ ]]; then
            exit 0
          fi
        else
          exit 0
        fi
        ;;
      *)
        echo ""
        echo "  Unknown option: $choice"
        ;;
    esac
  done
}

main
