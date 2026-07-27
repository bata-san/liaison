#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${LIAISON_PORT:-57841}"
LOCAL_ONLY="${LIAISON_LOCAL_ONLY:-0}"
SERVER_SOURCE="$ROOT/bin/liaison-service"
CLI_SOURCE="$ROOT/bin/liaison-cli"
CONFIG_TEMPLATE="$ROOT/config/liaison.example.json"
INSTALL_DIRECTORY="$HOME/Library/Application Support/Liaison Server"
BIN_DIRECTORY="$INSTALL_DIRECTORY/bin"
STARTER_PATH="$INSTALL_DIRECTORY/start-server.sh"
CONFIG_DIRECTORY="$HOME/Library/Application Support/Liaison"
CONFIG_PATH="$CONFIG_DIRECTORY/liaison.json"
DATA_DIRECTORY="$CONFIG_DIRECTORY/runtime-data"
LOG_DIRECTORY="$CONFIG_DIRECTORY/logs"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/dev.batasan.liaison.server.plist"
CONNECTION_FILE="$HOME/Desktop/liaison-client.json"
PAIRING_FILE="$HOME/Desktop/Liaison Pairing Code.txt"
LABEL="dev.batasan.liaison.server"
SERVICE_PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

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

if ! command -v colima >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
  echo "The headless Colima Docker runtime was not found." >&2
  echo "Run Install Liaison Server.command again without skipping dependencies." >&2
  exit 1
fi

if ! colima status >/dev/null 2>&1; then
  colima start --runtime docker
fi
if ! docker info >/dev/null 2>&1; then
  echo "The Colima Docker runtime is not ready." >&2
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
/usr/bin/plutil -replace runtime -string "wsl-docker" "$CONFIG_PATH"
/usr/bin/plutil -replace wsl_distribution -string "native-docker" "$CONFIG_PATH"
/usr/bin/plutil -replace data_directory -string "$DATA_DIRECTORY" "$CONFIG_PATH"
/usr/bin/plutil -replace auto_tune -bool YES "$CONFIG_PATH"
/usr/bin/plutil -convert json -o "$CONFIG_PATH.tmp" "$CONFIG_PATH"
mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"

cat > "$STARTER_PATH" <<SCRIPT
#!/bin/bash
set -euo pipefail
export PATH="$SERVICE_PATH"
if ! colima status >/dev/null 2>&1; then
  colima start --runtime docker >> "$LOG_DIRECTORY/colima.log" 2>&1
fi
exec "$BIN_DIRECTORY/liaison-service" --console --config "$CONFIG_PATH"
SCRIPT
chmod +x "$STARTER_PATH"

cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$STARTER_PATH</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$SERVICE_PATH</string>
    <key>HOME</key>
    <string>$HOME</string>
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
for _ in $(seq 1 60); do
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
TAILSCALE_BIN="$(command -v tailscale 2>/dev/null || true)"

if [[ "$LOCAL_ONLY" != "1" && -n "$TAILSCALE_BIN" ]]; then
  TAILSCALE_IP="$(/usr/bin/sudo "$TAILSCALE_BIN" ip -4 2>/dev/null | head -n 1 || true)"
  if [[ -n "$TAILSCALE_IP" ]] \
    && /usr/bin/sudo "$TAILSCALE_BIN" serve --yes --bg --tcp="$PORT" "tcp://127.0.0.1:$PORT" >/dev/null 2>&1; then
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
      echo "Warning: Tailscale forwarding did not pass the health check." >&2
    fi
  else
    echo "Warning: Tailscale TCP forwarding could not be configured." >&2
  fi
fi

SERVER_NAME="$(/bin/hostname -s | /usr/bin/tr -cd 'A-Za-z0-9._-')"
PAIRING_CODE="liaison://connect?address=$CLIENT_ADDRESS&token=$TOKEN"
cat > "$CONNECTION_FILE" <<JSON
{
  "version": 1,
  "server_name": "$SERVER_NAME",
  "address": "$CLIENT_ADDRESS",
  "token": "$TOKEN",
  "transport": "$TRANSPORT",
  "pairing_code": "$PAIRING_CODE"
}
JSON
cat > "$PAIRING_FILE" <<TEXT
Liaison Server: $SERVER_NAME
Address: $CLIENT_ADDRESS
Token: $TOKEN

Pairing code:
$PAIRING_CODE
TEXT
chmod 600 "$CONFIG_PATH" "$CONNECTION_FILE" "$PAIRING_FILE"

echo ""
echo "Server setup completed."
echo "Server address: $CLIENT_ADDRESS"
echo "Transport: $TRANSPORT"
echo "Pairing code: $PAIRING_CODE"
echo "Connection file: $CONNECTION_FILE"
echo "The server runs with Colima and the tailscaled system service; no Docker Desktop or Tailscale GUI is required."
echo "Apple GPU assignment remains disabled for regular Docker workers."
