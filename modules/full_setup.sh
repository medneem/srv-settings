#!/usr/bin/env bash

# Docker is intentionally not part of the core provisioning workflow.
full_setup() {
  info 'Полная настройка Ubuntu'
  attention 'Оставьте открытой текущую SSH-сессию и убедитесь, что есть консоль VPS/VNC.'
  confirm 'Начать первоначальную настройку?' || return 0

  section "1/6" 'РЕЗЕРВНОЕ КОПИРОВАНИЕ'
  backup_important || { fail 'Нет резервной копии. Настройка остановлена.'; return 1; }

  section "2/6" 'СИСТЕМА И ЧАСОВОЙ ПОЯС'
  system_setup || return 1

  section "3/6" 'ПОЛЬЗОВАТЕЛИ И SUDO'
  if confirm 'Создать пользователя с правами sudo?'; then user_create || return 1; fi

  section "4/6" 'SSH И БЕЗОПАСНОСТЬ'
  if confirm 'Настроить SSH-порт и доступ?'; then ssh_apply || return 1; fi

  section "5/6" 'БРАНДМАУЭР UFW'
  if confirm 'Настроить UFW и разрешённые TCP/UDP-порты?'; then ufw_setup || return 1; fi

  section "6/6" 'ЗАЩИТА FAIL2BAN'
  if confirm 'Настроить Fail2ban?'; then fail2ban_setup || return 1; fi

  success 'Основная настройка сервера завершена. Docker для неё не требуется.'
  info 'Проверьте диагностику, SSH и firewall облачного провайдера.'
}
