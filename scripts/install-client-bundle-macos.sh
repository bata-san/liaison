#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
source "$SCRIPT_DIRECTORY/bootstrap-dependencies-macos.sh"

CONNECTION_FILE="${1:-}"
SKIP_DEPENDENCIES="${LIAISON_SKIP_DEPENDENCIES:-0}"

find_connection_file() {
  local requested="$1"
  local candidates=(
    "$requested"
    "$ROOT/liaison-client.json"
    "$PWD/liaison-client.json"
    "$HOME/Desktop/liaison-client.json"
    "$HOME/Downloads/liaison-client.json"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

RESOLVED_CONNECTION_FILE=""
if RESOLVED_CONNECTION_FILE="$(find_connection_file "$CONNECTION_FILE")"; then
  TRANSPORT="$(/usr/bin/plutil -extract transport raw -o - "$RESOLVED_CONNECTION_FILE" 2>/dev/null || true)"
else
  TRANSPORT="tailscale"
fi

if [[ "$SKIP_DEPENDENCIES" != "1" && "$TRANSPORT" != "local" ]]; then
  if ! liaison_connect_tailscale 1 >/dev/null; then
    echo "Tailscale login was not completed. Liaison Client will still be installed." >&2
  fi
fi

if [[ -n "$RESOLVED_CONNECTION_FILE" ]]; then
  exec /bin/bash "$SCRIPT_DIRECTORY/setup-client-macos.sh" "$RESOLVED_CONNECTION_FILE"
else
  exec /bin/bash "$SCRIPT_DIRECTORY/setup-client-macos.sh"
fi
