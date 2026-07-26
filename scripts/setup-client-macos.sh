#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONNECTION_FILE="${1:-}"
APP_SOURCE="$ROOT/Liaison Client.app"
CLI_SOURCE="$ROOT/bin/liaison-cli"
APP_DESTINATION="$HOME/Applications/Liaison Client.app"
TOOLS_DIRECTORY="$HOME/Library/Application Support/Liaison Client/bin"
CONFIG_DIRECTORY="$HOME/Library/Application Support/Liaison"
CONFIG_PATH="$CONFIG_DIRECTORY/client.json"

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

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer must be run on macOS." >&2
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Warning: this package is built for Apple silicon (arm64)." >&2
fi

if [[ ! -d "$APP_SOURCE" || ! -f "$CLI_SOURCE" ]]; then
  echo "The Liaison Client package is incomplete." >&2
  exit 1
fi

if ! CONNECTION_FILE="$(find_connection_file "$CONNECTION_FILE")"; then
  echo "liaison-client.json was not found." >&2
  echo "Copy the file created by the server into this package folder and run again." >&2
  exit 1
fi

ADDRESS="$(/usr/bin/plutil -extract address raw -o - "$CONNECTION_FILE" 2>/dev/null || true)"
TOKEN="$(/usr/bin/plutil -extract token raw -o - "$CONNECTION_FILE" 2>/dev/null || true)"
if [[ -z "$ADDRESS" || ${#TOKEN} -lt 16 ]]; then
  echo "The connection file is invalid: $CONNECTION_FILE" >&2
  exit 1
fi

echo "Installing Liaison Client for Apple silicon..."
mkdir -p "$HOME/Applications" "$TOOLS_DIRECTORY" "$CONFIG_DIRECTORY"
rm -rf "$APP_DESTINATION"
cp -R "$APP_SOURCE" "$APP_DESTINATION"
cp "$CLI_SOURCE" "$TOOLS_DIRECTORY/liaison-cli"
cp "$CONNECTION_FILE" "$CONFIG_PATH"
chmod +x "$APP_DESTINATION/Contents/MacOS/liaison-desktop" "$TOOLS_DIRECTORY/liaison-cli"

# Apply an ad-hoc local signature so the copied app bundle has a coherent signature.
/usr/bin/codesign --force --deep --sign - "$APP_DESTINATION" >/dev/null 2>&1 || true

echo "Checking the server connection at $ADDRESS..."
if "$TOOLS_DIRECTORY/liaison-cli" --address "$ADDRESS" --token "$TOKEN" health >/dev/null; then
  echo "Connection: OK"
else
  echo "Warning: the client was installed, but the server is not reachable." >&2
  echo "Check the server, Tailscale, and the connection file." >&2
fi

echo "Installed: $APP_DESTINATION"
echo "Configuration: $CONFIG_PATH"
echo "Opening Liaison Client..."
/usr/bin/open "$APP_DESTINATION"
