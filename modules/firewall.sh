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

ufw_setup() {
  packages ufw || return 1
  local p current
  current="$(ssh_ports)"
  [[ -n $current ]] || { fail 'Не удалось определить SSH-порт'; return 1; }
  info "Сначала открываем SSH-порты: $current"
  for p in $current; do ufw allow "$p/tcp" || return 1; done
  ufw_allow_ports tcp || return 1
  ufw_allow_ports udp || return 1
  warn 'Проверьте внешний firewall облачного провайдера и доступ через VNC/консоль!'
  if confirm 'Применить default deny incoming / allow outgoing и включить UFW?'; then
    ufw default deny incoming || return 1
    ufw default allow outgoing || return 1
    ufw --force enable || return 1
  fi
  ufw status verbose
}

ufw_menu() {
  local n
  packages ufw || return 1
  while true; do
    printf '\nUFW\n1. Первоначальная настройка\n2. Разрешить TCP-порты\n3. Разрешить UDP-порты\n4. Удалить TCP-правила\n5. Удалить UDP-правила\n6. Список правил\n7. Переключить логирование\n0. Назад\n'
    read -r -p 'Выбор: ' n || return 0
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
