#!/usr/bin/env bash

diagnostics() {
  printf '\n========= ДИАГНОСТИКА =========\n'
  lsb_release -ds 2>/dev/null || cat /etc/os-release
  printf '\nЧасовой пояс / NTP:\n'
  timedatectl status 2>/dev/null || true
  printf '\nSSH (эффективные настройки):\n'
  if [[ -x /usr/sbin/sshd ]]; then
    /usr/sbin/sshd -t && /usr/sbin/sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|allowusers) ' || true
  fi
  printf '\nSSH socket/service:\n'
  systemctl is-active ssh.socket ssh.service 2>/dev/null || true
  printf '\nUFW:\n'
  if command -v ufw >/dev/null 2>&1; then ufw status verbose; else warn 'UFW не установлен'; fi
  printf '\nFail2ban:\n'
  if command -v fail2ban-client >/dev/null 2>&1; then
    fail2ban-client status sshd || true
  else
    warn 'Fail2ban не установлен'
  fi
  printf '\nСлушающие TCP/UDP-порты:\n'
  ss -tulpen 2>/dev/null || true
  printf '\nDocker:\n'
  if command -v docker >/dev/null 2>&1; then docker info --format '{{.ServerVersion}}' 2>/dev/null || true; fi
  warn 'UFW не обязательно блокирует Docker published ports. Проверяйте маршрутизацию DOCKER-USER/nftables отдельно.'
}

backup_important() {
  local dest archive
  mkdir -p /var/backups/srv-settings || return 1
  dest="/var/backups/srv-settings/config-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
  local -a list=()
  local f
  for f in /etc/ssh /etc/ufw /etc/fail2ban /etc/docker/daemon.json /etc/sudoers.d; do
    [[ -e $f ]] && list+=("${f#/}")
  done
  (( ${#list[@]} > 0 )) || { warn 'Не найдено конфигураций для резервирования'; return 1; }
  tar -czf "$dest" -C / "${list[@]}" || return 1
  chmod 0600 "$dest"
  info "Резервная копия конфигураций: $dest"
}
