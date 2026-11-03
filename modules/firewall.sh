#!/usr/bin/env bash

ufw_allow_ports() {
  local proto="$1" raw list p
  ask "TCP/UDP: порты $proto через запятую (пусто — пропустить)" '' || return 1
  raw="$REPLY"
  list="$(ports_csv "$raw")" || return 1
  for p in $list; do ufw allow "$p/$proto" || return 1; done
  ufw status numbered
}

ufw_remove_ports() {
  local proto="$1" list p active
  ask "Какие порты $proto удалить из ALLOW? Через запятую" '' || return 1
  list="$(ports_csv "$REPLY")" || return 1
  active=" $(ssh_ports | tr '\n' ' ') "
  for p in $list; do
    if [[ $proto == tcp && $active == *" $p "* ]]; then
      warn "$p/tcp — порт SSH, его удаление заблокировано"
      continue
    fi
    if confirm "Удалить allow $p/$proto?"; then
      ufw --force delete allow "$p/$proto" || warn 'Правило не найдено'
    fi
  done
}

# Offer to remove the old world-accessible SSH rule only after a verified
# 22 -> non-22 switch in the current wizard run, with the new SSH port
# configured, selected and allowed in active UFW. Do not touch scoped rules.
ufw_offer_close_previous_ssh_port() {
  local connected_port="$1" previous="${SRV_SETTINGS_CONFIRMED_SSH_OLD_PORT:-}"
  local verified="${SRV_SETTINGS_CONFIRMED_SSH_NEW_PORT:-}" current status rules
  [[ "$previous" == 22 && -n "$verified" && "$verified" != 22 &&
     "$connected_port" == "$verified" ]] || return 0

  current=" $(ssh_ports | tr '\n' ' ') "
  # Never remove the old rule while sshd may still accept port 22.
  [[ "$current" == *" $verified "* && "$current" != *" 22 "* ]] || {
    warn 'SSH всё ещё использует 22/tcp или новый порт не подтверждён sshd; старое правило оставлено.'
    return 0
  }
  status="$(ufw status)" || { warn 'Не удалось прочитать статус UFW; правило 22/tcp оставлено.'; return 0; }
  # Without an active firewall, no firewall-protected login was verified.
  grep -Fxq 'Status: active' <<< "$status" || return 0
  rules="$(ufw show added)" || { warn 'Не удалось прочитать правила UFW; правило 22/tcp оставлено.'; return 0; }
  grep -Fxq 'ufw allow 22/tcp' <<< "$rules" || return 0
  if ! grep -Fxq "ufw allow $verified/tcp" <<< "$rules"; then
    warn "В UFW отсутствует общее правило allow $verified/tcp; 22/tcp оставлен."
    return 0
  fi
  warn "После подтверждённой смены SSH-порта с 22 на $verified старое правило UFW 22/tcp больше не требуется."
  if confirm 'Удалить старое правило UFW allow 22/tcp (IPv4/IPv6)?'; then
    ufw --force delete allow 22/tcp || { warn 'Не удалось удалить старое правило 22/tcp.'; return 1; }
    success 'Старое правило UFW 22/tcp удалено.'
    ufw status numbered
  fi
}

ufw_setup() {
  packages ufw || return 1
  local p current
  current="$(ssh_ports)"
  [[ -n $current ]] || { fail 'Не удалось определить SSH-порт'; return 1; }
  info "Обнаружены SSH-порты: $current"
  local connected_port detected_port
  detected_port="$(printf '%s\n' "$current" | head -n 1)"
  ask "Фактический SSH-порт текущего подключения" "$detected_port" || return 1
  connected_port="$REPLY"
  validate_port "$connected_port" || { fail "Недопустимый SSH-порт"; return 1; }
  for p in $current "$connected_port"; do ufw allow "$p/tcp" || return 1; done
  ufw_allow_ports tcp || return 1
  ufw_allow_ports udp || return 1
  warn 'Проверьте внешний firewall облачного провайдера и доступ через VNC/консоль!'
  if confirm 'Применить default deny incoming / allow outgoing и включить UFW?'; then
    ufw default deny incoming || return 1
    ufw default allow outgoing || return 1
    ufw --force enable || return 1
  fi
  ufw status verbose || return 1
  ufw_offer_close_previous_ssh_port "$connected_port"
}

ufw_menu() {
  local n
  packages ufw || return 1
  while true; do
    printf '\nUFW\n1. Первоначальная настройка\n2. Разрешить TCP-порты\n3. Разрешить UDP-порты\n4. Удалить TCP-правила\n5. Удалить UDP-правила\n6. Список правил\n7. Переключить логирование\n0. Назад\n'
    read_input 'Выбор: ' n || return 0
    case $n in
      1) ufw_setup;;
      2) ufw_allow_ports tcp;;
      3) ufw_allow_ports udp;;
      4) ufw_remove_ports tcp;;
      5) ufw_remove_ports udp;;
      6) ufw status numbered;;
      7) if confirm 'Включить UFW logging low?'; then ufw logging low; else ufw logging off; fi;;
      0) return 0;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}
