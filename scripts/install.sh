#!/usr/bin/env bash
# Установка sing-box + golem-vless-client на любом systemd-дистрибутиве Linux
# (Debian/Ubuntu, Fedora/RHEL/Alma/Rocky, Arch/Manjaro — определяется
# автоматически по наличию apt-get/dnf/yum/pacman).
#
# Запускать от root, находясь внутри каталога vpn-client (или указать его
# явным путём как первый аргумент):
#
#   sudo bash scripts/install.sh
#
# Переопределяемые переменные окружения:
#   PREFIX            куда ставить (по умолчанию /opt/golem-vless)
#   STATE             durable-каталог кэша sing-box (по умолчанию /var/lib/golem-vless)
#   ETC               каталог конфигурации (по умолчанию /etc/golem-vless)
#   SINGBOX_VERSION   версия sing-box (по умолчанию 1.13.16; 1.11/1.12 дают
#                     "legacy DNS servers is deprecated" — см. README)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-/opt/golem-vless}"
STATE="${STATE:-/var/lib/golem-vless}"
ETC="${ETC:-/etc/golem-vless}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.16}"
UNIT_SRC="$ROOT/systemd/golem-vless-client.service"
UNIT_DST="/etc/systemd/system/golem-vless-client.service"
STATS_UNIT_SRC="$ROOT/systemd/golem-vless-stats.service"
STATS_TIMER_SRC="$ROOT/systemd/golem-vless-stats.timer"
STATS_UNIT_DST="/etc/systemd/system/golem-vless-stats.service"
STATS_TIMER_DST="/etc/systemd/system/golem-vless-stats.timer"

log()  { echo ">> $*"; }
die()  { echo "ОШИБКА: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "запустите от root (sudo bash scripts/install.sh)"
[[ -f "$UNIT_SRC" ]] || die "не найден $UNIT_SRC — запускайте из каталога vpn-client"
command -v systemctl >/dev/null 2>&1 || die "нужен systemd (systemctl не найден)"

# --- 1. Пакеты, нужные для сборки/запуска (curl, tar, python3) -------------
log "определяю дистрибутив и ставлю зависимости…"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl tar python3
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y ca-certificates curl tar python3
elif command -v yum >/dev/null 2>&1; then
  yum install -y ca-certificates curl tar python3
elif command -v pacman >/dev/null 2>&1; then
  pacman -Sy --noconfirm ca-certificates curl tar python
else
  die "не нашёл apt-get/dnf/yum/pacman — поставьте вручную: curl, tar, python3, ca-certificates"
fi

# --- 2. sing-box: статический бинарник, один для всех дистрибутивов --------
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)  sb_arch=amd64 ;;
  aarch64|arm64) sb_arch=arm64 ;;
  *) die "неподдерживаемая архитектура: $arch (sing-box собирают только под amd64/arm64)" ;;
esac

if command -v sing-box >/dev/null 2>&1 \
   && [[ "$(sing-box version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" == "$SINGBOX_VERSION" ]]; then
  log "sing-box $SINGBOX_VERSION уже установлен, пропускаю скачивание"
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${sb_arch}.tar.gz"
  log "скачиваю $url"
  curl -fsSL "$url" -o "$tmp/sing-box.tgz" \
    || die "не удалось скачать sing-box — проверьте интернет или соберите вручную: https://sing-box.sagernet.org"
  tar -xzf "$tmp/sing-box.tgz" -C "$tmp"
  install -m 0755 "$tmp/sing-box-${SINGBOX_VERSION}-linux-${sb_arch}/sing-box" /usr/local/bin/sing-box
fi
sing-box version

# --- 3. Файлы проекта -------------------------------------------------------
log "раскладываю файлы в $PREFIX и $ETC…"
mkdir -p "$PREFIX/generated" "$PREFIX/scripts" "$PREFIX/systemd" "$STATE" "$ETC"

