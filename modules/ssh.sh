#!/usr/bin/env bash

# Find the sudo-capable login account without assuming the root SSH user is the new user.
ssh_sudo_login_candidate() {
  local name members
  local -a candidates=()
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] &&
     [[ "$SUDO_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && id "$SUDO_USER" >/dev/null 2>&1; then
    printf '%s\n' "$SUDO_USER"
    return 0
  fi
  members="$(getent group sudo 2>/dev/null)" || return 1
  members="${members##*:}"
  local -a names=()
  IFS=',' read -r -a names <<< "$members"
  for name in "${names[@]}"; do
    [[ -n "$name" && "$name" != root && "$name" =~ ^[a-z_][a-z0-9_-]*$ ]] || continue
    id "$name" >/dev/null 2>&1 || continue
    candidates+=("$name")
  done
  if (( ${#candidates[@]} == 1 )); then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi
  return 1
}

# SSH_CONNECTION: client IP, client port, *server IP*, server port.
# SSH_CLIENT: client IP, client port, *server IP*.
ssh_current_server_address() {
  local client client_port server server_port
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r client client_port server server_port <<< "$SSH_CONNECTION"
  fi
  if [[ -z "${server:-}" && -n "${SSH_CLIENT:-}" ]]; then
    read -r client client_port server <<< "$SSH_CLIENT"
  fi
  case "${server:-}" in
    ""|0.0.0.0|::|::1|localhost|127.*) return 1 ;;
  esac
  [[ "$server" =~ ^[a-zA-Z0-9:][a-zA-Z0-9._:%-]*$ ]] || return 1
  printf '%s\n' "$server"
}

# Prefer the actual server-side port of the current SSH session.
# With systemd ssh.socket the effective sshd -T port can differ from the listener.
ssh_current_login_port() {
  local client client_port server port
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r client client_port server port <<< "$SSH_CONNECTION"
    if validate_port "${port:-}"; then
      printf '%d\n' "$((10#$port))"
      return 0
    fi
  fi
  port="$(ssh_ports | head -n 1)"
  if ! validate_port "${port:-}"; then port=22; fi
  printf '%d\n' "$((10#$port))"
}

# Best-effort fallback when sudo has stripped SSH_CONNECTION.
# Only a single globally routable server address is safe to suggest.
ssh_public_server_address() {
  command -v ip >/dev/null 2>&1 || return 1
  { ip -o -4 addr show scope global 2>/dev/null || true; } |
    awk '$3 == "inet" {print $4}' |
    python3 -c '
import ipaddress
import sys
addresses = set()
for item in sys.stdin:
    try:
        ip = ipaddress.ip_interface(item.strip()).ip
    except ValueError:
        continue
    if ip.is_global:
        addresses.add(str(ip))
if len(addresses) != 1:
    sys.exit(1)
print(next(iter(addresses)))
'
}

# Return a copy-ready target (user@server) in SSH_LOGIN_TARGET, or leave it blank.
# Never guess if there is more than one possible login or no usable server address.
ssh_prepare_login_target() {
  SSH_LOGIN_TARGET=""
  local name server
  name="${1:-}"
  if [[ -z "$name" ]]; then
    name="$(ssh_sudo_login_candidate)" || name=""
  fi
  if [[ -z "$name" ]]; then
    warn 'Не удалось однозначно определить пользователя с sudo. Команда подключения не будет подставлена автоматически.'
    return 1
  fi
  if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]*$ || "$name" == root ]] ||
     ! id "$name" >/dev/null 2>&1; then
    warn 'Не удалось определить действительного пользователя для SSH.'
    return 1
  fi

  server="$(ssh_current_server_address)" || server=""
  if [[ -z "$server" ]]; then
    server="$(ssh_public_server_address)" || server=""
  fi
  if [[ -z "$server" ]]; then
    warn 'Адрес сервера не определён автоматически. Вводить его в мастере не требуется.'
    return 1
  fi
  if [[ ! "$server" =~ ^[a-zA-Z0-9:][a-zA-Z0-9._:%-]*$ ]]; then
    warn 'Обнаружен некорректный адрес сервера.'
    return 1
  fi
  case "$server" in
    0.0.0.0|::|::1|localhost|127.*)
      warn 'Обнаружен локальный адрес сервера, который нельзя использовать для внешнего SSH.'
      return 1
      ;;
  esac
  SSH_LOGIN_TARGET="$name@$server"
}

