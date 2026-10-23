#!/usr/bin/env bash
# Pure/mocked tests: NEVER configure the host running these tests.
set -euo pipefail
BASE_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$BASE_DIR/modules/common.sh"
source "$BASE_DIR/modules/firewall.sh"
source "$BASE_DIR/modules/fail2ban.sh"
source "$BASE_DIR/modules/users.sh"
source "$BASE_DIR/modules/system.sh"
source "$BASE_DIR/modules/ssh.sh"
source "$BASE_DIR/modules/docker.sh"
source "$BASE_DIR/modules/diagnostics.sh"
source "$BASE_DIR/modules/full_setup.sh"

eq() {
  if [[ "$1" != "$2" ]]; then
    printf 'Expected <%s>; got <%s>\n' "$2" "$1" >&2
    return 1
  fi
}

# Core setup should succeed without any Docker commands or dependencies.
test_full_setup_without_docker() (
  local logfile expected
  logfile="$(mktemp)"
  trap 'rm -f "$logfile"' EXIT
  info() { :; }
  warn() { :; }
  confirm() { return 0; }
  backup_important() { echo backup >> "$logfile"; }
  system_setup() { echo system >> "$logfile"; }
  user_create() { echo user >> "$logfile"; }
  ssh_apply() { echo ssh >> "$logfile"; }
  ufw_setup() { echo ufw >> "$logfile"; }
  fail2ban_setup() { echo fail2ban >> "$logfile"; }
  docker_menu() { echo UNEXPECTED_DOCKER_MENU >> "$logfile"; return 1; }
  docker_mirrors() { echo UNEXPECTED_DOCKER_MIRRORS >> "$logfile"; return 1; }
  full_setup || return 1
  expected="$(printf '%s\n' backup system user ssh ufw fail2ban)"
  eq "$(cat "$logfile")" "$expected"
)

# Optional Docker menu must be a no-op on systems without Docker.
test_missing_docker_is_not_an_error() (
  local logfile
  logfile="$(mktemp)"
  trap 'rm -f "$logfile"' EXIT
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == docker ]]; then return 1; fi
    builtin command "$@"
  }
  info() { echo "$*" >> "$logfile"; }
  packages() { echo UNEXPECTED_PACKAGES >> "$logfile"; return 1; }
  backup() { echo UNEXPECTED_BACKUP >> "$logfile"; return 1; }
  docker_menu || return 1
  docker_mirrors || return 1
  if grep -Eq "UNEXPECTED_" "$logfile"; then cat "$logfile" >&2; return 1; fi
  grep -Fq "Docker не установлен" "$logfile"
)
test_ubuntu_release_support() {
  local ver
  for ver in 22.04 24.04 26.04; do
    ubuntu_release_supported "$ver" || { printf 'Not supported: %s\n' "$ver" >&2; return 1; }
  done
  for ver in '' 20.04 25.10 26.10 testing; do
    if ubuntu_release_supported "$ver"; then
      printf 'Unexpectedly supported: %s\n' "$ver" >&2
      return 1
    fi
  done
}

# Regression: passing a port via REPLY must not treat the word REPLY as a base-10 number.
test_ask_port_accepts_2203() (
  ask() { REPLY=2203; }
  ask_port 'Новый SSH-порт' 22 || return 1
  eq "$PORT" "2203"
)

test_ask_port_converts_leading_zeros() (
  ask() { REPLY=02203; }
  ask_port 'Новый SSH-порт' 22 || return 1
  eq "$PORT" "2203"
)

test_ask_port_maximum() (
  ask() { REPLY=65535; }
  ask_port 'Новый SSH-порт' 22 || return 1
  eq "$PORT" "65535"
)
test_port_bounds() {
  local x
  for x in 1 22 1024 65535 00022; do validate_port "$x" || return 1; done
  for x in 0 65536 -1 foo '22/tcp' 1000000000000000; do
    if validate_port "$x"; then return 1; fi
  done
}

