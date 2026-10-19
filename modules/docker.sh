#!/usr/bin/env bash

docker_mirrors() {
  if ! command -v docker >/dev/null 2>&1; then
    info 'Docker не установлен: настройка зеркал пропущена. Установка не требуется.'
    return 0
  fi
  packages python3 || return 1
  local cfg=/etc/docker/daemon.json
  warn 'Изменение registry-mirrors может повлиять на docker pull. Перезапуск Docker может прервать контейнеры.'
  confirm 'Добавить предложенные зеркала к существующему daemon.json?' || return 0
  mkdir -p /etc/docker
  backup "$cfg" || return 1
  local staged
  staged="$(mktemp /etc/docker/.daemon.json.XXXXXXXX)" || return 1
  if ! python3 "$BASE_DIR/lib/docker_mirrors.py" "$cfg" "$staged"; then
    rm -f -- "$staged"
    fail 'Ошибка разбора существующего daemon.json (оригинал не изменён)'
    return 1
  fi
  if command -v dockerd >/dev/null 2>&1; then
    if ! dockerd --validate --config-file "$staged"; then
      rm -f -- "$staged"
      fail 'dockerd отклонил конфигурацию; оригинал не изменён'
      return 1
    fi
  else
    warn 'dockerd отсутствует: синтаксис JSON проверен, но проверка конфигурации Docker недоступна.'
  fi
  mv -f -- "$staged" "$cfg" || return 1
  if confirm 'Перезапустить Docker СЕЙЧАС? (может прервать контейнеры)'; then
    systemctl restart docker || return 1
  else
    warn 'Изменения вступят в силу после перезапуска Docker.'
  fi
}

docker_menu() {
  if ! command -v docker >/dev/null 2>&1; then
    info 'Docker не установлен. Дополнительная настройка не требуется.'
    return 0
  fi
  local n
  while true; do
    printf '\nDOCKER\n1. Добавить зеркала Docker Hub\n2. Показать daemon.json\n0. Назад\n'
    read -r -p 'Выбор: ' n || return 0
    case $n in
      1) docker_mirrors;;
      2) if [[ -f /etc/docker/daemon.json ]]; then cat /etc/docker/daemon.json; else info 'Файл ещё не создан'; fi;;
      0) return 0;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}
