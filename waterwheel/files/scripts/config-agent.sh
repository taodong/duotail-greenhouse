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
STATUS_FILE="${CONFIG_HELPERS_PATH}/agent-config-status.yaml"

HOST_TESTING_START="<!-- host-testing-start -->"
HOST_TESTING_END="<!-- host-testing-end -->"

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
    rm -f "$STATUS_FILE"
    rm -f "$EXTRA_INSTRUCTION_FILE"
  fi
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
              echo "     instead and enable 'Test web app on host' (item 2) from the main menu."
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
  while true; do
    local host_testing_status
    if is_host_testing_enabled; then
      host_testing_status="enabled"
    else
      host_testing_status="disabled"
    fi

    print_header
    echo "  Select an item to configure:"
    echo ""
    echo "  1. Config domain permissions"
    echo "  2. Test web app on host [${host_testing_status}]"
    echo "  0. Exit"
    echo ""
    print_divider
    printf "  Choice: "
    read -r choice

    case "$choice" in
      1) config_domain_permissions ;;
      2) config_host_testing ;;
      0|q|Q|exit|quit)
        exit 0
        ;;
      *)
        echo ""
        echo "  Unknown option: $choice"
        ;;
    esac
  done
}

main