test_ports_csv() {
  eq "$(ports_csv '80, 443,80,00022')" '80 443 22' || return 1
  eq "$(ports_csv ' 53 , 1053 ')" '53 1053' || return 1
  eq "$(ports_csv '')" '' || return 1
  local x
  for x in '0' '65536' '22/udp' '80,,443' ',80' '80,' '80 90' '9999999999999'; do
    if ports_csv "$x" >/dev/null 2>&1; then echo "Accepted invalid: $x" >&2; return 1; fi
  done
}

test_ufw_allow() (
  local logfile
  logfile="$(mktemp)"
  trap 'rm -f "$logfile"' EXIT
  ask() { REPLY='80,443,80'; }
  ufw() { printf '%s\n' "$*" >> "$logfile"; }
  ufw_allow_ports tcp >/dev/null
  eq "$(cat "$logfile")" $'allow 80/tcp\nallow 443/tcp\nstatus numbered'
)

test_ufw_invalid_no_mutation() (
  local logfile
  logfile="$(mktemp)"
  trap 'rm -f "$logfile"' EXIT
  ask() { REPLY='80,,443'; }
  ufw() { printf '%s\n' "$*" >> "$logfile"; }
  if ufw_allow_ports tcp >/dev/null 2>&1; then return 1; fi
  [[ ! -s "$logfile" ]]
)

test_ufw_remove_protects_ssh() (
  local logfile
  logfile="$(mktemp)"
  trap 'rm -f "$logfile"' EXIT
  ask() { REPLY='2202,443'; }
  ssh_ports() { echo 2202; }
  confirm() { return 0; }
  ufw() { printf '%s\n' "$*" >> "$logfile"; }
  ufw_remove_ports tcp >/dev/null
  eq "$(cat "$logfile")" '--force delete allow 443/tcp'
)

test_ufw_initialization_order() (
  local logfile
  logfile="$(mktemp)"
  trap 'rm -f "$logfile"' EXIT
  packages() { return 0; }
  ssh_ports() { printf '2202\n'; }
  ask() {
    case "$1" in
      *'Фактический SSH-порт'*) REPLY=2202;;
      *'tcp через запятую'*) REPLY='80,443';;
      *'udp через запятую'*) REPLY='51820';;
      *) echo "Unexpected prompt $1" >&2; return 1;;
    esac
  }
  ufw() { printf '%s\n' "$*" >> "$logfile"; }
  confirm() { return 0; }
  ufw_setup >/dev/null
  eq "$(cat "$logfile")" $'allow 2202/tcp\nallow 2202/tcp\nallow 80/tcp\nallow 443/tcp\nstatus numbered\nallow 51820/udp\nstatus numbered\ndefault deny incoming\ndefault allow outgoing\n--force enable\nstatus verbose'
)

test_fail2ban_ignore_add_remove_and_rollback() (
  local temp fail_validation
  temp="$(mktemp -d)"
  trap 'rm -rf -- "$temp"' EXIT
  fail_validation=0
  fail2ban_ignore_path() { echo "$temp/95-srv-settings-ignore.local"; }
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == fail2ban-client ]]; then return 0; fi
    builtin command "$@"
  }
  fail2ban-client() {
    case "$*" in
      "status sshd"|"reload sshd") return 0;;
      "-t") (( fail_validation == 0 )); return;;
      "get sshd ignoreip") echo "127.0.0.0/8 ::1"; return 0;;
      *) echo "Unexpected Fail2ban call: $*" >&2; return 1;;
    esac
  }
  ask() { REPLY="192.0.2.7,10.1.2.5/24,2001:db8::5"; }
  confirm() { return 0; }
  backup() { return 0; }
  fail2ban_ignore_update add >/dev/null || return 1
  local target
  target="$(fail2ban_ignore_path)"
  grep -Fq "ignoreip = 127.0.0.0/8 ::1 192.0.2.7 10.1.2.0/24 2001:db8::5" "$target" || return 1
  local previous
  previous="$(cat "$target")"
  fail_validation=1
  ask() { REPLY="198.51.100.33"; }
  if fail2ban_ignore_update add >/dev/null 2>&1; then
    echo "Fail2ban config test failure was not propagated" >&2
    return 1
  fi
  eq "$(cat "$target")" "$previous" || return 1
  fail_validation=0
  ask() { REPLY="192.0.2.7,10.1.2.0/24,2001:db8::5"; }
  fail2ban_ignore_update remove >/dev/null || return 1
  [[ ! -e "$target" ]]
)
test_fail2ban_ignore_requires_running_jail() (
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == fail2ban-client ]]; then return 1; fi
    builtin command "$@"
  }
  local touched=""
  ask() { touched=yes; return 1; }
  fail2ban-client() { touched=yes; return 1; }
  if fail2ban_ignore_update add >/dev/null 2>&1; then
    echo 'Unexpectedly allowed ignoreip update without Fail2ban' >&2
    return 1
  fi
  [[ -z "$touched" ]]
)

