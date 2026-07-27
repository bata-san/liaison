#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${LIAISON_PORT:-57841}"
SERVER_SOURCE="$ROOT/bin/liaison-service"
CLI_SOURCE="$ROOT/bin/liaison-cli"
CONFIG_TEMPLATE="$ROOT/config/liaison.example.json"
INSTALL_DIRECTORY="$HOME/Library/Application Support/Liaison Server"
BIN_DIRECTORY="$INSTALL_DIRECTORY/bin"
CONFIG_DIRECTORY="$HOME/Library/Application Support/Liaison"
CONFIG_PATH="$CONFIG_DIRECTORY/liaison.json"
DATA_DIRECTORY="$CONFIG_DIRECTORY/runtime-data"
LOG_DIRECTORY="$CONFIG_DIRECTORY/logs"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/dev.batasan.liaison.server.plist"
CONNECTION_FILE="$HOME/Desktop/liaison-client.json"
LABEL="dev.batasan.liaison.server"
SERVICE_PATH="/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer must be run on macOS." >&2
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Warning: this package is built for Apple silicon (arm64)." >&2
fi

if [[ ! -f "$SERVER_SOURCE" || ! -f "$CLI_SOURCE" || ! -f "$CONFIG_TEMPLATE" ]]; then
  echo "The Liaison Server package is incomplete." >&2
  exit 1
fi

export PATH="$SERVICE_PATH"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker was not found. Install and start Docker Desktop first." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker Desktop is not running or is not ready." >&2
  exit 1
fi

TOKEN=""
if [[ -f "$CONFIG_PATH" ]]; then
  TOKEN="$(/usr/bin/plutil -extract auth_token raw -o - "$CONFIG_PATH" 2>/dev/null || true)"
fi
if [[ ${#TOKEN} -lt 16 || "$TOKEN" == change-* || "$TOKEN" == replace-* ]]; then
  TOKEN="$(/usr/bin/openssl rand -hex 32)"
fi

echo "Installing Liaison Server for Apple silicon..."
mkdir -p "$BIN_DIRECTORY" "$CONFIG_DIRECTORY" "$DATA_DIRECTORY" "$LOG_DIRECTORY" "$HOME/Library/LaunchAgents" "$HOME/Desktop"
cp "$SERVER_SOURCE" "$BIN_DIRECTORY/liaison-service"
cp "$CLI_SOURCE" "$BIN_DIRECTORY/liaison-cli"
chmod +x "$BIN_DIRECTORY/liaison-service" "$BIN_DIRECTORY/liaison-cli"

cp "$CONFIG_TEMPLATE" "$CONFIG_PATH"
/usr/bin/plutil -replace listen_address -string "127.0.0.1:$PORT" "$CONFIG_PATH"
/usr/bin/plutil -replace auth_token -string "$TOKEN" "$CONFIG_PATH"
# The serialized value remains wsl-docker for compatibility. On macOS the
# service maps it to the native Docker adapter and never invokes WSL.
/usr/bin/plutil -replace runtime -string "wsl-docker" "$CONFIG_PATH"
/usr/bin/plutil -replace wsl_distribution -string "native-docker" "$CONFIG_PATH"
/usr/bin/plutil -replace data_directory -string "$DATA_DIRECTORY" "$CONFIG_PATH"
/usr/bin/plutil -replace auto_tune -bool YES "$CONFIG_PATH"
/usr/bin/plutil -convert json -o "$CONFIG_PATH.tmp" "$CONFIG_PATH"
mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"

cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIRECTORY/liaison-service</string>
    <string>--console</string>
    <string>--config</string>
    <string>$CONFIG_PATH</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$SERVICE_PATH</string>
    <key>HOME</key>
    <string>$HOME</string>
    <key>TAILSCALE_BE_CLI</key>
    <string>1</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIRECTORY/server.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIRECTORY/server-error.log</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$LAUNCH_AGENT" >/dev/null
/bin/launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT"
/bin/launchctl kickstart -k "gui/$UID/$LABEL"

READY=0
for _ in $(seq 1 40); do
  sleep 0.25
  if "$BIN_DIRECTORY/liaison-cli" --address "127.0.0.1:$PORT" --token "$TOKEN" health >/dev/null 2>&1; then
    READY=1
    break
  fi
done
if [[ "$READY" -ne 1 ]]; then
  echo "The server did not pass its local health check." >&2
  echo "See: $LOG_DIRECTORY/server-error.log" >&2
  /bin/launchctl print "gui/$UID/$LABEL" 2>/dev/null | tail -n 30 >&2 || true
  exit 1
fi

TRANSPORT="local"
CLIENT_ADDRESS="127.0.0.1:$PORT"
TAILSCALE_BIN=""
if command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_BIN="$(command -v tailscale)"
elif [[ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]]; then
  TAILSCALE_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi

run_tailscale() {
  TAILSCALE_BE_CLI=1 "$TAILSCALE_BIN" "$@"
}

if [[ -n "$TAILSCALE_BIN" ]]; then
  TAILSCALE_IP="$(run_tailscale ip -4 2>/dev/null | head -n 1 || true)"
  if [[ -n "$TAILSCALE_IP" ]] \
    && run_tailscale serve --yes --bg --tcp="$PORT" "tcp://127.0.0.1:$PORT" >/dev/null 2>&1; then
    REMOTE_READY=0
    for _ in $(seq 1 20); do
      sleep 0.25
      if "$BIN_DIRECTORY/liaison-cli" --address "$TAILSCALE_IP:$PORT" --token "$TOKEN" health >/dev/null 2>&1; then
        REMOTE_READY=1
        break
      fi
    done
    if [[ "$REMOTE_READY" -eq 1 ]]; then
      TRANSPORT="tailscale"
      CLIENT_ADDRESS="$TAILSCALE_IP:$PORT"
      echo "Tailscale access configured and verified: $CLIENT_ADDRESS"
    else
      echo "Warning: Tailscale forwarding was configured but did not pass the health check." >&2
      echo "The generated connection file is valid only on this Mac." >&2
    fi
  else
    echo "Warning: Tailscale TCP forwarding could not be configured." >&2
    echo "The generated connection file is valid only on this Mac." >&2
  fi
else
  echo "Warning: Tailscale was not detected. The generated connection file is valid only on this Mac." >&2
fi

SERVER_NAME="$(/bin/hostname -s | /usr/bin/tr -cd 'A-Za-z0-9._-')"
cat > "$CONNECTION_FILE" <<JSON
{
  "version": 1,
  "server_name": "$SERVER_NAME",
  "address": "$CLIENT_ADDRESS",
  "token": "$TOKEN",
  "transport": "$TRANSPORT"
}
JSON
chmod 600 "$CONFIG_PATH" "$CONNECTION_FILE"

echo ""
echo "Server setup completed."
echo "Server address: $CLIENT_ADDRESS"
echo "Transport: $TRANSPORT"
echo "Client connection file: $CONNECTION_FILE"
if [[ "$TRANSPORT" == "tailscale" ]]; then
  echo "Copy liaison-client.json into the client package."
else
  echo "This connection file works only when the client runs on this same Mac."
  echo "For another computer, connect Tailscale and run this installer again."
fi
echo "Apple GPU assignment is disabled; CPU, memory, and Docker workers are available."
