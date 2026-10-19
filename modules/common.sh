#!/usr/bin/env bash

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; return 1; }

# Supported LTS releases are checked in setup.sh and in tests.
ubuntu_release_supported() {
  case "${1:-}" in
    22.04|24.04|26.04) return 0 ;;
    *) return 1 ;;
  esac
}

confirm() {
  local a
  read -r -p "$1 [y/N]: " a || return 1
  [[ $a == [yY] || $a == [yY][eE][sS] || $a == [дД] || $a == [дД][аА] ]]
}

ask() {
  local q="$1" default="${2:-}" value
  read -r -p "$q [$default]: " value || return 1
  REPLY="${value:-$default}"
}

validate_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

ask_port() {
  while true; do
    ask "$1" "$2" || return 1
    if validate_port "$REPLY"; then PORT="$((10#REPLY))"; return 0; fi
    warn 'Допустимый порт: 1–65535'
  done
}

ports_csv() {
  local raw="$1" item value result=''
  local -a items=()
  local -A seen=()
  [[ -z "${raw//[[:space:],]/}" ]] && { echo ''; return 0; }
  if [[ ! $raw =~ ^[[:space:]]*[0-9]+[[:space:]]*(,[[:space:]]*[0-9]+[[:space:]]*)*$ ]]; then
    fail "Некорректный список портов: $raw"; return 1
  fi
  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    value="${item//[[:space:]]/}"
    validate_port "$value" || { fail "Некорректный порт: $item"; return 1; }
    value="$((10#$value))"
    if [[ ! -v seen[$value] ]]; then seen[$value]=1; result+="$value "; fi
  done
  echo "${result% }"
}

packages() {
  local p
  local -a missing=()
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -qx 'install ok installed' || missing+=("$p")
  done
  if (( ${#missing[@]} > 0 )); then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
}

backup() {
  local path="$1"
  [[ -f $path ]] || return 0
  mkdir -p /var/backups/srv-settings
  cp -a "$path" "/var/backups/srv-settings/$(basename "$path").$(date +%Y%m%d-%H%M%S)-$$"
}

ssh_ports() {
  if [[ -x /usr/sbin/sshd ]]; then
    /usr/sbin/sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
  else
    echo 22
  fi
}
