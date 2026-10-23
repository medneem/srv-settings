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
# Merely opening the optional Docker menu must never install anything.
test_missing_docker_menu_is_safe() (
  local logfile
  logfile="$(mktemp)"
  trap 'rm -f "$logfile"' EXIT
  command() {
    if [[ "$1" == -v && "$2" == docker ]]; then return 1; fi
    builtin command "$@"
  }
  info() { echo "$*" >> "$logfile"; }
  packages() { echo UNEXPECTED_PACKAGES >> "$logfile"; return 1; }
  backup() { echo UNEXPECTED_BACKUP >> "$logfile"; return 1; }
  docker_menu <<< 0 || return 1
  docker_mirrors || return 1
  if grep -Eq 'UNEXPECTED_' "$logfile"; then cat "$logfile" >&2; return 1; fi
  grep -Fq 'Docker не установлен' "$logfile"
)

test_docker_supported_ubuntu_codenames() (
  VERSION_ID=22.04
  eq "$(docker_ubuntu_codename)" jammy || return 1
  VERSION_ID=24.04
  eq "$(docker_ubuntu_codename)" noble || return 1
  VERSION_ID=26.04
  eq "$(docker_ubuntu_codename)" resolute || return 1
  VERSION_ID=20.04
  if docker_ubuntu_codename >/dev/null 2>&1; then return 1; fi
)

test_docker_install_declined_no_mutation() (
  local logfile
  VERSION_ID=22.04
  logfile="$(mktemp)"
  trap 'rm -f "$logfile"' EXIT
  confirm() { return 1; }
  packages() { echo packages >> "$logfile"; return 1; }
  apt-get() { echo apt >> "$logfile"; return 1; }
  curl() { echo curl >> "$logfile"; return 1; }
  docker_install || return 1
  [[ ! -s "$logfile" ]]
)

test_docker_install_uses_official_repo_and_compose() (
  local temp logfile
  temp="$(mktemp -d)"
  trap 'rm -rf "$temp"' EXIT
  logfile="$temp/operations"
  VERSION_ID=24.04
  docker_repo_key_path() { printf '%s\n' "$temp/keyrings/docker.asc"; }
  docker_repo_sources_path() { printf '%s\n' "$temp/sources/docker.sources"; }
  confirm() { return 0; }
  packages() { return 0; }
  backup() { return 0; }
  dpkg-query() { return 1; }
  dpkg() { printf 'amd64\n'; }
  curl() {
    local last='' arg
    for arg in "$@"; do
      if [[ "$last" == -o ]]; then
        printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'test' '-----END PGP PUBLIC KEY BLOCK-----' >"$arg"
        return 0
      fi
      last="$arg"
    done
    return 1
  }
  apt-get() { printf 'apt-get %s\n' "$*" >> "$logfile"; }
  apt-cache() { printf '  Candidate: 5:29.0.0\n'; }
  systemctl() { printf 'systemctl %s\n' "$*" >> "$logfile"; }
  docker() {
    case "$*" in
      --version) printf 'Docker test\n';;
      'compose version') printf 'Docker Compose test\n';;
      *) return 1;;
    esac
  }
  docker_install || return 1
  grep -Fq 'URIs: https://download.docker.com/linux/ubuntu' "$temp/sources/docker.sources" || return 1
  grep -Fq 'Suites: noble' "$temp/sources/docker.sources" || return 1
  grep -Fq 'Architectures: amd64' "$temp/sources/docker.sources" || return 1
  grep -Fq "Signed-By: $temp/keyrings/docker.asc" "$temp/sources/docker.sources" || return 1
  grep -Fq 'apt-get update' "$logfile" || return 1
  grep -Fq 'apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' "$logfile" || return 1
  grep -Fq 'systemctl enable --now docker' "$logfile" || return 1
)

