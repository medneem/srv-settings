#!/usr/bin/env bash
set -Eeuo pipefail
if (( EUID != 0 )); then
  echo "Запустите через sudo bash" >&2
  exit 1
fi
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "Поддерживается только Ubuntu" >&2
  exit 1
fi
for cmd in curl tar mktemp python3; do command -v "$cmd" >/dev/null || { echo "Не найдена команда: $cmd" >&2; exit 1; }; done
if ! (: </dev/tty) 2>/dev/null; then
  echo "Нужен интерактивный терминал (/dev/tty). Подключитесь по SSH и повторите." >&2
  exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
echo "Загрузка srv-settings..."
# Resolve a moving branch once, then download an immutable commit snapshot.
# A random cache-buster avoids stale branch metadata from intermediary caches.
cache_bust="$(date +%s%N)-$$"
if ! curl -fLSs --retry 3 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    -o "$tmp/revision.json" \
    "https://api.github.com/repos/medneem/srv-settings/commits/main?cache_bust=$cache_bust"; then
  echo "Не удалось получить актуальный SHA ветки main из GitHub API." >&2
  exit 1
fi
if ! commit_sha="$(python3 - "$tmp/revision.json" <<'PY'
import json
import re
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    sha = json.load(stream)["sha"]
if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
    raise SystemExit("Invalid GitHub commit SHA")
print(sha)
PY
)"; then
  echo "Некорректный ответ GitHub API; установка прервана без обновления файлов." >&2
  exit 1
fi
if ! curl -fLSs --retry 3 \
    -o "$tmp/source.tar.gz" \
    "https://codeload.github.com/medneem/srv-settings/tar.gz/$commit_sha"; then
  echo "Не удалось скачать архив srv-settings для версии $commit_sha" >&2
  exit 1
fi
mkdir -p "$tmp/unpacked"
tar -xzf "$tmp/source.tar.gz" -C "$tmp/unpacked" --strip-components=1
test -f "$tmp/unpacked/setup.sh" || { echo "В репозитории отсутствует setup.sh" >&2; exit 1; }
install -d -m 0755 /opt/srv-settings
cp -a "$tmp/unpacked/." /opt/srv-settings/
printf '%s\n' "$commit_sha" > /opt/srv-settings/.installed-commit
echo "Установлено в /opt/srv-settings (версия $commit_sha)"
rm -rf -- "$tmp"
trap - EXIT
# При curl | sudo bash stdin содержит код bootstrap. Меню читает с терминала.
exec bash /opt/srv-settings/setup.sh </dev/tty
