#!/bin/bash
set -euo pipefail

liaison_dependency_step() {
  printf '\n==> %s\n' "$1"
}

liaison_brew_bin() {
  if command -v brew >/dev/null 2>&1; then
    command -v brew
    return 0
  fi
  if [[ -x /opt/homebrew/bin/brew ]]; then
    printf '%s\n' /opt/homebrew/bin/brew
    return 0
  fi
  if [[ -x /usr/local/bin/brew ]]; then
    printf '%s\n' /usr/local/bin/brew
    return 0
  fi
  return 1
}

liaison_add_brew_path() {
  local brew
  brew="$(liaison_brew_bin 2>/dev/null || true)"
  if [[ -n "$brew" ]]; then
    eval "$("$brew" shellenv)"
  fi
}

liaison_install_homebrew() {
  if liaison_brew_bin >/dev/null 2>&1; then
    liaison_add_brew_path
    return 0
  fi

  liaison_dependency_step "Installing Homebrew for headless dependencies"
  NONINTERACTIVE=1 /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  liaison_add_brew_path
  liaison_brew_bin >/dev/null 2>&1 || {
    echo "Homebrew installation did not complete." >&2
    return 1
  }
}

liaison_tailscale_bin() {
  liaison_add_brew_path
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
    return 0
  fi
  return 1
}

liaison_tailscale() {
  local binary
  binary="$(liaison_tailscale_bin)" || return 1
  "$binary" "$@"
}

liaison_tailscale_ip() {
  liaison_tailscale ip -4 2>/dev/null | head -n 1 || true
}

liaison_install_tailscale() {
  liaison_install_homebrew
  local brew
  brew="$(liaison_brew_bin)"

  if ! liaison_tailscale_bin >/dev/null 2>&1; then
    liaison_dependency_step "Installing the headless Tailscale daemon"
    "$brew" install --formula tailscale
  fi

  liaison_dependency_step "Starting the headless Tailscale service"
  "$brew" services start tailscale >/dev/null
  for _ in $(seq 1 30); do
    if liaison_tailscale status >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 0
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

  liaison_dependency_step "Connecting the headless Tailscale service"
  echo "A browser login link may be displayed once. Complete that login, then return here."
  liaison_tailscale up || true
  ip="$(liaison_tailscale_ip)"
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  return 1
}

liaison_docker_bin() {
  liaison_add_brew_path
  if command -v docker >/dev/null 2>&1; then
    command -v docker
    return 0
  fi
  return 1
}

liaison_colima_bin() {
  liaison_add_brew_path
  if command -v colima >/dev/null 2>&1; then
    command -v colima
    return 0
  fi
  return 1
}

liaison_docker_ready() {
  local binary
  binary="$(liaison_docker_bin)" || return 1
  "$binary" info >/dev/null 2>&1
}

liaison_colima_resources() {
  local cpu memory_bytes memory_gib
  cpu="$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
  memory_bytes="$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 8589934592)"
  memory_gib=$((memory_bytes / 1024 / 1024 / 1024))
  cpu=$((cpu > 2 ? cpu - 2 : 2))
  memory_gib=$((memory_gib > 6 ? memory_gib - 4 : 4))
  printf '%s %s\n' "$cpu" "$memory_gib"
}

liaison_start_colima() {
  local colima resources cpu memory
  colima="$(liaison_colima_bin)" || return 1
  resources="$(liaison_colima_resources)"
  cpu="${resources%% *}"
  memory="${resources##* }"

  if "$colima" status >/dev/null 2>&1 && liaison_docker_ready; then
    return 0
  fi

  liaison_dependency_step "Starting the headless Docker runtime"
  "$colima" start --runtime docker --cpu "$cpu" --memory "$memory" --disk 60
  liaison_docker_ready
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
  liaison_install_homebrew
  local brew
  brew="$(liaison_brew_bin)"

  liaison_dependency_step "Installing the headless Docker runtime"
  "$brew" install colima docker
  liaison_start_colima
  if ! liaison_wait_for_docker 180; then
    echo "The Colima Docker runtime did not become ready." >&2
    return 1
  fi
}