cp -a "$ROOT/README.md" "$PREFIX/" 2>/dev/null || true
cp -a "$ROOT/scripts/." "$PREFIX/scripts/"
cp -a "$ROOT/systemd/." "$PREFIX/systemd/"
chmod +x "$PREFIX/scripts/render_config.py" "$PREFIX/scripts/stats.py" "$PREFIX/scripts/vpnctl"

# policy.conf и endpoints.txt — пользовательские данные; ставим шаблон
# только если файла ещё нет, чтобы повторный запуск install.sh не затирал
# уже сделанные настройки.
if [[ ! -f "$ETC/policy.conf" ]]; then
  cp -a "$ROOT/policy.conf" "$ETC/policy.conf"
  log "создан $ETC/policy.conf — отредактируйте под себя, затем: vpnctl reload"
fi
if [[ ! -f "$ETC/endpoints.txt" ]]; then
  if [[ -f "$ROOT/secrets/endpoints.txt" ]]; then
    # Обычный сценарий для этого репозитория: ключ уже вставлен в локальную
    # копию (secrets/endpoints.txt, в .gitignore) перед копированием на сервер.
    install -m 0600 "$ROOT/secrets/endpoints.txt" "$ETC/endpoints.txt"
    log "перенёс уже заполненный secrets/endpoints.txt в $ETC/endpoints.txt"
  else
    install -m 0600 "$ROOT/secrets/endpoints.example.txt" "$ETC/endpoints.txt"
    log "создан $ETC/endpoints.txt из шаблона — вставьте туда ваш VLESS-ключ"
  fi
fi

ln -sf "$PREFIX/scripts/vpnctl" /usr/local/bin/vpnctl

# systemd/golem-vless-client.service ships with the default paths
# (/opt/golem-vless, /etc/golem-vless, /var/lib/golem-vless) written out
# literally, since systemd units can't reference environment variables. When
# PREFIX/ETC/STATE are overridden, substitute them into the installed copy so
# a non-default install actually works instead of silently pointing at the
# defaults.
sed -e "s#/opt/golem-vless#${PREFIX}#g" \
    -e "s#/etc/golem-vless#${ETC}#g" \
    -e "s#/var/lib/golem-vless#${STATE}#g" \
    "$UNIT_SRC" > "$UNIT_DST"
chmod 0644 "$UNIT_DST"
systemctl daemon-reload

# --- 5. Телеметрия (B-015): stats-таймер каждые 30 минут -------------------
log "ставлю телеметрию (stats-таймер, каждые 30 мин)…"
sed -e "s#/opt/golem-vless#${PREFIX}#g" \
    -e "s#/etc/golem-vless#${ETC}#g" \
    -e "s#/var/lib/golem-vless#${STATE}#g" \
    "$STATS_UNIT_SRC" > "$STATS_UNIT_DST"
cp -a "$STATS_TIMER_SRC" "$STATS_TIMER_DST"
chmod 0644 "$STATS_UNIT_DST" "$STATS_TIMER_DST"
systemctl daemon-reload
systemctl enable --now golem-vless-stats.timer >/dev/null 2>&1 \
  || systemctl enable golem-vless-stats.timer >/dev/null 2>&1
systemctl start golem-vless-stats.timer 2>/dev/null || true
log "stats-таймер установлен: systemctl status golem-vless-stats.timer"

cat <<EOF

Установлено. Дальше:

  1) вставить ключ:     \${EDITOR:-nano} $ETC/endpoints.txt
  2) настроить правила: vpnctl policy         (что через VPN, что напрямую)
  3) проверить ключ:    python3 $PREFIX/scripts/render_config.py --endpoints $ETC/endpoints.txt --check-only
  4) запустить:         vpnctl on
  5) проверить:         vpnctl status
     (второй SSH-сессией, если ставите на удалённый сервер — первое включение
     TUN может на секунду оборвать текущее соединение)
  6) телеметрия:        vpnctl stats   (сбор + сводка; авто-сбор каждые 30 мин)

Подробности и разбор частых проблем — в README.md.
EOF