test_fail2ban_ignore_menu_contract() {
  grep -Fq 'fail2ban_ignore_update add;;' "$BASE_DIR/modules/fail2ban.sh" || return 1
  grep -Fq 'fail2ban_ignore_update remove;;' "$BASE_DIR/modules/fail2ban.sh" || return 1
  grep -Fq 'fail2ban_ignore_show;;' "$BASE_DIR/modules/fail2ban.sh" || return 1
  grep -Fq 'fail2ban_ignore_update add || return 1' "$BASE_DIR/modules/fail2ban.sh"
}
test_fail2ban_ip_validation() (
  local logfile
  logfile="$(mktemp)"
  trap 'rm -f "$logfile"' EXIT
  ask() { REPLY='198.51.100.22'; }
  fail2ban-client() { printf '%s\n' "$*" >> "$logfile"; }
  fail2ban_unban >/dev/null
  eq "$(cat "$logfile")" 'set sshd unbanip 198.51.100.22' || return 1
  : > "$logfile"
  ask() { REPLY='1.2.3.4;touch /tmp/unsafe'; }
  if fail2ban_unban >/dev/null 2>&1; then return 1; fi
  [[ ! -s "$logfile" ]]
)

test_bootstrap_interactivity_contract() {
  grep -Fq 'exec bash /opt/srv-settings/setup.sh </dev/tty' "$BASE_DIR/bootstrap.sh" || return 1
  grep -Fq 'if ! (: </dev/tty)' "$BASE_DIR/bootstrap.sh" || return 1
}

test_ssh_rollback_contract() {
  grep -Fq -- '--on-active=5min' "$BASE_DIR/modules/ssh.sh" || return 1
  grep -Fq 'ufw allow "$newport/tcp"' "$BASE_DIR/modules/ssh.sh" || return 1
  grep -Fq 'systemctl daemon-reload' "$BASE_DIR/modules/ssh.sh" || return 1
  grep -Fq 'systemctl restart ssh.socket' "$BASE_DIR/modules/ssh.sh" || return 1
}

test_main_menu_has_no_docker() {
  local menu="$BASE_DIR/setup.sh" expected
  if grep -Eq "^[[:space:]]*source .*modules/docker.sh|^[[:space:]]*6\\) docker_menu;;|Docker \\(необязательно\\)" "$menu"; then
    echo "Docker remains accessible in main menu" >&2
    return 1
  fi
  for expected in \
    "printf '6. Обновление системы / время\\n'" \
    "printf '7. Диагностика\\n'" \
    "printf '8. Резервное копирование конфигурации\\n'" \
    '6) system_menu;;' \
    '7) diagnostics;;' \
    '8) backup_important;;' \
    "Выберите пункт меню от 0 до 8"; do
    grep -Fq -- "$expected" "$menu" || { echo "Missing menu entry: $expected" >&2; return 1; }
  done
}
test_modules_load() {
  local name
  for name in system_setup user_create ssh_apply ufw_setup fail2ban_setup docker_mirrors diagnostics; do
    declare -F "$name" >/dev/null || return 1
  done
}

passed=0
failed=0
for test_fn in $(compgen -A function test_ | LC_ALL=C sort); do
  printf 'RUN %-38s' "$test_fn"
  if ( "$test_fn" ); then
    printf 'OK\n'
    ((passed+=1))
  else
    printf 'FAILED\n' >&2
    ((failed+=1))
  fi
done
printf '\nBash: %d passed, %d failed\n' "$passed" "$failed"
((failed==0))
