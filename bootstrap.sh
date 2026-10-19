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
for cmd in curl tar mktemp; do command -v "$cmd" >/dev/null || { echo "Не найдена команда: $cmd" >&2; exit 1; }; done
if ! (: </dev/tty) 2>/dev/null; then
  echo "Нужен интерактивный терминал (/dev/tty). Подключитесь по SSH и повторите." >&2
  exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
echo "Загрузка srv-settings..."
curl -fLSs --retry 3 -o "$tmp/source.tar.gz" "https://github.com/medneem/srv-settings/archive/refs/heads/main.tar.gz"
tar -xzf "$tmp/source.tar.gz" -C "$tmp"
test -f "$tmp/srv-settings-main/setup.sh" || { echo "В репозитории отсутствует setup.sh" >&2; exit 1; }
install -d -m 0755 /opt/srv-settings
cp -a "$tmp/srv-settings-main/." /opt/srv-settings/
echo "Установлено в /opt/srv-settings"
rm -rf -- "$tmp"
trap - EXIT
# При curl | sudo bash stdin содержит код bootstrap. Меню читает с терминала.
exec bash /opt/srv-settings/setup.sh </dev/tty