test_docker_does_not_remove_conflicts_when_repository_unavailable() (
  local temp logfile
  temp="$(mktemp -d)"
  trap 'rm -rf "$temp"' EXIT
  logfile="$temp/removed"
  VERSION_ID=22.04
  docker_repo_key_path() { printf '%s\n' "$temp/keyrings/docker.asc"; }
  docker_repo_sources_path() { printf '%s\n' "$temp/sources/docker.sources"; }
  confirm() { return 0; }
  packages() { return 0; }
  dpkg() { echo amd64; }
  dpkg-query() {
    if [[ "$*" == *docker.io* ]]; then printf 'install ok installed'; return 0; fi
    return 1
  }
  curl() {
    local previous='' arg
    for arg in "$@"; do
      if [[ "$previous" == -o ]]; then
        printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'test' >"$arg"
        return 0
      fi
      previous="$arg"
    done
    return 1
  }
  apt-get() {
    if [[ "$1" == remove ]]; then echo 'removed!' >"$logfile"; return 0; fi
    [[ "$1" == update ]] && return 1
    return 1
  }
  apt-cache() { return 1; }
  if docker_install >/dev/null 2>&1; then return 1; fi
  [[ ! -e "$logfile" ]]
)

test_docker_invalid_gpg_key_does_not_write_sources() (
  local temp logfile
  temp="$(mktemp -d)"
  trap 'rm -rf "$temp"' EXIT
  logfile="$temp/apt.log"
  VERSION_ID=26.04
  docker_repo_key_path() { printf '%s\n' "$temp/keyrings/docker.asc"; }
  docker_repo_sources_path() { printf '%s\n' "$temp/sources/docker.sources"; }
  confirm() { return 0; }
  packages() { return 0; }
  dpkg-query() { return 1; }
  dpkg() { echo amd64; }
  curl() {
    local last='' arg
    for arg in "$@"; do
      if [[ "$last" == -o ]]; then
        printf '%s\n' 'not a PGP public key' > "$arg"
        return 0
      fi
      last="$arg"
    done
    return 1
  }
  apt-get() { printf '%s\n' "$*" >> "$logfile"; return 1; }
  if docker_install >/dev/null 2>&1; then return 1; fi
  [[ ! -e "$temp/keyrings/docker.asc" &&
     ! -e "$temp/sources/docker.sources" &&
     ! -e "$logfile" ]]
)

