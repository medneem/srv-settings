#!/usr/bin/env bash
# Interactive Ubuntu server configuration. Run with sudo.
set -uo pipefail
umask 077  # Резервные копии могут содержать приватные SSH-ключи.

BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if (( EUID != 0 )); then
  printf 'Запустите: sudo bash %s\n' "$BASE_DIR/setup.sh" >&2
  exit 1
fi
if [[ ! -r /etc/os-release ]]; then echo 'Нет /etc/os-release' >&2; exit 1; fi
. /etc/os-release
if [[ ${ID:-} != ubuntu ]]; then echo 'Требуется Ubuntu Server' >&2; exit 1; fi

source "$BASE_DIR/modules/common.sh"
source "$BASE_DIR/modules/system.sh"
source "$BASE_DIR/modules/users.sh"
source "$BASE_DIR/modules/ssh.sh"
source "$BASE_DIR/modules/firewall.sh"
source "$BASE_DIR/modules/fail2ban.sh"
source "$BASE_DIR/modules/docker.sh"
source "$BASE_DIR/modules/diagnostics.sh"
source "$BASE_DIR/modules/full_setup.sh"

if ubuntu_release_supported "${VERSION_ID:-}"; then
  info "Поддерживаемая Ubuntu $VERSION_ID LTS"
else
  warn "Ubuntu ${VERSION_ID:-unknown}: поддерживаются LTS 22.04, 24.04, 26.04."
  confirm 'Продолжить на неподтверждённой версии?' || exit 1
fi

main_menu() {
  local choice
  while true; do
    printf '\n========== SERVER SETTINGS ==========\n'
    printf '1. Полная первоначальная настройка\n'
    printf '2. Управление TCP/UDP-портами (UFW)\n'
    printf '3. Настройка SSH\n'
    printf '4. Управление пользователями и sudo\n'
    printf '5. Настройка Fail2ban\n'
    printf '6. Docker (необязательно)\n'
    printf '7. Обновление системы / время\n'
    printf '8. Диагностика\n'
    printf '9. Резервное копирование конфигурации\n'
    printf '0. Выход\n'
    printf '=====================================\n'
    read -r -p 'Выбор: ' choice || { printf '\n'; return 0; }
    case "$choice" in
      1) full_setup || warn 'Настройка остановлена из-за ошибки';;
      2) ufw_menu;;
      3) ssh_menu;;
      4) users_menu;;
      5) fail2ban_menu;;
      6) docker_menu;;
      7) system_menu;;
      8) diagnostics;;
      9) backup_important;;
      0) info 'Выход'; return 0;;
      *) warn 'Выберите пункт меню от 0 до 9';;
    esac
  done
}
main_menu
