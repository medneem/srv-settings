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
  fail2ban-client status sshd
}

fail2ban_unban() {
  local ip
  ask 'IP-адрес для разблокировки' '' || return 1
  ip="$REPLY"
  [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] || { fail 'Недопустимый IP'; return 1; }
  fail2ban-client set sshd unbanip "$ip"
}

fail2ban_menu() {
  local n
  while true; do
    printf '\nFAIL2BAN\n1. Установить и настроить SSH jail (3 попытки / 30 минут / бан 24 часа)\n2. Состояние Fail2ban\n3. Состояние SSH jail\n4. Разбанить IP\n5. Логи (последние 50 строк)\n0. Назад\n'
    read -r -p 'Выбор: ' n || return 0
    case $n in
      1) fail2ban_setup;;
      2) fail2ban-client status;;
      3) fail2ban-client status sshd;;
      4) fail2ban_unban;;
      5) journalctl -u fail2ban -n 50 --no-pager;;
      0) return 0;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}
