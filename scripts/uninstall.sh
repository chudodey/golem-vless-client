#!/usr/bin/env bash
# Полное удаление golem-vless-client. Запускать от root.
#
#   sudo bash scripts/uninstall.sh            — оставить policy.conf/endpoints.txt
#   sudo bash scripts/uninstall.sh --purge     — удалить вообще всё, включая ключ
set -euo pipefail

PREFIX="${PREFIX:-/opt/golem-vless}"
STATE="${STATE:-/var/lib/golem-vless}"
ETC="${ETC:-/etc/golem-vless}"
UNIT="/etc/systemd/system/golem-vless-client.service"

[[ "$(id -u)" -eq 0 ]] || { echo "запустите от root (sudo bash scripts/uninstall.sh)" >&2; exit 1; }

echo ">> останавливаю сервисы…"
systemctl disable --now golem-vless-client 2>/dev/null || true
systemctl disable --now golem-vless-stats.timer 2>/dev/null || true

echo ">> удаляю юниты и бинарники…"
rm -f "$UNIT" \
      /etc/systemd/system/golem-vless-stats.service \
      /etc/systemd/system/golem-vless-stats.timer \
      /usr/local/bin/vpnctl /usr/local/bin/sing-box
systemctl daemon-reload

echo ">> удаляю $PREFIX и $STATE…"
rm -rf "$PREFIX" "$STATE"

if [[ "${1:-}" == "--purge" ]]; then
  echo ">> --purge: удаляю $ETC (ваш ключ и policy.conf)…"
  rm -rf "$ETC"
else
  echo ">> $ETC оставлен нетронутым (там ваш ключ и policy.conf)."
  echo "   Удалить и его: sudo bash scripts/uninstall.sh --purge"
fi

echo "Готово."
