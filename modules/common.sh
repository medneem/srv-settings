#!/usr/bin/env bash

# ANSI formatting is restricted to interactive terminals.
# Redirected logs, dumb terminals and NO_COLOR always remain plain text.
ui_output_is_terminal() { [[ -t "$1" ]]; }

ui_color_enabled() {
  [[ -z "${NO_COLOR:-}" && -n "${TERM:-}" && "${TERM:-}" != dumb ]] &&
    ui_output_is_terminal "$1"
}

# INFO/OK => stdout, WARN/ERROR => stderr.
# Only labels are colored, except critical failures.
ui_log() {
  local label="$1" color="$2" fd="$3" full="$4"
  shift 4
  local start='' reset=''
  if ui_color_enabled "$fd"; then
    printf -v start '\033[%sm' "$color"
    printf -v reset '\033[0m'
  fi
  if [[ "$full" == yes ]]; then
    printf '%s[%s] %s%s\n' "$start" "$label" "$*" "$reset" >&"$fd"
  else
    printf '%s[%s]%s %s\n' "$start" "$label" "$reset" "$*" >&"$fd"
  fi
}

info() { ui_log INFO 36 1 no "$*"; }
success() { ui_log ' OK ' '1;32' 1 no "$*"; }
warn() { ui_log WARN '1;33' 2 no "$*"; }
attention() { ui_log ВАЖНО '1;33' 2 yes "$*"; }
fail() { ui_log ERROR '1;31' 2 yes "$*"; return 1; }

# Numbered stages are printed by the full-setup wizard.
section() {
  local number="$1" title="$2" start='' reset=''
  if ui_color_enabled 1; then
    printf -v start '\033[36m'
    printf -v reset '\033[0m'
  fi
  printf '\n%s━━━ [ %s ] %s ━━━%s\n' "$start" "$number" "$title" "$reset"
}

# Highlight a copy-ready SSH command on a single line.
ssh_command() {
  local port="$1" target="$2" start='' reset=''
  if ui_color_enabled 1; then
    printf -v start '\033[1;32m'
    printf -v reset '\033[0m'
  fi
  printf '\n    %sssh -p %s %s%s\n\n' "$start" "$port" "$target" "$reset"
}

# Supported LTS releases are checked in setup.sh and in tests.
ubuntu_release_supported() {
  case "${1:-}" in
    22.04|24.04|26.04) return 0 ;;
    *) return 1 ;;
  esac
}

# UTF-8 Readline editing erases full characters (not individual bytes).
# Readline only works with a TTY; keep normal read for pipes and unit tests.
read_input() {
  local prompt="$1" variable="$2"
  if [[ -t 0 ]]; then
    read -e -r -p "$prompt" "$variable"
  else
    read -r -p "$prompt" "$variable"
  fi
}

# Do not permanently change system locale. Only adjust this process/TTY.
prepare_utf8_terminal() {
  local charmap
  charmap="$(locale charmap 2>/dev/null || true)"
  case "$charmap" in
    UTF-8|utf8|UTF8) ;;
    *)
      if [[ "$(LC_ALL=C.UTF-8 locale charmap 2>/dev/null)" == UTF-8 ]]; then
        export LC_ALL=C.UTF-8
      else
        warn 'Нет доступной UTF-8 locale. Стирание кириллицы может работать некорректно.'
      fi
      ;;
  esac
  if [[ -t 0 ]] && command -v stty >/dev/null 2>&1; then
    stty iutf8 2>/dev/null || true
  fi
}

confirm() {
  local a
  read_input "$1 [y/N]: " a || return 1
  # Terminals/pasted responses may include CRLF or surrounding whitespace.
  # Only an explicit yes may authorize potentially dangerous operations.
  a="${a#"${a%%[![:space:]]*}"}"
  a="${a%"${a##*[![:space:]]}"}"
  case "$a" in
    [yY]|[yY][eE][sS]|[дД]|[дД][аА]) return 0 ;;
    ''|[nN]|[nN][oO]|[нН]|[нН][еЕ][тТ]) return 1 ;;
    *) warn 'Ответ не распознан; действие НЕ подтверждено. Используйте y/yes или Enter (N).'; return 1 ;;
  esac
}

ask() {
  local q="$1" default="${2:-}" value
  read_input "$q [$default]: " value || return 1
  REPLY="${value:-$default}"
}

validate_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

ask_port() {
  while true; do
    ask "$1" "$2" || return 1
    if validate_port "$REPLY"; then PORT="$((10#$REPLY))"; return 0; fi
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
