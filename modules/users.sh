#!/usr/bin/env bash

user_create() {
  local username
  ask 'Логин нового пользователя' admins || return 1
  username="$REPLY"
  if [[ ! $username =~ ^[a-z_][a-z0-9_-]*$ || ${#username} -gt 32 || $username == root ]]; then
    fail 'Некорректное имя пользователя'; return 1
  fi
  if id "$username" >/dev/null 2>&1; then
    info "Пользователь $username уже существует"
  else
    adduser --disabled-password --gecos '' "$username" || return 1
  fi
  usermod -aG sudo "$username" || return 1
  info "Сейчас задайте пароль пользователю $username; ввод не отображается и не логируется"
  passwd "$username" || return 1
  warn "Проверьте вход в SSH под $username до отключения root!"
}

sudo_nopasswd() {
  local name path
  ask 'Логин пользователя для NOPASSWD' admins || return 1
  name="$REPLY"
  [[ $name =~ ^[a-z_][a-z0-9_-]*$ ]] && id "$name" >/dev/null 2>&1 || { fail 'Нет такого пользователя'; return 1; }
  warn 'NOPASSWD: ALL разрешает выполнение любых команд от root без пароля'
  confirm "Разрешить NOPASSWD только для $name?" || return 0
  path="/etc/sudoers.d/90-srv-settings-$name"
  backup "$path" || return 1
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$name" > "$path"
  chmod 0440 "$path"
  if ! visudo -cf "$path"; then
    rm -f "$path"
    fail 'Ошибка sudoers; новое правило удалено'
    return 1
  fi
  info 'Проверка sudoers пройдена'
}

users_menu() {
  local n
  while true; do
    printf '\nПОЛЬЗОВАТЕЛИ\n1. Создать пользователя / обновить пароль, дать sudo\n2. NOPASSWD (опасная опция)\n0. Назад\n'
    read -r -p 'Выбор: ' n || return 0
    case $n in
      1) user_create;;
      2) sudo_nopasswd;;
      0) return 0;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}
