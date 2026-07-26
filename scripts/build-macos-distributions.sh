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

cargo build --release -p liaison-service -p liaison-cli -p liaison-desktop

SERVER_PACKAGE="$OUTPUT_DIRECTORY/liaison-server-macos-arm64"
CLIENT_PACKAGE="$OUTPUT_DIRECTORY/liaison-client-macos-arm64"
SERVER_ZIP="$OUTPUT_DIRECTORY/liaison-server-macos-arm64.zip"
CLIENT_ZIP="$OUTPUT_DIRECTORY/liaison-client-macos-arm64.zip"
CLIENT_APP="$CLIENT_PACKAGE/Liaison Client.app"

rm -rf "$SERVER_PACKAGE" "$CLIENT_PACKAGE" "$SERVER_ZIP" "$CLIENT_ZIP"
mkdir -p \
  "$SERVER_PACKAGE/bin" \
  "$SERVER_PACKAGE/scripts" \
  "$SERVER_PACKAGE/config" \
  "$CLIENT_PACKAGE/bin" \
  "$CLIENT_PACKAGE/scripts" \
  "$CLIENT_APP/Contents/MacOS" \
  "$CLIENT_APP/Contents/Resources"

cp target/release/liaison-service "$SERVER_PACKAGE/bin/liaison-service"
cp target/release/liaison-cli "$SERVER_PACKAGE/bin/liaison-cli"
cp scripts/setup-server-macos.sh "$SERVER_PACKAGE/scripts/setup-server-macos.sh"
cp config/liaison.example.json "$SERVER_PACKAGE/config/liaison.example.json"

cat > "$SERVER_PACKAGE/Install Liaison Server.command" <<'COMMAND'
#!/bin/bash
set -e
cd "$(dirname "$0")"
exec /bin/bash ./scripts/setup-server-macos.sh
COMMAND

cat > "$SERVER_PACKAGE/README.txt" <<'README'
Liaison Server for Apple silicon

Requirements:
- Apple silicon Mac
- Docker Desktop running
- Tailscale when connecting from another computer

Setup:
1. Extract this ZIP.
2. Double-click "Install Liaison Server.command".
3. When setup completes, copy liaison-client.json from the Desktop to a client package.

Supported on Mac server:
- CPU and memory allocation
- Persistent and workspace Docker containers
- Automatic host sizing
- Tailscale private TCP access

Not supported:
- Apple GPU assignment to Docker containers
README

cp target/release/liaison-desktop "$CLIENT_APP/Contents/MacOS/liaison-desktop"
cp target/release/liaison-cli "$CLIENT_PACKAGE/bin/liaison-cli"
cp scripts/setup-client-macos.sh "$CLIENT_PACKAGE/scripts/setup-client-macos.sh"

cat > "$CLIENT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Liaison Client</string>
  <key>CFBundleExecutable</key>
  <string>liaison-desktop</string>
  <key>CFBundleIdentifier</key>
  <string>dev.batasan.liaison</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Liaison Client</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>0.2.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

cat > "$CLIENT_PACKAGE/Install Liaison Client.command" <<'COMMAND'
#!/bin/bash
set -e
cd "$(dirname "$0")"
exec /bin/bash ./scripts/setup-client-macos.sh
COMMAND

cat > "$CLIENT_PACKAGE/README.txt" <<'README'
Liaison Client for Apple silicon

Setup:
1. Extract this ZIP.
2. Copy liaison-client.json from the server into this folder.
3. Double-click "Install Liaison Client.command".
4. Liaison Client is installed into ~/Applications and opened.

This build is ad-hoc signed for local testing. On the first launch, macOS may ask you to confirm that the app should be opened.
README

chmod +x \
  "$SERVER_PACKAGE/bin/liaison-service" \
  "$SERVER_PACKAGE/bin/liaison-cli" \
  "$SERVER_PACKAGE/scripts/setup-server-macos.sh" \
  "$SERVER_PACKAGE/Install Liaison Server.command" \
  "$CLIENT_APP/Contents/MacOS/liaison-desktop" \
  "$CLIENT_PACKAGE/bin/liaison-cli" \
  "$CLIENT_PACKAGE/scripts/setup-client-macos.sh" \
  "$CLIENT_PACKAGE/Install Liaison Client.command"

/usr/bin/codesign --force --deep --sign - "$CLIENT_APP"
/usr/bin/plutil -lint "$CLIENT_APP/Contents/Info.plist" >/dev/null

mkdir -p "$OUTPUT_DIRECTORY"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$SERVER_PACKAGE" "$SERVER_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$CLIENT_PACKAGE" "$CLIENT_ZIP"

echo "Created:"
echo "  $SERVER_ZIP"
echo "  $CLIENT_ZIP"
