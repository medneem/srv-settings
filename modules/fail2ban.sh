#!/usr/bin/env bash

# Keep file paths mockable: CI must never write to the host's /etc.
fail2ban_setup_path() {
  printf '%s\n' /etc/fail2ban/jail.d/90-srv-settings.local
}


# fail2ban 1.0.x on Ubuntu 24.04 emits a warning when the global
# [Definition] allowipv6 option is not set. This is not a jail setting.
# Keep the managed override separate from the operator's configuration.
fail2ban_global_root() {
  printf '%s\n' /etc/fail2ban
}

fail2ban_allowipv6_path() {
  printf '%s/fail2ban.d/90-srv-settings.local\n' "$(fail2ban_global_root)"
}

# Respect an explicit IPv6 preference in any Fail2ban global config layer.
# Stock commented-out settings do not count.
fail2ban_allowipv6_defined() {
  local root="$1" file
  for file in "$root/fail2ban.conf" "$root/fail2ban.local" \
    "$root"/fail2ban.d/*.conf "$root"/fail2ban.d/*.local; do
    [[ -f "$file" ]] || continue
    if awk '
      /^[[:space:]]*[#;]/ { next }
      /^[[:space:]]*\[/ {
        section=$0
        sub(/^[[:space:]]*\[/, "", section)
        sub(/\].*$/, "", section)
        section=tolower(section)
        next
      }
      (section=="definition" || section=="default") &&
        tolower($0) ~ /^[[:space:]]*allowipv6[[:space:]]*=/ {
          found=1
          exit
        }
      END { exit !found }
    ' "$file"; then
      return 0
    fi
  done
  return 1
}

# Only create our own file. Never modify an existing global override.
fail2ban_create_allowipv6_default() {
  local target="$1" parent staged
  if [[ -e "$target" || -L "$target" ]]; then
    warn "Существующий $target оставлен без изменений."
    return 1
  fi
  parent="$(dirname "$target")"
  mkdir -p -- "$parent" || return 1
  staged="$(mktemp "$parent/.srv-settings-ipv6-XXXXXXXX")" || return 1
  if ! printf '[Definition]\nallowipv6 = auto\n' > "$staged" ||
     ! chmod 0644 "$staged" ||
     ! mv -n -- "$staged" "$target" ||
     [[ -e "$staged" ]]; then
    rm -f -- "$staged"
    fail "Не удалось безопасно создать $target"
    return 1
  fi
}

# fail2ban-client -t only checks syntax; the daemon may still be starting.
# Treat Fail2ban as ready only when its SSH jail answers over the socket.
fail2ban_wait_ready() {
  local max_attempts="${1:-12}" attempt
  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    if fail2ban-client status sshd >/dev/null 2>&1; then
      return 0
    fi
    if (( attempt < max_attempts )); then
      sleep 1
    fi
  done
  return 1
}

fail2ban_show_startup_diagnostics() {
  warn 'Fail2ban не готов или SSH jail не запустился. Диагностика:'
  systemctl status fail2ban --no-pager -l >&2 || true
  journalctl -u fail2ban -n 40 --no-pager >&2 || true
}

fail2ban_restore_setup_config() {
  local cfg="$1" original="$2" existed="$3"
  if (( existed )); then
    cp -a -- "$original" "$cfg"
  else
    rm -f -- "$cfg"
  fi
}

fail2ban_setup() {
  packages fail2ban python3-systemd ufw || return 1
  local cfg port_list temp existed=0
  local global_root global_path='' global_created=0
  cfg="$(fail2ban_setup_path)" || return 1
  port_list="$(ssh_ports | paste -sd, -)"
  [[ -n $port_list ]] || { fail 'Не удалось определить SSH-порт'; return 1; }
  backup "$cfg" || return 1

  temp="$(mktemp)" || return 1
  if [[ -f "$cfg" ]]; then
    existed=1
    cp -a -- "$cfg" "$temp" || { rm -f -- "$temp"; return 1; }
  fi
  if ! cat >"$cfg" <<EOF
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
  then
    fail2ban_restore_setup_config "$cfg" "$temp" "$existed" ||
      warn "Не удалось восстановить конфигурацию: $cfg"
    rm -f -- "$temp"
    return 1
  fi
  # Prevent the stock allowipv6 warning without changing an existing
  # fail2ban.local or operator-defined IPv6 setting.
  global_root="$(fail2ban_global_root)" || {
    fail2ban_restore_setup_config "$cfg" "$temp" "$existed" || true
    rm -f -- "$temp"
    return 1
  }
  if ! fail2ban_allowipv6_defined "$global_root"; then
    global_path="$(fail2ban_allowipv6_path)" || {
      fail2ban_restore_setup_config "$cfg" "$temp" "$existed" || true
      rm -f -- "$temp"
      return 1
    }
    if [[ -e "$global_path" || -L "$global_path" ]]; then
      warn "Глобальный $global_path уже существует без allowipv6; файл оставлен без изменений."
    elif fail2ban_create_allowipv6_default "$global_path"; then
      global_created=1
    else
      fail2ban_restore_setup_config "$cfg" "$temp" "$existed" || true
      rm -f -- "$temp"
      return 1
    fi
  fi

  if ! fail2ban-client -t; then
    if (( global_created )); then rm -f -- "$global_path" || warn "Не удалось удалить $global_path"; fi
    fail2ban_restore_setup_config "$cfg" "$temp" "$existed" ||
      warn "Не удалось восстановить конфигурацию: $cfg"
    rm -f -- "$temp"
    fail 'Ошибка конфигурации Fail2ban; изменения отменены'
    return 1
  fi

  # Enable once; restart once to apply the freshly written jail config.
  # Immediately running fail2ban-client here can race with daemon startup.
  if ! systemctl enable fail2ban ||
     ! systemctl restart fail2ban ||
     ! fail2ban_wait_ready 12; then
    fail2ban_show_startup_diagnostics
    if (( global_created )); then rm -f -- "$global_path" || warn "Не удалось удалить $global_path"; fi
    if fail2ban_restore_setup_config "$cfg" "$temp" "$existed"; then
      warn 'Предыдущая конфигурация Fail2ban восстановлена.'
      systemctl restart fail2ban >/dev/null 2>&1 ||
        warn 'Не удалось перезапустить Fail2ban с прежней конфигурацией.'
    else
      warn "Не удалось восстановить $cfg; требуется ручная проверка."
    fi
    rm -f -- "$temp"
    fail 'Fail2ban SSH jail недоступен после запуска; настройка не завершена.'
    return 1
  fi
  rm -f -- "$temp"
  fail2ban-client status sshd || return 1
  if confirm 'Добавить доверенные IP/CIDR для SSH сейчас?'; then
    fail2ban_ignore_update add || return 1
  fi
}

fail2ban_unban() {
  local ip
  ask 'IP-адрес для разблокировки' '' || return 1
  ip="$REPLY"
  [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] || { fail 'Недопустимый IP'; return 1; }
  fail2ban-client set sshd unbanip "$ip"
}

# Entries in the managed .local file are specific to the SSH jail.
# Fail2ban reads them after 90-srv-settings.local, so repeat setup keeps them.
fail2ban_ignore_path() {
  printf '%s\n' /etc/fail2ban/jail.d/95-srv-settings-ignore.local
}

fail2ban_ignore_show() {
  local cfg
  cfg="$(fail2ban_ignore_path)"
  info "Исключения SSH, управляемые srv-settings:"
  python3 "$BASE_DIR/lib/fail2ban_ignore.py" show "$cfg" || return 1
  if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
    info "Фактические исключения активного SSH jail:"
    fail2ban-client get sshd ignoreip || return 1
  else
    warn 'Активный SSH jail не найден; показаны только сохранённые исключения.'
  fi
}

fail2ban_ignore_update() {
  local action="$1" cfg raw staged old_copy=''
  local had_original=0
  if ! command -v fail2ban-client >/dev/null 2>&1 ||
     ! fail2ban-client status sshd >/dev/null 2>&1; then
    warn 'Сначала установите и настройте Fail2ban (пункт 1). SSH jail должен быть активен.'
    return 1
  fi
  cfg="$(fail2ban_ignore_path)"
  ask 'IP-адреса / CIDR-сети через запятую (IPv4, IPv6)' '' || return 1
  raw="$REPLY"
  staged="$(mktemp "$(dirname "$cfg")/.srv-settings-ignore.XXXXXXXX")" || return 1
  if ! python3 "$BASE_DIR/lib/fail2ban_ignore.py" "$action" "$cfg" "$raw" >"$staged"; then
    rm -f -- "$staged"
    return 1
  fi

  if { [[ -f "$cfg" ]] && cmp -s -- "$cfg" "$staged"; } ||
     { [[ ! -e "$cfg" ]] && [[ ! -s "$staged" ]]; }; then
    rm -f -- "$staged"
    info 'Изменений в списке нет.'
    return 0
  fi

  warn 'Новый ignoreip применяется только к sshd и может переопределить ignoreip для sshd из других .local файлов.'
  fail2ban-client get sshd ignoreip || warn 'Не удалось прочесть текущий список.'
  confirm 'Сохранить изменения в исключениях SSH?' || { rm -f -- "$staged"; return 0; }

  if [[ -f "$cfg" ]]; then
    had_original=1
    old_copy="$(mktemp "$(dirname "$cfg")/.srv-settings-previous.XXXXXXXX")" || { rm -f -- "$staged"; return 1; }
    if ! cp -a -- "$cfg" "$old_copy"; then
      rm -f -- "$old_copy" "$staged"
      return 1
    fi
    backup "$cfg" || { rm -f -- "$old_copy" "$staged"; return 1; }
  fi

  if [[ -s "$staged" ]]; then
    chmod 0644 "$staged" || { rm -f -- "$old_copy" "$staged"; return 1; }
    if ! mv -f -- "$staged" "$cfg"; then
      rm -f -- "$old_copy" "$staged"
      return 1
    fi
  else
    rm -f -- "$staged"
    rm -f -- "$cfg" || return 1
  fi

  if ! fail2ban-client -t || ! fail2ban-client reload sshd; then
    warn 'Ошибка проверки или перезагрузки Fail2ban — восстанавливаю предыдущую конфигурацию.'
    if (( had_original )); then
      mv -f -- "$old_copy" "$cfg" || { fail "Ручное восстановление из $old_copy"; return 1; }
    else
      rm -f -- "$cfg"
    fi
    fail2ban-client reload sshd || warn 'Не удалось восстановить активную конфигурацию SSH jail.'
    return 1
  fi
  [[ -z "$old_copy" ]] || rm -f -- "$old_copy"
  info 'Исключения сохранены и применены к SSH jail.'
  fail2ban-client get sshd ignoreip
}

fail2ban_menu() {
  local n
  while true; do
    printf '\nFAIL2BAN\n1. Установить и настроить SSH jail (3 попытки / 30 минут / бан 24 часа)\n2. Состояние Fail2ban\n3. Состояние SSH jail\n4. Разбанить IP\n5. Логи (последние 50 строк)\n6. Добавить IP/CIDR в исключения SSH (через запятую)\n7. Удалить IP/CIDR из исключений SSH\n8. Показать исключения SSH\n0. Назад\n'
    read_input 'Выбор: ' n || return 0
    case $n in
      1) fail2ban_setup;;
      2) fail2ban-client status;;
      3) fail2ban-client status sshd;;
      4) fail2ban_unban;;
      5) journalctl -u fail2ban -n 50 --no-pager;;
      6) fail2ban_ignore_update add;;
      7) fail2ban_ignore_update remove;;
      8) fail2ban_ignore_show;;
      0) return 0;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}