# Print an executable SSH command for the user just created, even when
# multiple members of the sudo group make autodetection ambiguous.
ssh_show_login_command() {
  local username="$1" port="$2"
  if ssh_prepare_login_target "$username"; then
    printf '\n    ssh -p %s %s\n\n' "$port" "$SSH_LOGIN_TARGET"
  else
    printf '\n    ssh -p %s %s@АДРЕС_СЕРВЕРА\n\n' "$port" "$username"
    warn 'Автоматически определить адрес сервера не удалось. Используйте адрес, по которому подключаетесь обычно.'
  fi
}

# Normalize user input from SSH terminals, including pasted CRLF/whitespace.
ssh_auth_mode_normalize() {
  local mode="${1,,}"
  mode="${mode#"${mode%%[![:space:]]*}"}"
  mode="${mode%"${mode##*[![:space:]]}"}"
  case "$mode" in
    yes|no) printf '%s\n' "$mode" ;;
    *) return 1 ;;
  esac
}

# Validate a fully captured sshd -T snapshot. Do not pipe sshd -T into
# grep -q: with pipefail an early grep exit can cause SIGPIPE (status 141).
ssh_validate_effective_config() {
  local effective="$1" newport="$2" passwd_mode="$3" root_mode="$4"
  local expected key observed mismatch=0
  for expected in "port $newport" "passwordauthentication $passwd_mode" "permitrootlogin $root_mode"; do
    if ! grep -Fxq -- "$expected" <<< "$effective"; then
      key="${expected%% *}"
      observed="$(awk -v key="$key" '$1==key {printf "%s%s", sep, $2; sep=","} END {print ""}' <<< "$effective")"
      [[ -n "$observed" ]] || observed="(отсутствует)"
      warn "sshd -T: ожидалось '$expected', фактически '$key $observed'."
      mismatch=1
    fi
  done
  return "$mismatch"
}

ssh_check_pending_config() {
  local effective
  if ! /usr/sbin/sshd -t; then
    warn 'sshd -t обнаружил ошибку синтаксиса SSH-конфигурации (см. сообщение выше).'
    return 1
  fi
  if ! effective="$(/usr/sbin/sshd -T)"; then
    warn 'Не удалось получить эффективную конфигурацию через sshd -T.'
    return 1
  fi
  ssh_validate_effective_config "$effective" "$1" "$2" "$3"
}

