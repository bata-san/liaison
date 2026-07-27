#!/bin/bash
set -euo pipefail

liaison_dependency_step() {
  printf '\n==> %s\n' "$1"
}

liaison_tailscale_bin() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
    return 0
  fi
  if [[ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]]; then
    printf '%s\n' "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    return 0
  fi
  return 1
}

liaison_tailscale() {
  local binary
  binary="$(liaison_tailscale_bin)" || return 1
  TAILSCALE_BE_CLI=1 "$binary" "$@"
}

liaison_tailscale_ip() {
  liaison_tailscale ip -4 2>/dev/null | head -n 1 || true
}

liaison_install_tailscale() {
  if liaison_tailscale_bin >/dev/null 2>&1; then
    return 0
  fi

  liaison_dependency_step "Installing Tailscale from the official package server"
  local temporary index package
  temporary="$(mktemp -d)"
  index="$temporary/index.html"
  /usr/bin/curl -fsSL "https://pkgs.tailscale.com/stable/" -o "$index"
  package="$(/usr/bin/grep -Eo 'Tailscale-[0-9.]+-macos\.pkg' "$index" | head -n 1 || true)"
  if [[ -z "$package" ]]; then
    echo "The current Tailscale package could not be located." >&2
    rm -rf "$temporary"
    return 1
  fi
  /usr/bin/curl -fL "https://pkgs.tailscale.com/stable/$package" -o "$temporary/$package"
  /usr/bin/sudo /usr/sbin/installer -pkg "$temporary/$package" -target /
  rm -rf "$temporary"
  /usr/bin/open -a Tailscale || true
}

liaison_connect_tailscale() {
  local install_if_missing="${1:-1}"
  if ! liaison_tailscale_bin >/dev/null 2>&1; then
    if [[ "$install_if_missing" == "1" ]]; then
      liaison_install_tailscale
    else
      return 1
    fi
  fi

  local ip
  ip="$(liaison_tailscale_ip)"
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi

  liaison_dependency_step "Connecting Tailscale"
  /usr/bin/open -a Tailscale || true
  sleep 2
  liaison_tailscale up || true
  ip="$(liaison_tailscale_ip)"
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  return 1
}

liaison_docker_bin() {
  if command -v docker >/dev/null 2>&1; then
    command -v docker
    return 0
  fi
  if [[ -x "/Applications/Docker.app/Contents/Resources/bin/docker" ]]; then
    printf '%s\n' "/Applications/Docker.app/Contents/Resources/bin/docker"
    return 0
  fi
  return 1
}

liaison_docker_ready() {
  local binary
  binary="$(liaison_docker_bin)" || return 1
  "$binary" info >/dev/null 2>&1
}

liaison_wait_for_docker() {
  local timeout="${1:-180}"
  local elapsed=0
  while [[ "$elapsed" -lt "$timeout" ]]; do
    if liaison_docker_ready; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

liaison_install_docker() {
  if [[ ! -d "/Applications/Docker.app" ]]; then
    liaison_dependency_step "Installing Docker Desktop from Docker"
    local temporary dmg
    temporary="$(mktemp -d)"
    dmg="$temporary/Docker.dmg"
    /usr/bin/curl -fL "https://desktop.docker.com/mac/main/arm64/Docker.dmg" -o "$dmg"
    /usr/bin/hdiutil attach "$dmg" -nobrowse -quiet
    /usr/bin/sudo /Volumes/Docker/Docker.app/Contents/MacOS/install --user="$USER"
    /usr/bin/hdiutil detach /Volumes/Docker -quiet || true
    rm -rf "$temporary"
  fi

  /usr/bin/open -a Docker
  if ! liaison_wait_for_docker 180; then
    echo "Docker Desktop is installed but not ready." >&2
    echo "Complete the Docker Desktop first-run prompts, then run setup again." >&2
    return 1
  fi
}
