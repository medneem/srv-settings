#!/usr/bin/env bash

# Docker is intentionally not part of the core provisioning workflow.
full_setup() {
  info 'Полная настройка Ubuntu'
  warn 'Оставьте открытой текущую SSH-сессию и убедитесь, что есть консоль VPS/VNC.'
  confirm 'Начать первоначальную настройку?' || return 0
  backup_important || { fail 'Нет резервной копии. Настройка остановлена.'; return 1; }
  system_setup || return 1
  if confirm 'Создать пользователя с правами sudo?'; then user_create || return 1; fi
  if confirm 'Настроить SSH-порт и доступ?'; then ssh_apply || return 1; fi
  if confirm 'Настроить UFW и разрешённые TCP/UDP-порты?'; then ufw_setup || return 1; fi
  if confirm 'Настроить Fail2ban?'; then fail2ban_setup || return 1; fi
  info 'Основная настройка сервера завершена. Docker для неё не требуется.'
  info 'Проверьте диагностику, SSH и firewall облачного провайдера.'
}
