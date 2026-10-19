#!/usr/bin/env python3
"""Manage srv-settings SSH ignoreip entries safely.

No file system changes: this tool reads the old managed file and prints a
candidate configuration. The calling Bash module validates and installs it.
"""
from __future__ import annotations

import configparser
import ipaddress
import pathlib
import re
import sys

HEADER = "# Managed by srv-settings; use Fail2ban menu to edit.\n"
BASELINE = ("127.0.0.1/8", "::1")
SECTION = "sshd"


def normalize_ip(value: str) -> str:
    value = value.strip()
    if not value:
        raise ValueError("Пустой IP-адрес")
    try:
        if "/" in value:
            network = ipaddress.ip_network(value, strict=False)
            if network.prefixlen == 0:
                raise ValueError("Подсеть /0 отключила бы защиту для всех адресов")
            return str(network)
        return str(ipaddress.ip_address(value))
    except ValueError as exc:
        if "Подсеть /0" in str(exc):
            raise
        raise ValueError(f"Некорректный IP/CIDR: {value!r}") from exc


def parse_csv(raw: str) -> list[str]:
    if not raw.strip():
        raise ValueError("Список адресов пуст")
    items = raw.split(",")
    if any(not item.strip() for item in items):
        raise ValueError("Пустое значение в списке через запятую")
    return list(dict.fromkeys(normalize_ip(item) for item in items))


def load_managed(path: pathlib.Path) -> list[str]:
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8")
    if not text.startswith(HEADER):
        raise ValueError(f"Файл {path} создан не srv-settings; отказ от перезаписи")
    cfg = configparser.RawConfigParser(strict=True, inline_comment_prefixes=("#",))
    cfg.read_string(text)
    if cfg.sections() != [SECTION] or set(cfg.options(SECTION)) != {"ignoreip"}:
        raise ValueError("Формат управляемого файла неожиданно изменён")
    words = cfg.get(SECTION, "ignoreip").split()
    ips = [normalize_ip(x) for x in words]
    if not set(BASELINE).issubset(set(ips)):
        raise ValueError("Отсутствуют обязательные локальные исключения")
    return [x for x in dict.fromkeys(ips) if x not in BASELINE]


def apply_edit(current: list[str], operation: str, raw: str) -> list[str]:
    to_change = parse_csv(raw)
    if operation == "add":
        return list(dict.fromkeys([*current, *[x for x in to_change if x not in BASELINE]]))
    if operation == "remove":
        selected = set(to_change)
        return [x for x in current if x not in selected]
    raise ValueError(f"Неизвестная операция {operation!r}")


def render(ips: list[str]) -> str:
    if not ips:
        return ""  # Delete our .local override, restoring any external settings.
    return HEADER + f"[{SECTION}]\nignoreip = {' '.join([*BASELINE, *ips])}\n"


def main(args: list[str]) -> int:
    if len(args) < 2:
        raise ValueError("Использование: fail2ban_ignore.py show|add|remove FILE [CSV]")
    operation, path_text, *extra = args
    path = pathlib.Path(path_text)
    current = load_managed(path)
    if operation == "show":
        if extra:
            raise ValueError("show не принимает адреса")
        print(", ".join(current) if current else "(пользовательские исключения не заданы)")
    elif operation in ("add", "remove"):
        if len(extra) != 1:
            raise ValueError("Требуется список IP/CIDR через запятую")
        print(render(apply_edit(current, operation, extra[0])), end="")
    else:
        raise ValueError("Неизвестная операция")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (ValueError, OSError, configparser.Error) as error:
        print(f"Fail2ban ignoreip: {error}", file=sys.stderr)
        raise SystemExit(1) from error