ssh_apply() {
  packages openssh-server ufw || return 1
  local oldport newport passwd_mode root_mode cfg save_dir rollback unit
  local socket_active=0 service_active=0 current_pass current_root
  cfg=/etc/ssh/sshd_config.d/00-00-srv-settings.conf
  oldport="$(ssh_current_login_port)"
  ask_port 'Новый SSH-порт' "$oldport" || return 1
  newport="$PORT"
  current_pass="$(/usr/sbin/sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2;exit}')"
  current_root="$(/usr/sbin/sshd -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2;exit}')"
  while true; do
    ask 'PasswordAuthentication (yes/no)' "${current_pass:-yes}" || return 1
    if passwd_mode="$(ssh_auth_mode_normalize "$REPLY")"; then
      break
    fi
    warn "Укажите yes или no. Получено: $(printf '%q' "$REPLY"). Повторите ввод."
  done
  root_mode="${current_root:-prohibit-password}"
  local login_target=''
  if confirm 'Отключить SSH-вход root (PermitRootLogin no)?'; then
    warn 'После отключения root больше не сможет подключаться по SSH. Сначала проверьте другой способ входа!'
    info '1. НЕ закрывайте текущую SSH-сессию. Откройте ВТОРОЙ терминал на своём компьютере.'
    if ssh_prepare_login_target "${SRV_SETTINGS_CREATED_SUDO_USER:-}"; then
      login_target="$SSH_LOGIN_TARGET"
      info "2. Скопируйте команду ниже во ВТОРОЙ терминал (ТЕКУЩИЙ SSH-порт):"
      printf '\n    ssh -p %s %s\n\n' "$oldport" "$login_target"
      info '   Убедитесь, что адрес сервера доступен с вашего компьютера (учтите NAT и доменные имена).'
    else
      info '2. Подключитесь в другом терминале привычным способом на ТЕКУЩИЙ SSH-порт:'
      printf '\n    ssh -p %s ПОЛЬЗОВАТЕЛЬ@АДРЕС_СЕРВЕРА\n\n' "$oldport"
      warn 'Адрес сервера не запрашивается. Воспользуйтесь адресом, по которому вы обычно подключаетесь.'
    fi
    info '3. Выполните whoami — должно быть имя созданного пользователя, не root.'
    info '4. Выполните: sudo -v && sudo id -u — ожидается 0. При NOPASSWD пароль не требуется.'
    info 'Только после успешной проверки отвечайте y. Если не проверили — нажмите Enter (N).'
    if confirm 'Уже вошли во ВТОРОМ SSH-сеансе под созданным пользователем и проверили sudo (вывод 0)?'; then
      root_mode=no
    else
      warn 'Root SSH оставлен без изменений'
    fi
  fi
  warn "Новые настройки: port=$newport, PasswordAuthentication=$passwd_mode, PermitRootLogin=$root_mode"
  warn 'Текущая SSH-сессия должна оставаться открытой. Новый порт надо проверить во ВТОРОМ терминале.'
  confirm 'Применить с автоматическим откатом через 5 минут?' || return 0

  # Открываем оба порта ДО перезапуска SSH; старые UFW-правила не удаляются.
  local p
  for p in $(ssh_ports); do ufw allow "$p/tcp" || return 1; done
  ufw allow "$newport/tcp" || return 1

  mkdir -p /etc/ssh/sshd_config.d /var/backups/srv-settings || return 1
  save_dir="$(mktemp -d /var/backups/srv-settings/ssh-XXXXXXXX)" || return 1
  if [[ -f $cfg ]]; then cp -a "$cfg" "$save_dir/original.conf" || return 1; fi
  systemctl is-active --quiet ssh.socket && socket_active=1
  systemctl is-active --quiet ssh.service && service_active=1
  if (( socket_active == 0 && service_active == 0 )); then
    fail 'Не найдены работающие ssh.socket или ssh.service'; return 1
  fi
  rollback="$save_dir/rollback.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -eu'
    if [[ -f $save_dir/original.conf ]]; then
      printf 'cp -a %q %q\n' "$save_dir/original.conf" "$cfg"
    else
      printf 'rm -f %q\n' "$cfg"
    fi
    echo 'systemctl daemon-reload'
    (( socket_active == 0 )) || echo 'systemctl restart ssh.socket'
    (( service_active == 0 )) || echo 'systemctl restart ssh.service'
  } > "$rollback"

  unit="srv-settings-ssh-rollback-$$"
  if ! systemd-run --quiet --unit="$unit" --on-active=5min /bin/bash "$rollback"; then
    fail 'Не удалось запланировать откат. Конфигурация НЕ изменена'; return 1
  fi

  printf 'Port %s\nPermitRootLogin %s\nPasswordAuthentication %s\n' \
    "$newport" "$root_mode" "$passwd_mode" > "$cfg"
  chmod 0644 "$cfg"

  if ! ssh_check_pending_config "$newport" "$passwd_mode" "$root_mode"; then
    warn 'Проверка SSH не прошла: значения не применились или конфигурация некорректна. Выполняем откат.'
    bash "$rollback" || warn "Ручное восстановление: bash $rollback"
    systemctl stop "$unit.timer" || true
    return 1
  fi

  local apply_ok=1
  systemctl daemon-reload || apply_ok=0
  if (( apply_ok && socket_active )); then
    systemctl restart ssh.socket || apply_ok=0
  fi
  if (( apply_ok && service_active )); then
    systemctl restart ssh.service || apply_ok=0
  fi
  if (( ! apply_ok )); then
    warn 'Не удалось перезапустить SSH. Выполняем откат!'
    bash "$rollback" || warn "Ручное восстановление: bash $rollback"
    systemctl stop "$unit.timer" || true
    return 1
  fi
  if ! ss -H -ltn | awk -v port=":$newport" '$4 ~ port "$" {found=1} END {exit !found}'; then
    warn 'Новый порт не слушается. Выполняем откат!'
    bash "$rollback" || warn "Ручное восстановление: bash $rollback"
    systemctl stop "$unit.timer" || true
    return 1
  fi

  info "SSH слушает $newport. В течение 5 минут проверьте НОВОЕ подключение из второго терминала:"
  if [[ -n "$login_target" ]]; then
    printf '\n    ssh -p %s %s\n\n' "$newport" "$login_target"
  else
    warn 'Для подключения используйте: ssh -p НОВЫЙ_ПОРТ ПОЛЬЗОВАТЕЛЬ@АДРЕС_СЕРВЕРА'
    info "Новый SSH-порт: $newport"
  fi
  if confirm 'Удалось войти в НОВОМ терминале по SSH? (yes отменяет автооткат)'; then
    systemctl stop "$unit.timer" || warn 'Не удалось отменить таймер: проверьте systemctl list-timers!'
    info 'Настройки сохранены. Старые порты UFW НЕ удалены; их можно закрыть позже вручную.'
  else
    warn 'Восстановление предыдущей SSH-конфигурации'
    bash "$rollback" || warn "Ручное восстановление: bash $rollback"
    systemctl stop "$unit.timer" || true
  fi
}

