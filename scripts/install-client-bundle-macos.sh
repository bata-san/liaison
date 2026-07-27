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

if ! CONNECTION_FILE="$(find_connection_file "$CONNECTION_FILE")"; then
  echo "liaison-client.json was not found." >&2
  echo "Copy the file created by the server into this folder." >&2
  exit 1
fi

TRANSPORT="$(/usr/bin/plutil -extract transport raw -o - "$CONNECTION_FILE" 2>/dev/null || true)"
if [[ "$SKIP_DEPENDENCIES" != "1" && "$TRANSPORT" == "tailscale" ]]; then
  if ! liaison_connect_tailscale 1 >/dev/null; then
    echo "Tailscale sign-in is required for this server connection." >&2
    exit 1
  fi
fi

exec /bin/bash "$SCRIPT_DIRECTORY/setup-client-macos.sh" "$CONNECTION_FILE"