test_docker_conflicting_packages_require_separate_approval() (
  local temp logfile prompts=0
  temp="$(mktemp -d)"
  trap 'rm -rf "$temp"' EXIT
  logfile="$temp/operations"
  VERSION_ID=22.04
  confirm() { ((prompts+=1)); [[ "$prompts" -eq 1 ]]; }
  dpkg-query() {
    if [[ "$*" == *docker.io* ]]; then printf 'install ok installed'; return 0; fi
    return 1
  }
  apt-get() { echo apt >> "$logfile"; return 1; }
  curl() { echo curl >> "$logfile"; return 1; }
  packages() { echo packages >> "$logfile"; return 1; }
  docker_install >/dev/null 2>&1 || return 1
  [[ "$prompts" == 2 && ! -e "$logfile" ]]
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

test_ssh_auth_accepts_yes_with_crlf() (
  local confirmations=0
  packages() { return 0; }
  ssh_ports() { echo 22; }
  ask_port() { PORT=2203; }
  ask() { REPLY="$(printf '  YES\015')"; }
  confirm() { ((confirmations+=1)); return 1; }
  ufw() { echo 'Unexpected UFW action' >&2; return 1; }
  ssh_apply >/dev/null 2>&1 || return 1
  (( confirmations >= 2 ))
)

test_ssh_auth_accepts_no_with_whitespace() (
  local confirmations=0
  packages() { return 0; }
  ssh_ports() { echo 22; }
  ask_port() { PORT=2203; }
  ask() { REPLY="$(printf 'No \011')"; }
  confirm() { ((confirmations+=1)); return 1; }
  ufw() { echo 'Unexpected UFW action' >&2; return 1; }
  ssh_apply >/dev/null 2>&1 || return 1
  (( confirmations >= 2 ))
)

test_bootstrap_resolves_commit_before_downloading() {
  grep -Fq 'api.github.com/repos/medneem/srv-settings/commits/main?cache_bust=' "$BASE_DIR/bootstrap.sh" || return 1
  grep -Fq 'codeload.github.com/medneem/srv-settings/tar.gz/' "$BASE_DIR/bootstrap.sh" || return 1
  grep -Fq -- '--strip-components=1' "$BASE_DIR/bootstrap.sh" || return 1
  grep -Fq 'Cache-Control: no-cache' "$BASE_DIR/bootstrap.sh"
}
test_ssh_auth_accepts_plain_yes_from_read() (
  local confirmations=0
  packages() { return 0; }
  ssh_ports() { echo 22; }
  ask_port() { PORT=2203; }
  confirm() { ((confirmations+=1)); return 1; }
  ufw() { echo 'Unexpected UFW action' >&2; return 1; }
  ssh_apply <<< 'yes' >/dev/null 2>&1 || return 1
  (( confirmations >= 2 ))
)

test_ssh_status_shows_service_and_socket() {
  grep -Fq "systemctl status ssh.service ssh.socket" "$BASE_DIR/modules/ssh.sh"
}
# CRLF/pasted input is visually "y" but used to silently decline root SSH changes.
test_confirm_accepts_yes_from_crlf() (
  printf 'y\r\n' | confirm 'Подтвердить отключение root?' >/dev/null
)

test_confirm_accepts_yes_with_spaces() (
  printf '  YES  \r\n' | confirm 'Подтвердить?' >/dev/null
)

test_confirm_negative_answers_remain_safe() (
  local value
  for value in '' 'n' 'N' 'no' 'nope' 'yesplease' 'y?'; do
    if printf '%s\n' "$value" | confirm 'Подтвердить?' >/dev/null 2>&1; then
      printf 'Unexpectedly accepted affirmative: %q\n' "$value" >&2
      return 1
    fi
  done
)

test_ssh_root_confirmation_crlf_changes_preview_only() (
  packages() { return 0; }
  ssh_ports() { echo 22; }
  ask_port() { PORT=2203; }
  ask() { REPLY=yes; }
  ssh_prepare_login_target() { SSH_LOGIN_TARGET='admins@203.0.113.42'; }
  ufw() { echo 'Unexpected UFW changes!' >&2; return 1; }
  local transcript
  transcript="$(printf 'y\r\ny\r\nn\n' | ssh_apply 2>&1)" || return 1
  [[ "$transcript" == *'PermitRootLogin=no'* ]] || return 1
  [[ "$transcript" != *'Root SSH оставлен без изменений'* ]]
)

test_ssh_root_lockout_prompt_explains_safe_check() (
  local calls=0 transcript transcript_file
  transcript_file="$(mktemp)"
  trap 'rm -f "$transcript_file"' EXIT
  packages() { return 0; }
  ssh_ports() { printf '22\n'; }
  ask_port() { PORT=2203; }
  SSH_CONNECTION='198.51.100.7 53842 203.0.113.42 22'
  SUDO_USER=''
  getent() { printf 'sudo:x:27:deploy\n'; }
  id() { [[ "${1:-}" == deploy ]]; }
  ask() { REPLY=yes; }
  confirm() { ((calls+=1)); [[ "$calls" == 1 ]]; }
  ufw() { echo "Unexpected UFW call" >&2; return 1; }
  ssh_apply >"$transcript_file" 2>&1 || return 1
  transcript="$(cat "$transcript_file")"
  [[ "$transcript" == *"ssh -p 22 deploy@203.0.113.42"* ]] || return 1
  [[ "$transcript" == *"sudo -v && sudo id -u"* ]] || return 1
  [[ "$transcript" == *"Enter (N)"* ]] || return 1
  [[ "$transcript" == *"Root SSH оставлен без изменений"* ]] || return 1
  [[ "$calls" == 3 ]]
)
test_ssh_login_target_uses_ssh_connection_and_sudo_user() (
  SSH_CONNECTION='198.51.100.9 55012 203.0.113.42 22'
  SSH_CLIENT='198.51.100.9 55012 10.0.0.5'
  SUDO_USER='deploy'
  id() { [[ "${1:-}" == deploy ]]; }
  ask() { echo "Unexpected prompt: $1" >&2; return 1; }
  ssh_prepare_login_target || return 1
  eq "$SSH_LOGIN_TARGET" "deploy@203.0.113.42"
)

test_ssh_login_target_unique_sudo_member() (
  SSH_CONNECTION='198.51.100.9 55012 203.0.113.42 22'
  SUDO_USER='root'
  getent() { printf 'sudo:x:27:admins\n'; }
  id() { [[ "${1:-}" == admins ]]; }
  ask() { echo "Unexpected prompt: $1" >&2; return 1; }
  ssh_prepare_login_target || return 1
  eq "$SSH_LOGIN_TARGET" "admins@203.0.113.42"
)

test_ssh_login_target_ipv6() (
  SSH_CONNECTION='2001:db8::99 44422 2001:db8::5 22'
  SUDO_USER='deploy'
  id() { [[ "${1:-}" == deploy ]]; }
  ask() { echo "Unexpected prompt" >&2; return 1; }
  ssh_prepare_login_target || return 1
  eq "$SSH_LOGIN_TARGET" "deploy@2001:db8::5"
)

test_ssh_login_target_missing_address_never_prompts() (
  SSH_CONNECTION=""
  SSH_CLIENT=""
  SUDO_USER="deploy"
  id() { [[ "$1" == deploy ]]; }
  ip() { return 1; }
  ask() { echo "Unexpected interactive prompt" >&2; return 1; }
  if ssh_prepare_login_target >/dev/null 2>&1; then return 1; fi
  [[ -z "$SSH_LOGIN_TARGET" ]]
)

test_ssh_root_no_detectable_address_keeps_explicit_confirmation() (
  local num=0 out
  packages() { return 0; }
  ssh_ports() { echo 22; }
  ask_port() { PORT=2203; }
  ask() { REPLY=yes; }
  ssh_prepare_login_target() { SSH_LOGIN_TARGET=""; return 1; }
  confirm() { ((num+=1)); [[ "$num" == 1 || "$num" == 2 ]]; }
  ufw() { echo "Unexpected UFW call" >&2; return 1; }
  out="$(mktemp)"
  ssh_apply >"$out" 2>&1 || { rm -f "$out"; return 1; }
  grep -Fq "PermitRootLogin=no" "$out" || { rm -f "$out"; return 1; }
  rm -f "$out"
  [[ "$num" == 3 ]]
)

test_ssh_password_auth_reprompts_invalid_input() (
  local reads=0 confirms=0
  packages() { return 0; }
  ssh_ports() { echo 22; }
  ask_port() { PORT=2203; }
  ask() {
    ((reads+=1))
    if ((reads==1)); then REPLY="yes-no"; else REPLY="yes"; fi
  }
  confirm() { ((confirms+=1)); return 1; }
  ufw() { echo "Unexpected UFW call" >&2; return 1; }
  ssh_apply >/dev/null 2>&1 || return 1
  [[ "$reads" == 2 && "$confirms" == 2 ]]
)

test_ssh_login_target_rejects_unsafe_hostname() (
  SSH_CONNECTION=""
  SSH_CLIENT=""
  SUDO_USER="deploy"
  id() { [[ "$1" == deploy ]]; }
  ip() { return 1; }
  ask() { echo "Unexpected interactive prompt" >&2; return 1; }
  if ssh_prepare_login_target >/dev/null 2>&1; then return 1; fi
  [[ -z "$SSH_LOGIN_TARGET" ]]
)

test_ssh_rollback_contract() {
  grep -Fq -- '--on-active=5min' "$BASE_DIR/modules/ssh.sh" || return 1
  grep -Fq 'ufw allow "$newport/tcp"' "$BASE_DIR/modules/ssh.sh" || return 1
  grep -Fq 'systemctl daemon-reload' "$BASE_DIR/modules/ssh.sh" || return 1
  grep -Fq 'systemctl restart ssh.socket' "$BASE_DIR/modules/ssh.sh" || return 1
}

test_main_menu_has_additional_section_no_backup_item() {
  local menu="$BASE_DIR/setup.sh" expected
  if grep -Fq "printf '8. Резервное копирование" "$menu" ||
     grep -Fq '8) backup_important;;' "$menu" ||
     grep -Fq '8) docker_menu;;' "$menu"; then
    echo "Unwanted top-level backup or Docker entry" >&2
    return 1
  fi
  for expected in \
    "printf '8. Дополнительные настройки\\n'" \
    '8) additional_menu;;' \
    'source "$BASE_DIR/modules/docker.sh"' \
    '6) system_menu;;' \
    '7) diagnostics;;'; do
    grep -Fq -- "$expected" "$menu" || { echo "Missing menu item: $expected" >&2; return 1; }
  done
  grep -Fq "1. Docker" "$BASE_DIR/modules/docker.sh"
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
