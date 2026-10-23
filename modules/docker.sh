#!/usr/bin/env bash

# Docker Engine from Docker's official apt repository, not Ubuntu docker.io.
docker_repo_key_path() { printf '%s\n' /etc/apt/keyrings/docker.asc; }
docker_repo_sources_path() { printf '%s\n' /etc/apt/sources.list.d/docker.sources; }

docker_ubuntu_codename() {
  case "$VERSION_ID" in
    22.04) printf 'jammy\n';;
    24.04) printf 'noble\n';;
    26.04) printf 'resolute\n';;
    *) return 1;;
  esac
}

docker_package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

docker_conflicting_packages() {
  local package
  for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    if docker_package_installed "$package"; then printf '%s\n' "$package"; fi
  done
}

docker_install() {
  local codename arch key_path sources_path key_stage sources_stage conflicts_text
  local -a conflicts=()
  if ! codename="$(docker_ubuntu_codename)"; then
    fail 'Docker: поддерживаются только Ubuntu 22.04, 24.04 и 26.04 LTS.'
    return 1
  fi
  if docker_package_installed docker-ce && command -v docker >/dev/null 2>&1 &&
     docker compose version >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    info 'Официальный Docker Engine и Compose уже установлены и работают.'
    return 0
  fi

  warn 'Docker — ДОПОЛНИТЕЛЬНЫЙ компонент. Для основной настройки сервера он не требуется.'
  warn 'Docker при публикации контейнерных портов может обходить правила UFW.'
  warn 'Docker daemon запускается с привилегиями root; группа docker даёт эквивалентные права.'
  info 'Источник: https://download.docker.com/linux/ubuntu (stable), без get.docker.com.'
  confirm 'Установить Docker Engine + Compose из официального Docker APT-репозитория?' || return 0

  mapfile -t conflicts < <(docker_conflicting_packages)
  if (( ${#conflicts[@]} > 0 )); then
    conflicts_text="${conflicts[*]}"
    warn "Найдены несовместимые пакеты: $conflicts_text"
    warn 'Удаление этих пакетов может остановить существующие контейнеры и сервисы (включая containerd).'
    warn 'Данные /var/lib/docker и /var/lib/containerd автоматически НЕ удаляются.'
    confirm 'Разрешить УДАЛЕНИЕ перечисленных пакетов для перехода на официальный Docker?' || return 0
  fi

  packages ca-certificates curl || return 1
  arch="$(dpkg --print-architecture)" || return 1
  case "$arch" in
    amd64|arm64|armhf|s390x|ppc64el) ;;
    *) fail "Неизвестная архитектура Docker: $arch"; return 1;;
  esac
  key_path="$(docker_repo_key_path)"
  sources_path="$(docker_repo_sources_path)"
  install -d -m 0755 "$(dirname "$key_path")" "$(dirname "$sources_path")" || return 1

  key_stage="$(mktemp "$(dirname "$key_path")/.docker-key.XXXXXXXX")" || return 1
  if ! curl -fLSs --retry 3 -o "$key_stage" https://download.docker.com/linux/ubuntu/gpg ||
     ! grep -Fq -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$key_stage"; then
    rm -f -- "$key_stage"
    fail 'Не удалось получить корректный официальный ключ Docker; настройки APT не изменены.'
    return 1
  fi
  chmod 0644 "$key_stage" || { rm -f -- "$key_stage"; return 1; }
  sources_stage="$(mktemp "$(dirname "$sources_path")/.docker-sources.XXXXXXXX")" || {
    rm -f -- "$key_stage"
    return 1
  }
  if ! printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n' \
      "$codename" "$arch" "$key_path" > "$sources_stage"; then
    rm -f -- "$key_stage" "$sources_stage"
    return 1
  fi
  chmod 0644 "$sources_stage" || { rm -f -- "$key_stage" "$sources_stage"; return 1; }

  if [[ -f "$key_path" ]] && ! cmp -s -- "$key_path" "$key_stage"; then
    backup "$key_path" || { rm -f -- "$key_stage" "$sources_stage"; return 1; }
  fi
  if [[ -f "$sources_path" ]] && ! cmp -s -- "$sources_path" "$sources_stage"; then
    backup "$sources_path" || { rm -f -- "$key_stage" "$sources_stage"; return 1; }
  fi
  if [[ -f "$key_path" ]] && cmp -s -- "$key_path" "$key_stage"; then
    rm -f -- "$key_stage"
  else
    mv -f -- "$key_stage" "$key_path" || { rm -f -- "$key_stage" "$sources_stage"; return 1; }
  fi
  if [[ -f "$sources_path" ]] && cmp -s -- "$sources_path" "$sources_stage"; then
    rm -f -- "$sources_stage"
  else
    mv -f -- "$sources_stage" "$sources_path" || { rm -f -- "$sources_stage"; return 1; }
  fi

  apt-get update || { fail 'APT: не удалось обновить индекс Docker-репозитория.'; return 1; }
  # Never remove an existing engine before the official repository and its
  # Docker CE candidate have been verified on this Ubuntu release.
  if ! LC_ALL=C apt-cache policy docker-ce |
       awk '$1 == "Candidate:" && $2 != "(none)" {found=1} END {exit !found}'; then
    fail 'APT: официальный docker-ce недоступен для этой версии/архитектуры Ubuntu.'
    return 1
  fi
  if (( ${#conflicts[@]} > 0 )); then
    if ! DEBIAN_FRONTEND=noninteractive apt-get remove -y "${conflicts[@]}"; then
      fail 'Не удалось удалить конфликтующие пакеты.'
      return 1
    fi
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
    fail 'APT: установка Docker завершилась ошибкой; проверьте вывод APT.'
    return 1
  }
  systemctl enable --now docker || { fail 'Не удалось запустить docker.service'; return 1; }
  docker --version || return 1
  docker compose version || { fail 'Не удалось проверить Docker Compose plugin.'; return 1; }
  info 'Docker Engine, Buildx и Compose установлены. Пользователи НЕ добавлены в группу docker.'
  info 'Зеркала Docker Hub при необходимости настройте через пункт 2 меню Docker.'
}

docker_status() {
  if ! command -v docker >/dev/null 2>&1; then
    info 'Docker не установлен.'
    return 0
  fi
  docker --version || return 1
  docker compose version || warn 'Плагин Docker Compose недоступен.'
  systemctl status docker --no-pager -l || true
}


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
  local n
  while true; do
    printf '\nDOCKER (необязательно)\n1. Установить Docker Engine + Compose (официальный APT)\n2. Настроить зеркала Docker Hub\n3. Проверить состояние Docker\n4. Показать daemon.json\n0. Назад\n'
    read_input 'Выбор: ' n || return 0
    case "$n" in
      1) docker_install;;
      2) docker_mirrors;;
      3) docker_status;;
      4) if [[ -f /etc/docker/daemon.json ]]; then cat /etc/docker/daemon.json; else info 'Файл ещё не создан'; fi;;
      0) return 0;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}

additional_menu() {
  local n
  while true; do
    printf '\nДОПОЛНИТЕЛЬНЫЕ НАСТРОЙКИ\n1. Docker (необязательно)\n0. Назад\n'
    read_input 'Выбор: ' n || return 0
    case "$n" in
      1) docker_menu;;
      0) return 0;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}
