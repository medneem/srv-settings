#!/usr/bin/env bash

fail2ban_setup() {
  packages fail2ban python3-systemd ufw || return 1
  local cfg=/etc/fail2ban/jail.d/90-srv-settings.local
  local port_list
  port_list="$(ssh_ports | paste -sd, -)"
  [[ -n $port_list ]] || { fail 'Не удалось определить SSH-порт'; return 1; }
  backup "$cfg" || return 1
  # Keep a rollback copy in case fail2ban-client -t fails.
  local temp
  temp="$(mktemp)" || return 1
  if [[ -f $cfg ]]; then cp -a "$cfg" "$temp"; else : >"$temp"; fi
  cat >"$cfg" <<EOF
[DEFAULT]
maxretry = 3
findtime = 30m
bantime = 24h
banaction = ufw

[sshd]
enabled = true
backend = systemd
port = $port_list
EOF
  if ! fail2ban-client -t; then
    if [[ -s $temp ]]; then cp -a "$temp" "$cfg"; else rm -f "$cfg"; fi
    rm -f "$temp"
    fail 'Ошибка конфигурации Fail2ban; изменения отменены'
    return 1
  fi
  rm -f "$temp"
  systemctl enable --now fail2ban || return 1
  systemctl restart fail2ban || return 1
  fail2ban-client status sshd || return 1
  if confirm 'Добавить доверенные IP/CIDR для SSH сейчас?'; then
    fail2ban_ignore_update add || return 1
  fi
}

fail2ban_unban() {
  local ip
  ask 'IP-адрес для разблокировки' '' || return 1
  ip="$REPLY"
  [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] || { fail 'Недопустимый IP'; return 1; }
  fail2ban-client set sshd unbanip "$ip"
}

# Entries in the managed .local file are specific to the SSH jail.
# Fail2ban reads them after 90-srv-settings.local, so repeat setup keeps them.
fail2ban_ignore_path() {
  printf '%s\n' /etc/fail2ban/jail.d/95-srv-settings-ignore.local
}

fail2ban_ignore_show() {
  local cfg
  cfg="$(fail2ban_ignore_path)"
  info "Исключения SSH, управляемые srv-settings:"
  python3 "$BASE_DIR/lib/fail2ban_ignore.py" show "$cfg" || return 1
  if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
    info "Фактические исключения активного SSH jail:"
    fail2ban-client get sshd ignoreip || return 1
  else
    warn 'Активный SSH jail не найден; показаны только сохранённые исключения.'
  fi
}

fail2ban_ignore_update() {
  local action="$1" cfg raw staged old_copy=''
  local had_original=0
  if ! command -v fail2ban-client >/dev/null 2>&1 ||
     ! fail2ban-client status sshd >/dev/null 2>&1; then
    warn 'Сначала установите и настройте Fail2ban (пункт 1). SSH jail должен быть активен.'
    return 1
  fi
  cfg="$(fail2ban_ignore_path)"
  ask 'IP-адреса / CIDR-сети через запятую (IPv4, IPv6)' '' || return 1
  raw="$REPLY"
  staged="$(mktemp /etc/fail2ban/jail.d/.srv-settings-ignore.XXXXXXXX)" || return 1
  if ! python3 "$BASE_DIR/lib/fail2ban_ignore.py" "$action" "$cfg" "$raw" >"$staged"; then
    rm -f -- "$staged"
    return 1
  fi

  if { [[ -f "$cfg" ]] && cmp -s -- "$cfg" "$staged"; } ||
     { [[ ! -e "$cfg" ]] && [[ ! -s "$staged" ]]; }; then
    rm -f -- "$staged"
    info 'Изменений в списке нет.'
    return 0
  fi

  warn 'Новый ignoreip применяется только к sshd и может переопределить ignoreip для sshd из других .local файлов.'
  fail2ban-client get sshd ignoreip || warn 'Не удалось прочесть текущий список.'
  confirm 'Сохранить изменения в исключениях SSH?' || { rm -f -- "$staged"; return 0; }

  if [[ -f "$cfg" ]]; then
    had_original=1
    old_copy="$(mktemp /etc/fail2ban/jail.d/.srv-settings-previous.XXXXXXXX)" || { rm -f -- "$staged"; return 1; }
    if ! cp -a -- "$cfg" "$old_copy"; then
      rm -f -- "$old_copy" "$staged"
      return 1
    fi
    backup "$cfg" || { rm -f -- "$old_copy" "$staged"; return 1; }
  fi

  if [[ -s "$staged" ]]; then
    chmod 0644 "$staged" || { rm -f -- "$old_copy" "$staged"; return 1; }
    if ! mv -f -- "$staged" "$cfg"; then
      rm -f -- "$old_copy" "$staged"
      return 1
    fi
  else
    rm -f -- "$staged"
    rm -f -- "$cfg" || return 1
  fi

  if ! fail2ban-client -t || ! fail2ban-client reload sshd; then
    warn 'Ошибка проверки или перезагрузки Fail2ban — восстанавливаю предыдущую конфигурацию.'
    if (( had_original )); then
      mv -f -- "$old_copy" "$cfg" || { fail "Ручное восстановление из $old_copy"; return 1; }
    else
      rm -f -- "$cfg"
    fi
    fail2ban-client reload sshd || warn 'Не удалось восстановить активную конфигурацию SSH jail.'
    return 1
  fi
  [[ -z "$old_copy" ]] || rm -f -- "$old_copy"
  info 'Исключения сохранены и применены к SSH jail.'
  fail2ban-client get sshd ignoreip
}

fail2ban_menu() {
  local n
  while true; do
    printf '\nFAIL2BAN\n1. Установить и настроить SSH jail (3 попытки / 30 минут / бан 24 часа)\n2. Состояние Fail2ban\n3. Состояние SSH jail\n4. Разбанить IP\n5. Логи (последние 50 строк)\n6. Добавить IP/CIDR в исключения SSH (через запятую)\n7. Удалить IP/CIDR из исключений SSH\n8. Показать исключения SSH\n0. Назад\n'
    read -r -p 'Выбор: ' n || return 0
    case $n in
      1) fail2ban_setup;;
      2) fail2ban-client status;;
      3) fail2ban-client status sshd;;
      4) fail2ban_unban;;
      5) journalctl -u fail2ban -n 50 --no-pager;;
      6) fail2ban_ignore_update add;;
      7) fail2ban_ignore_update remove;;
      8) fail2ban_ignore_show;;
      0) return 0;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}