# /etc/ssh/sshd_config is the source of truth for requested global AllowUsers.
ssh_allowusers_config_path() { printf '%s\n' /etc/ssh/sshd_config; }

ssh_allowusers_cancel_rollback() {
  local unit="$1"
  if ! systemctl stop "$unit.timer"; then
    warn "Не удалось остановить таймер отката $unit.timer."
    return 1
  fi
  if systemctl is-active --quiet "$unit.timer"; then
    warn "Таймер отката $unit.timer всё ещё активен."
    return 1
  fi
  return 0
}

ssh_allowusers_apply() {
  local username="$1" cfg staged saved unit rollback status_effective port
  local service_active=0 socket_active=0
  cfg="$(ssh_allowusers_config_path)"
  if [[ ! -f "$cfg" ]]; then
    fail "Отсутствует SSH-конфигурация $cfg"
    return 1
  fi
  if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ || "$username" == root ]]; then
    fail 'Некорректное имя пользователя для AllowUsers'
    return 1
  fi
  staged="$(mktemp "$(dirname "$cfg")/.srv-settings-sshd.XXXXXXXX")" || return 1
  if ! cp -p -- "$cfg" "$staged" ||
     ! python3 "$BASE_DIR/lib/ssh_allowusers.py" "$cfg" "$staged" "$username"; then
    rm -f -- "$staged"
    fail 'Не удалось подготовить изменение AllowUsers.'
    return 1
  fi
  if cmp -s -- "$cfg" "$staged"; then
    rm -f -- "$staged"
    info "Пользователь $username уже присутствует в глобальном AllowUsers."
    return 0
  fi

  if ! /usr/sbin/sshd -t -f "$staged"; then
    rm -f -- "$staged"
    fail 'sshd отклонил подготовленную конфигурацию; оригинал не изменён.'
    return 1
  fi
  if ! status_effective="$(/usr/sbin/sshd -T -f "$staged" -C "user=$username,host=localhost,addr=127.0.0.1")"; then
    rm -f -- "$staged"
    fail 'Не удалось проверить AllowUsers через sshd -T.'
    return 1
  fi
  if ! awk -v user="$username" '
    $1 == "allowusers" {
      for (i=2; i<=NF; i++) if ($i == user) found=1
    }
    END {exit !found}
  ' <<< "$status_effective"; then
    rm -f -- "$staged"
    fail "В эффективном AllowUsers отсутствует $username; оригинал не изменён."
    return 1
  fi
  systemctl is-active --quiet ssh.service && service_active=1
  systemctl is-active --quiet ssh.socket && socket_active=1
  if (( ! service_active && ! socket_active )); then
    rm -f -- "$staged"
    fail 'ssh.service и ssh.socket не активны; ограничение доступа не применено.'
    return 1
  fi

  install -d -m 0700 /var/backups/srv-settings || { rm -f -- "$staged"; return 1; }
  saved="$(mktemp -d /var/backups/srv-settings/ssh-allowusers-XXXXXXXX)" || {
    rm -f -- "$staged"; return 1
  }
  if ! cp -a -- "$cfg" "$saved/original"; then
    rm -f -- "$staged"
    return 1
  fi
  rollback="$saved/rollback.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -eu'
    printf 'cp -a -- %q %q\n' "$saved/original" "$cfg"
    echo '/usr/sbin/sshd -t'
    (( ! service_active )) || echo 'systemctl reload ssh.service || systemctl restart ssh.service'
  } > "$rollback"
  chmod 0700 "$rollback" || { rm -f -- "$staged"; return 1; }

  unit="srv-settings-allowusers-$$"
  if ! systemd-run --quiet --unit="$unit" --on-active=5min /bin/bash "$rollback"; then
    rm -f -- "$staged"
    fail 'Не удалось назначить автоматический откат: AllowUsers не изменён.'
    return 1
  fi

  if ! mv -f -- "$staged" "$cfg" || ! /usr/sbin/sshd -t ||
     { (( service_active )) && ! systemctl reload ssh.service; }; then
    warn 'Не удалось применить AllowUsers. Восстанавливаю прежний SSH-конфиг.'
    bash "$rollback" || warn "Аварийный откат: sudo bash $rollback"
    systemctl stop "$unit.timer" || true
    return 1
  fi

  info "AllowUsers $username записано в $cfg."
  warn 'После применения AllowUsers повторно откройте НОВОЕ SSH-подключение во втором терминале:'
  port="$(ssh_current_login_port)"
  ssh_show_login_command "$username" "$port"
  info "В новом сеансе выполните: whoami; sudo id -u (ожидаются $username и 0)."
  warn 'Если вход не работает, НЕ закрывайте текущую сессию. Автооткат через 5 минут.'
  if confirm "Подтверждаете НОВЫЙ успешный SSH-вход $username с sudo (вывод 0)? (y отменяет откат)"; then
    if ssh_allowusers_cancel_rollback "$unit"; then
      info 'AllowUsers подтверждён; автоматический откат отменён.'
    else
      warn "Таймер отката не удалось надёжно отменить. Проверьте: systemctl list-timers --all"
      return 1
    fi
  else
    warn 'Подтверждение не получено: восстанавливаю прежнюю конфигурацию.'
    bash "$rollback" || warn "Аварийный откат: sudo bash $rollback"
    systemctl stop "$unit.timer" || true
  fi
}

