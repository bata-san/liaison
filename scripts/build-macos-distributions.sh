#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIRECTORY="${1:-$ROOT/dist}"
SKIP_TESTS="${SKIP_TESTS:-0}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This distribution builder must run on macOS." >&2
  exit 1
fi

cd "$ROOT"

npm --prefix apps/liaison-desktop install
npm --prefix apps/liaison-desktop run build

if [[ "$SKIP_TESTS" != "1" ]]; then
  cargo test --workspace
fi

cargo build --release -p liaison-service -p liaison-cli
npm --prefix apps/liaison-desktop run tauri:build -- --bundles app --ci

SERVER_PACKAGE="$OUTPUT_DIRECTORY/liaison-server-macos-arm64"
CLIENT_PACKAGE="$OUTPUT_DIRECTORY/liaison-client-macos-arm64"
SERVER_ZIP="$OUTPUT_DIRECTORY/liaison-server-macos-arm64.zip"
CLIENT_ZIP="$OUTPUT_DIRECTORY/liaison-client-macos-arm64.zip"
CLIENT_APP="$CLIENT_PACKAGE/Liaison Client.app"

BUNDLED_APP=""
for candidate in \
  "$ROOT/target/release/bundle/macos/Liaison Client.app" \
  "$ROOT/apps/liaison-desktop/src-tauri/target/release/bundle/macos/Liaison Client.app"; do
  if [[ -d "$candidate" ]]; then
    BUNDLED_APP="$candidate"
    break
  fi
done

if [[ -z "$BUNDLED_APP" ]]; then
  BUNDLED_APP="$(find "$ROOT" -path '*/target/release/bundle/macos/*.app' -type d -maxdepth 9 -print -quit 2>/dev/null || true)"
fi
if [[ -z "$BUNDLED_APP" || ! -d "$BUNDLED_APP" ]]; then
  echo "The Tauri macOS application bundle was not found." >&2
  exit 1
fi

rm -rf "$SERVER_PACKAGE" "$CLIENT_PACKAGE" "$SERVER_ZIP" "$CLIENT_ZIP"
mkdir -p \
  "$SERVER_PACKAGE/bin" \
  "$SERVER_PACKAGE/scripts" \
  "$SERVER_PACKAGE/config" \
  "$CLIENT_PACKAGE/bin" \
  "$CLIENT_PACKAGE/scripts"

cp target/release/liaison-service "$SERVER_PACKAGE/bin/liaison-service"
cp target/release/liaison-cli "$SERVER_PACKAGE/bin/liaison-cli"
cp config/liaison.example.json "$SERVER_PACKAGE/config/liaison.example.json"
cp scripts/setup-server-macos.sh "$SERVER_PACKAGE/scripts/setup-server-macos.sh"
cp scripts/install-server-bundle-macos.sh "$SERVER_PACKAGE/scripts/install-server-bundle-macos.sh"
cp scripts/bootstrap-dependencies-macos.sh "$SERVER_PACKAGE/scripts/bootstrap-dependencies-macos.sh"

cat > "$SERVER_PACKAGE/Install Liaison Server.command" <<'COMMAND'
#!/bin/bash
set -e
cd "$(dirname "$0")"
/bin/bash ./scripts/install-server-bundle-macos.sh
printf '\nPress Return to close.\n'
read -r _
COMMAND

cat > "$SERVER_PACKAGE/README.txt" <<'README'
Liaison Server for Apple silicon Mac

1. Extract this ZIP.
2. Double-click Install Liaison Server.command.
3. The installer prepares Homebrew, Colima, Docker CLI, and the headless tailscaled service.
4. Complete the one-time Tailscale browser login when prompted.
5. Copy the displayed liaison:// pairing code into Liaison Client.

Docker Desktop and the Tailscale GUI are not required.
The server stops Liaison-managed containers when it shuts down.
Apple GPU assignment is not supported for regular Docker workers.
README

/usr/bin/ditto "$BUNDLED_APP" "$CLIENT_APP"
cp target/release/liaison-cli "$CLIENT_PACKAGE/bin/liaison-cli"
cp scripts/setup-client-macos.sh "$CLIENT_PACKAGE/scripts/setup-client-macos.sh"
cp scripts/install-client-bundle-macos.sh "$CLIENT_PACKAGE/scripts/install-client-bundle-macos.sh"
cp scripts/bootstrap-dependencies-macos.sh "$CLIENT_PACKAGE/scripts/bootstrap-dependencies-macos.sh"

cat > "$CLIENT_PACKAGE/Install Liaison Client.command" <<'COMMAND'
#!/bin/bash
set -e
cd "$(dirname "$0")"
/bin/bash ./scripts/install-client-bundle-macos.sh
printf '\nPress Return to close.\n'
read -r _
COMMAND

cat > "$CLIENT_PACKAGE/README.txt" <<'README'
Liaison Client for Apple silicon Mac

1. Extract this ZIP.
2. Double-click Install Liaison Client.command.
3. Complete the one-time headless Tailscale browser login when prompted.
4. Open Liaison Client and paste the server pairing code.

A liaison-client.json file is optional. The app can save the address and token itself.
Worker management and the workspace terminal are integrated into Liaison Client.
The app is installed into ~/Applications.
README

chmod +x \
  "$SERVER_PACKAGE/bin/liaison-service" \
  "$SERVER_PACKAGE/bin/liaison-cli" \
  "$SERVER_PACKAGE/scripts/setup-server-macos.sh" \
  "$SERVER_PACKAGE/scripts/install-server-bundle-macos.sh" \
  "$SERVER_PACKAGE/scripts/bootstrap-dependencies-macos.sh" \
  "$SERVER_PACKAGE/Install Liaison Server.command" \
  "$CLIENT_PACKAGE/bin/liaison-cli" \
  "$CLIENT_PACKAGE/scripts/setup-client-macos.sh" \
  "$CLIENT_PACKAGE/scripts/install-client-bundle-macos.sh" \
  "$CLIENT_PACKAGE/scripts/bootstrap-dependencies-macos.sh" \
  "$CLIENT_PACKAGE/Install Liaison Client.command"

/usr/bin/codesign --force --deep --sign - "$CLIENT_APP"
/usr/bin/plutil -lint "$CLIENT_APP/Contents/Info.plist" >/dev/null

mkdir -p "$OUTPUT_DIRECTORY"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$SERVER_PACKAGE" "$SERVER_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$CLIENT_PACKAGE" "$CLIENT_ZIP"

echo "Created:"
echo "  $SERVER_ZIP"
echo "  $CLIENT_ZIP"
