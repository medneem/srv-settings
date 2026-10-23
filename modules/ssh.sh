#!/usr/bin/env bash

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

ssh_apply() {
  packages openssh-server ufw || return 1
  local oldport newport passwd_mode root_mode cfg save_dir rollback unit
  local socket_active=0 service_active=0 current_pass current_root
  cfg=/etc/ssh/sshd_config.d/00-00-srv-settings.conf
  oldport="$(ssh_ports | head -n 1)"
  oldport="${oldport:-22}"
  ask_port 'Новый SSH-порт' "$oldport" || return 1
  newport="$PORT"
  current_pass="$(/usr/sbin/sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2;exit}')"
  current_root="$(/usr/sbin/sshd -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2;exit}')"
  ask 'PasswordAuthentication (yes/no)' "${current_pass:-yes}" || return 1
  if ! passwd_mode="$(ssh_auth_mode_normalize "$REPLY")"; then
    fail 'Укажите yes или no'
    return 1
  fi
  root_mode="${current_root:-prohibit-password}"
  if confirm 'Отключить SSH-вход root (PermitRootLogin no)?'; then
    if confirm 'Я уже ПРОВЕРИЛ вход другого пользователя с sudo в отдельном SSH-сеансе'; then
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

  if ! /usr/sbin/sshd -t ||
     ! /usr/sbin/sshd -T | grep -qx "port $newport" ||
     ! /usr/sbin/sshd -T | grep -qx "passwordauthentication $passwd_mode" ||
     ! /usr/sbin/sshd -T | grep -qx "permitrootlogin $root_mode"; then
    warn 'Проверка sshd не прошла, выполняем откат'
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

  info "SSH слушает $newport. В течение 5 минут проверьте НОВОЕ подключение: ssh -p $newport USER@SERVER"
  if confirm 'Удалось войти в НОВОМ терминале по SSH? (yes отменяет автооткат)'; then
    systemctl stop "$unit.timer" || warn 'Не удалось отменить таймер: проверьте systemctl list-timers!'
    info 'Настройки сохранены. Старые порты UFW НЕ удалены; их можно закрыть позже вручную.'
  else
    warn 'Восстановление предыдущей SSH-конфигурации'
    bash "$rollback" || warn "Ручное восстановление: bash $rollback"
    systemctl stop "$unit.timer" || true
  fi
}

ssh_menu() {
  local n
  while true; do
    printf '\nSSH\n1. Порт, парольная аутентификация и root (с откатом)\n2. Показать действующую конфигурацию\n0. Назад\n'
    read -r -p 'Выбор: ' n || return 0
    case $n in
      1) ssh_apply;;
      2) /usr/sbin/sshd -T 2>/dev/null | grep -E '^(port|passwordauthentication|permitrootlogin|allowusers) '; systemctl status ssh.service ssh.socket --no-pager -l || true;;
      0) return 0;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}
