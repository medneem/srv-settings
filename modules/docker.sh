#!/usr/bin/env bash

docker_mirrors() {
  if ! command -v docker >/dev/null 2>&1; then
    warn 'Docker не установлен; модуль не устанавливает Docker автоматически.'
    return 1
  fi
  packages python3 || return 1
  local cfg=/etc/docker/daemon.json
  warn 'Изменение registry-mirrors может повлиять на docker pull. Перезапуск Docker может прервать контейнеры.'
  confirm 'Добавить предложенные зеркала к существующему daemon.json?' || return 0
  mkdir -p /etc/docker
  backup "$cfg" || return 1
  python3 - "$cfg" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
else:
    cfg = {}
if not isinstance(cfg, dict):
    raise SystemExit("Expected JSON object")
mirrors = [
    "https://dh-mirror.gitverse.ru",
    "https://dockerhub.timeweb.cloud",
    "https://dockerhub1.beget.com",
    "https://mirror.gcr.io"
]
cfg["registry-mirrors"] = list(dict.fromkeys(cfg.get("registry-mirrors", []) + mirrors))
fd, tmp = tempfile.mkstemp(prefix=".daemon.", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
  if command -v dockerd >/dev/null 2>&1; then
    dockerd --validate --config-file "$cfg" || { fail 'Ошибка проверки daemon.json; восстановите резервную копию'; return 1; }
  fi
  if confirm 'Перезапустить Docker СЕЙЧАС? (может прервать контейнеры)'; then
    systemctl restart docker || return 1
  else
    warn 'Изменения вступят в силу после перезапуска Docker.'
  fi
}

docker_menu() {
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
