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
  sudo_nopasswd_for_user "$username" || return 1
  warn "Проверьте вход в SSH под $username до отключения root!"
  ssh_allow_user_after_creation "$username" || return 1
}

# Per-user sudoers drop-in: never grant NOPASSWD to the entire %sudo group.
sudo_nopasswd_path() {
  printf '/etc/sudoers.d/90-srv-settings-%s\n' "$1"
}

sudo_nopasswd_stage() {
  mktemp /etc/sudoers.d/.srv-settings-sudo-XXXXXXXX
}

sudo_nopasswd_for_user() {
  local name="$1" path staging
  if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ || "$name" == root ]] ||
     ! id "$name" >/dev/null 2>&1; then
    fail 'Недопустимое имя пользователя для NOPASSWD или пользователь отсутствует'
    return 1
  fi
  warn "NOPASSWD разрешит $name выполнять любые команды от root через sudo БЕЗ пароля."
  warn 'Это эквивалентно правам root; не рекомендуется для общедоступных учётных записей.'
  confirm "Отключить запрос пароля sudo ТОЛЬКО для $name?" || return 0
  path="$(sudo_nopasswd_path "$name")" || return 1
  staging="$(sudo_nopasswd_stage)" || return 1

  if ! printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$name" > "$staging" ||
     ! chmod 0440 "$staging"; then
    rm -f -- "$staging"
    fail 'Не удалось подготовить файл sudoers'
    return 1
  fi
  if ! visudo -cf "$staging"; then
    rm -f -- "$staging"
    fail 'Ошибка sudoers; существующее правило не изменено'
    return 1
  fi
  if [[ -f "$path" ]] && cmp -s -- "$staging" "$path"; then
    rm -f -- "$staging"
    info "NOPASSWD для $name уже настроен; изменений нет."
    return 0
  fi
  backup "$path" || { rm -f -- "$staging"; return 1; }
  mv -f -- "$staging" "$path" || { rm -f -- "$staging"; return 1; }
  info "NOPASSWD для $name сохранён в $path; перезагрузка сервера не требуется."
  info "Проверка под $name: sudo -k; sudo -n id -u (ожидается 0 без запроса пароля)."
}

sudo_nopasswd() {
  ask 'Логин пользователя для NOPASSWD' admins || return 1
  sudo_nopasswd_for_user "$REPLY"
}

users_menu() {
  local n
  while true; do
    printf '\nПОЛЬЗОВАТЕЛИ\n1. Создать пользователя / обновить пароль, дать sudo\n2. NOPASSWD (опасная опция)\n0. Назад\n'
    read_input 'Выбор: ' n || return 0
    case $n in
      1) user_create;;
      2) sudo_nopasswd;;
      0) return 0;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}
