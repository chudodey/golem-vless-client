#!/usr/bin/env bash
# Включает запасной вход по паролю на сервере:
#   • локальная консоль (монитор + клавиатура);
#   • SSH с логином и паролем.
#
# Запускать ОТ ROOT НА СЕРВЕРЕ, передав файл формата LOGIN= / PASSWORD=:
#
#   bash enable-password-login.sh /path/to/server-access.txt
#
# LOGIN=root   — разблокирует root (консоль + SSH по паролю);
# LOGIN=<имя>  — создаёт пользователя с sudo и ставит ему пароль
#                (root остаётся входом только по ключу).
#
# Существующий доступ по ключу не трогается (PubkeyAuthentication остаётся
# включённым), поэтому даже неудачный прогон не отрежет текущую сессию.
set -euo pipefail

FILE="${1:-}"
if [ -z "$FILE" ]; then
  echo "укажите файл: bash enable-password-login.sh <server-access.txt>" >&2
  exit 1
fi
[ -f "$FILE" ] || { echo "нет файла: $FILE" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "запускайте от root" >&2; exit 1; }

# Файл может быть сохранён с Windows (CRLF) — чистые переводы строки.
clean="$(mktemp)"
trap 'rm -f "$clean"' EXIT
tr -d '\r' < "$FILE" > "$clean"
# shellcheck disable=SC1090
. "$clean"

LOGIN="${LOGIN:-}"
PASSWORD="${PASSWORD:-}"
[ -n "$LOGIN" ] || { echo "пустой LOGIN в $FILE" >&2; exit 1; }
[ -n "$PASSWORD" ] || { echo "пустой PASSWORD в $FILE" >&2; exit 1; }
case "$PASSWORD" in
  *your_password_here*|*"password"*|*"пароль"*|*"ПАРОЛЬ"*|*PASSWORD*)
    echo "PASSWORD похож на заглушку — заполните $FILE настоящим паролем" >&2; exit 1 ;;
esac
[ "${#PASSWORD}" -ge 8 ] || { echo "PASSWORD короче 8 символов — не продолжаю" >&2; exit 1; }

# ── 1. Логин и пароль ────────────────────────────────────────────────────────
if [ "$LOGIN" = "root" ]; then
  echo "root:$PASSWORD" | chpasswd
  echo ">> root: пароль задан (консоль + SSH по паролю)"
else
  if ! id "$LOGIN" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$LOGIN"
    echo ">> создан пользователь $LOGIN"
  fi
  echo "$LOGIN:$PASSWORD" | chpasswd
  usermod -aG sudo "$LOGIN"
  getent group wheel >/dev/null && usermod -aG wheel "$LOGIN"
  echo ">> $LOGIN: пароль задан, добавлен в sudo"
fi

# ── 2. SSH: вход по паролю ТОЛЬКО из локальной сети ─────────────────────────
# Глобально парольный вход остаётся выключенным (PasswordAuthentication no из
# 99-dell-server.conf). Match Address дописывается в САМЫЙ КОНЕЦ главного
# sshd_config: включать его в .d-файл нельзя — .d читается до хвоста
# sshd_config, и Match «захватил» бы идущие следом настройки (UsePAM,
# Subsystem sftp). Match в конце файла ограничивает только себя.
# Консоль (монитор+клавиатура) sshd не касается — пароль работает всегда.
LAN="${GOLEM_SSH_LAN:-192.168.88.0/24}"
if grep -q '^# B-016' /etc/ssh/sshd_config; then
  echo ">> sshd_config уже содержит блок B-016 — пропускаю добавление"
else
  cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak-b016
  cat >> /etc/ssh/sshd_config <<EOF

# B-016: парольный вход только из локальной сети (или с консоли — консоль
# sshd не касается). Ключевой вход работает отовсюду.
Match Address ${LAN},127.0.0.1,::1
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
    PermitRootLogin yes
    PermitEmptyPasswords no
EOF
  echo ">> SSH: парольный вход включён только из ${LAN}"
fi

if ! sshd -t; then
  echo "sshd -t не прошёл — откатываю изменения SSH" >&2
  rm -f "$SSHD_D"
  exit 1
fi
systemctl reload ssh 2>/dev/null || systemctl reload sshd

echo
echo "Готово. Что проверить:"
echo "  1) консоль: вход под «$LOGIN» с монитора/клавиатуры (всегда доступен);"
if [ "$LOGIN" = "root" ]; then
  echo "  2) SSH по паролю: ssh root@192.168.88.13 — работает ТОЛЬКО из"
  echo "     локальной сети (${LAN:-192.168.88.0/24});"
else
  echo "  2) SSH по паролю: ssh $LOGIN@192.168.88.13 (sudo — по нему же) —"
  echo "     работает ТОЛЬКО из локальной сети (${LAN:-192.168.88.0/24});"
fi
echo "  Ключевой доступ (dell_sysrescue_ed25519) работает отовсюду."