ssh_allow_user_after_creation() {
  local username="$1" port
  port="$(ssh_current_login_port)"
  warn 'AllowUsers ограничит SSH-вход только перечисленными пользователями, включая нового.'
  warn 'Если до сих пор не было AllowUsers, root и другие учётные записи потеряют возможность нового SSH-входа.'
  info '1. НЕ закрывайте текущую SSH-сессию.'
  info '2. Откройте ВТОРОЙ терминал на своём компьютере и выполните:'
  ssh_show_login_command "$username" "$port"
  info '   Если сервер использует NAT или перенаправление портов, подставьте внешний адрес/порт.'
  info '3. После входа во втором терминале выполните:'
  printf '\n    whoami\n    sudo id -u\n\n'
  info "   Ожидается: $username и 0. При настроенном NOPASSWD пароль sudo не потребуется."
  warn 'Если вход не работает, отвечайте N. Изменять AllowUsers пока нельзя.'
  confirm "Добавить $username в глобальный AllowUsers (/etc/ssh/sshd_config)?" || return 0
  confirm "Уже проверили вход $username в ОТДЕЛЬНОМ SSH-сеансе и sudo (0)?" || {
    warn 'AllowUsers не изменён до проверки входа.'
    return 0
  }
  ssh_allowusers_apply "$username"
}

ssh_menu() {
  local n
  while true; do
    printf '\nSSH\n1. Порт, парольная аутентификация и root (с откатом)\n2. Показать действующую конфигурацию\n0. Назад\n'
    read_input 'Выбор: ' n || return 0
    case $n in
      1) ssh_apply;;
      2) /usr/sbin/sshd -T 2>/dev/null | grep -E '^(port|passwordauthentication|permitrootlogin|allowusers) '; systemctl status ssh.service ssh.socket --no-pager -l || true;;
      0) return 0;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}
