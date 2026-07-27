#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIRECTORY/bootstrap-dependencies-macos.sh"

LOCAL_ONLY="${LIAISON_LOCAL_ONLY:-0}"
SKIP_DEPENDENCIES="${LIAISON_SKIP_DEPENDENCIES:-0}"

if [[ "$SKIP_DEPENDENCIES" != "1" ]]; then
  liaison_install_docker
  if [[ "$LOCAL_ONLY" != "1" ]]; then
    if ! liaison_connect_tailscale 1 >/dev/null; then
      echo "Tailscale is installed but not signed in." >&2
      echo "The server will be configured as local-only." >&2
      LOCAL_ONLY="1"
    fi
  fi
fi

if [[ "$LOCAL_ONLY" == "1" ]]; then
  LIAISON_LOCAL_ONLY=1 exec /bin/bash "$SCRIPT_DIRECTORY/setup-server-macos.sh"
else
  exec /bin/bash "$SCRIPT_DIRECTORY/setup-server-macos.sh"
fi
