#!/usr/bin/env bash

system_setup() {
  info 'Установка базовых пакетов (curl, UFW, Fail2ban, rsyslog)'
  packages ca-certificates curl ufw fail2ban rsyslog || return 1
  local zone
  zone="$(timedatectl show -p Timezone --value 2>/dev/null)"
  ask 'Часовой пояс (например, Europe/Moscow)' "${zone:-Etc/UTC}" || return 1
  if timedatectl list-timezones | grep -Fxq -- "$REPLY"; then
    timedatectl set-timezone "$REPLY" || return 1
  else
    warn 'Неизвестный часовой пояс; изменение пропущено'
  fi
  timedatectl set-ntp true || warn 'Не удалось включить синхронизацию NTP'
  if confirm 'Обновить все установленные пакеты (apt upgrade)?'; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  fi
  timedatectl status
}

system_menu() {
  local n
  while true; do
    printf '\nСИСТЕМА\n1. Установить базовые пакеты и настроить время\n2. apt update && apt upgrade\n0. Назад\n'
    read_input 'Выбор: ' n || return 0
    case $n in
      1) system_setup;;
      2) if confirm 'Обновить пакеты?'; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; fi;;
      0) return 0;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}
