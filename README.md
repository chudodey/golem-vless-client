# VLESS-клиент с избирательной маршрутизацией (sing-box)

[sing-box](https://sing-box.sagernet.org/) клиент с **разделением трафика**:
часть приложений и сайтов идёт через VPN, остальное — напрямую, по правилам,
которые задаются в **одном** файле `policy.conf`. Одна и та же подписка и
политика работают и на **Linux** (headless-сервер, systemd), и на **Windows**
(ноутбук, TUN + Task Scheduler). Провайдер — любой с протоколом VLESS
(Durev, Marzban, 3x-ui, свой сервер) — в секрете только ключ или ссылка
подписки, никаких привязок к конкретному провайдеру в коде нет.

## Возможности

- **Избирательность по программам** — например, только `claude` и
  `antigravity` идут через VPN, всё остальное — напрямую.
- **Избирательность по сайтам** — список «через VPN» и список «всегда
  напрямую» (банки, госуслуги — туда лучше не пускать чужой IP).
- **Автовыбор самого быстрого сервера** — встроенный `urltest` раз в
  несколько минут сам перепроверяет задержку до пачки серверов и
  переключается на быстрейший, без разрыва текущих соединений.
- **Проверка живости нод** — при сборке каждая нода реально проверяется
  запросами к `api.anthropic.com` (ждать 401) и `www.youtube.com` (ждать 200);
  в гонку `urltest` попадают только прошедшие проверку (B-010).
- **xhttp-ноды через Xray-core** — подписки, где почти все ноды на
  транспорте xhttp (которого sing-box не понимает), держатся через
  отдельный `xray-core`: та же связка sing-box(TUN)→xray, что у
  официального приложения Durev (B-007/B-011).
- **Telegram по IP, а не по доменам** — MTProto/CDN-подключения к голым
  `91.108.x`/`149.154.x` тоже идут через VPN (правила по CIDR + geosite),
  особенно важно для TUN-режима на Windows (B-013).
- **Телеметрия провайдера 24/7** (B-015) — каждые 30 минут записывается
  живость, пинг и HTTP-доступность каждой ноды; сводка по провайдерам,
  странам и времени жизни нод накапливается месяцами.
- **Автовосстановление** — на Linux systemd перезапускает клиент при падении;
  на Windows дежурный watchdog каждые 5 минут пересобирает конфиг и
  перезапускает, если канал умер.

## Требования

- **Linux**: любой дистрибутив с systemd (проверено на Debian; ставится и на
  Ubuntu/Fedora/RHEL/Arch), права root, архитектура amd64 или arm64.
- **Windows**: Windows 10/11, PowerShell 5.1+, Python 3 в `PATH`
  (используется рендерером конфига), права администратора
  (установщик и `GolemVpn.ps1` сами поднимают права).
- В любом случае: ключ VLESS (`vless://…`), ссылка подписки
  (`https://…`) или body-ответа подписки из браузера (base64-блок).

## Установка

### Linux

```bash
git clone https://github.com/chudodey/golem-vless-client.git vpn-client
cd vpn-client
sudo bash scripts/install.sh
```

Скрипт сам определяет дистрибутив (`apt`/`dnf`/`yum`/`pacman`), ставит
зависимости, скачивает статический бинарник sing-box (одна и та же сборка для
любого дистрибутива — распаковка из архива, не системный пакет) и раскладывает
файлы:

| Что | Куда (по умолчанию) |
|---|---|
| Программа и скрипты | `/opt/golem-vless/` |
| Ваши настройки (`policy.conf`, `endpoints.txt`) | `/etc/golem-vless/` |
| Кэш sing-box и телеметрия | `/var/lib/golem-vless/` |
| Команда управления | `/usr/local/bin/vpnctl` |

Пути переопределяются переменными `PREFIX`/`ETC`/`STATE` перед запуском
`install.sh`, если нужно поставить в нестандартное место. Повторный запуск
`install.sh` безопасен — не затирает уже заполненные `policy.conf` и
`endpoints.txt`. Также ставит systemd-таймер телеметрии `golem-vless-stats.timer`.

### Windows

Из корня проекта, в PowerShell **от имени администратора**:

```powershell
.\windows\Install-GolemVless.ps1 -Start
```

Установщик качает `sing-box.exe` и `xray.exe`, копирует скрипты и
`policy.conf` в `%LOCALAPPDATA%\GolemVLESS`, создаёт VPN-задачу и watchdog и
раскладывает файлы так:

| Что | Куда |
|---|---|
| Скрипты, `sing-box.exe`, `xray.exe` | `%LOCALAPPDATA%\GolemVLESS\bin\` |
| Ваши настройки (`policy.conf`, `endpoints.txt`) | `%LOCALAPPDATA%\GolemVLESS\config\` |
| Конфиг, кэш, логи, телеметрия | `%LOCALAPPDATA%\GolemVLESS\state\` |
| Автозапуск | задачи `GolemVLESS`, `GolemVLESS-Watchdog`, `GolemVLESS-Refresh` |

Секреты остаются вне репозитория — в `config\endpoints.txt`. Перед установкой
(или на первом старте) закройте другой активный TUN-клиент, например Durev
VPN: одновременно работать может только один TUN-клиент.

## Настройка — один файл `policy.conf`

Синтаксис и оба списка правил одинаковы на обеих системах: что через VPN,
что напрямую, и параметры автовыбора (`[auto-select]`). Внутри файла всё
объяснено в комментариях. Лежит он в разных местах:

| | Linux | Windows |
|---|---|---|
| `policy.conf` | `/etc/golem-vless/policy.conf` | `%LOCALAPPDATA%\GolemVLESS\config\policy.conf` |
| `endpoints.txt` | `/etc/golem-vless/endpoints.txt` | `%LOCALAPPDATA%\GolemVLESS\config\endpoints.txt` |

### Формат `endpoints.txt` (общий)

```text
@provider myprovider
vless://uuid@host:443?security=reality&…#Имя-ноды
ACTIVE=1
```

или ссылка подписки (список нод одной строкой):

```text
@provider myprovider
https://example.com/sub/TOKEN
ACTIVE=1
```

Можно несколько `@provider`-блоков подряд; `ACTIVE=N` выбирает N-й
распознанный узел как ручной вариант (актуально только если автовыбор
выключен). Если сеть блокирует скачивание подписки (DPI) — вставьте
base64-тело ответа подписки из браузера вместо ссылки (см. «Частые проблемы»).

Проверка, что ключ распознался (без запуска сервиса):

```bash
# Linux
python3 /opt/golem-vless/scripts/render_config.py \
  --endpoints /etc/golem-vless/endpoints.txt --check-only
```

```powershell
# Windows
python ".\scripts\render_config.py" --endpoints "$env:LOCALAPPDATA\GolemVLESS\config\endpoints.txt" --check-only
```

### Первый запуск: Linux

1. **Ключ**: `sudo nano /etc/golem-vless/endpoints.txt` (см. форматы выше).
2. **Правила**: `vpnctl policy` → правки → `vpnctl reload`.
3. **Запуск**: `sudo vpnctl on`, затем `sudo vpnctl status`.

⚠️ Если ставите на **удалённый** сервер по SSH: первое включение поднимает
TUN-интерфейс и может на секунду оборвать текущую SSH-сессию (переезд
маршрутов). Проверяйте **новой** сессией — старая может отвалиться, сервер
обычно жив.

### Первый запуск: Windows

1. **Ключ**: если не вставили до установки — `notepad "$env:LOCALAPPDATA\GolemVLESS\config\endpoints.txt"`.
2. **Правила**: `notepad "$env:LOCALAPPDATA\GolemVLESS\config\policy.conf"` → правки → `GolemVpn.ps1 restart`.
3. **Запуск**: `GolemVpn.ps1 start`.

Проверка на любой системе: приложение из списка видит IP VPN-сервера,
обычный `curl.exe https://ifconfig.io/ip` — домашний IP.

## Управление

### Linux — команда `vpnctl`

| Команда | Что делает |
|---|---|
| `vpnctl on` / `off` / `restart` | включить / выключить / перезапустить |
| `vpnctl status` | состояние, текущий сервер, проверка обоих маршрутов |
| `vpnctl nodes` | список серверов с задержкой (мс), быстрейший — сверху |
| `vpnctl fastest` | сейчас же перепроверить и переключиться на быстрейший |
| `vpnctl check <имя>` | убедиться, что программа `<имя>` реально идёт через VPN |
| `vpnctl reload` | пересобрать конфиг (включая обновление URL-подписок) и перезапустить |
| `vpnctl policy` | открыть `policy.conf` в `$EDITOR` (по умолчанию `nano`) |
| `vpnctl logs [N]` | последние N строк журнала (по умолчанию 50) |
| `vpnctl stats` / `report` | собрать телеметрию нод и показать сводку / просто сводку (B-015) |

`on`, `off`, `restart` и `reload` требуют root (`sudo`). `status`, `nodes`,
`fastest`, `check` и `logs` можно запускать без root; `policy` требует прав
на запись в файл конфигурации (обычно `sudo vpnctl policy`).

### Windows — скрипт `GolemVpn.ps1`

Устанавливается в `%LOCALAPPDATA%\GolemVLESS\bin\GolemVpn.ps1` и умеет сам
поднимать права. Параметр `-Wait` держит окно открытым до Enter
(используется ярлыками на рабочем столе).

| Команда | Что делает |
|---|---|
| `GolemVpn.ps1 status` (по умолчанию) | состояние задач, процессы sing-box/xray, число ключей, активный сервер, системный прокси, внешний IP |
| `GolemVpn.ps1 start` / `stop` / `restart` | включить / выключить / перезапустить |
| `GolemVpn.ps1 logs` | последние строки лога sing-box |
| `GolemVpn.ps1 diagnose` | собрать отчёт `state\diagnostic.txt` |
| `GolemVpn.ps1 refresh` | вручную обновить подписку и перезапустить клиент при изменении |
| `GolemVpn.ps1 stats` / `report` | собрать телеметрию и показать сводку / просто сводку (B-015) |
| `GolemVpn.ps1 uninstall` | полное удаление (задачи, процессы, `%LOCALAPPDATA%\GolemVLESS`, ярлыки) |

### Обновление подписки

- **Linux**: `vpnctl reload` тянет свежие ноды при каждой пересборке конфига
  (`--fetch`); при недоступности подписки рендерер использует последний
  кэш в `state/last-subscription.txt`.
- **Windows**: ежедневно в 04:00 задача `GolemVLESS-Refresh` скачивает свежий
  список в `state\last-subscription.txt` и, если sha256 пула изменился,
  перезапускает клиент (лог — `state\subscription-refresh.log`). Тот же кэш —
  офлайн-фолбэк рендерера. Ручной запуск — `GolemVpn.ps1 refresh`.

Чтобы временно остановить Windows-клиент и вернуться к Durev:

```powershell
Stop-ScheduledTask GolemVLESS
Stop-ScheduledTask GolemVLESS-Watchdog
```

### Как проверить, что всё реально работает

Одного «сервис запущен» недостаточно — split-маршрутизация может быть сломана
незаметно (см. «Частые проблемы»). Правильная проверка — **оба** маршрута
сразу; на Linux это делает `vpnctl status`:

| Проверка | Ожидаемый результат |
|---|---|
| Сайт из `[domains-direct]` (например банк) | открывается с вашего обычного IP |
| Сайт из `[domains-via-vpn]` | открывается с IP/страной VPN-сервера |
| `vpnctl check <имя-программы-из-policy.conf>` | `✓ уходит через VPN` |

### Автовыбор сервера

Встроенный `urltest` sing-box, не самописный скрипт: раз в `interval` из
`policy.conf` замеряет задержку до `candidates` серверов-кандидатов из вашей
подписки и переключается на самый быстрый. Переключение не рвёт уже открытые
соединения; упавший сервер выбывает из гонки автоматически. Параметр
`tolerance` (мс) не даёт «дёргаться» между серверами с почти одинаковой
скоростью — поэтому в списке серверов текущий сервер иногда не самый верхний,
это нормально, а не баг.

Перед сборкой конфига клиент дополнительно **проверяет живые ноды** (`--probe`
по умолчанию): параллельным TCP-пингом до каждой ноды (`host:port`) отсеивает
мёртвые и упорядочивает пул `urltest` по измеренной задержке. Поэтому в гонке
участвуют только живые быстрые ноды, а медленный/«Автовыбор»-узел, отвечающий
только через секунду, не выигрывает. Выключить сканирование — `--no-probe`
(или `PROBE=0` в env для `vpnctl reload`) и `--probe-timeout`.

Выключить автовыбор и закрепить один сервер вручную: `enabled = no` в
`[auto-select]`, затем `ACTIVE=N` в `endpoints.txt` выбирает нужный по номеру
из `render_config.py --check-only`.

## Телеметрия качества провайдера (B-015)

На Linux `install.sh` ставит systemd-таймер `golem-vless-stats.timer`, который
каждые 30 минут собирает данные (`golem-vless-stats.service`, oneshot):
TCP-пинг и HTTP-проверку каждой ноды, фиксирует появления/исчезновения нод и
текущий выбор клиента. Журнал append-only событий лежит в
`$STATE/stats/events-YYYY-MM.jsonl` (со снимком нод `nodes.json`).
`render_config.py` записывает телеметрию и при каждой обычной сборке конфига.

| Система | Собрать + сводка | Только сводка |
|---|---|---|
| Linux | `vpnctl stats` | `vpnctl report` |
| Windows | `GolemVpn.ps1 stats` | `GolemVpn.ps1 report` |

Ещё вариант на Linux:

```bash
python3 scripts/stats.py report --state-dir /var/lib/golem-vless --months 1
```

Сводка показывает таблицы: провайдеры (общая доступность, средний пинг,
рождаемость/смертность нод), время жизни каждой ноды, страны и динамику по
месяцам — какой провайдер реально стабильнее, а не кажется.

## Дополнительно

### Управление сервером Dell с ноутбука под Windows

Особого случая: сервер на Linux, ноутбук на Windows. Ярлыки на рабочем столе,
которые дёргают `ssh` + `vpnctl` на сервере, не открывая терминал.

```powershell
cd 'путь\до\vpn-client\desktop'
powershell -ExecutionPolicy Bypass -File install-shortcuts.ps1
```

Создаст на рабочем столе папку **VPN Dell** с ярлыками: включить, выключить,
статус, быстрейший сервер, список серверов, перезапустить, применить
настройки, телеметрия, сводка. Перед использованием откройте `vpn.ps1` и
поправьте `$DellHost` и `$KeyPath` под свой сервер и SSH-ключ. Повторный
запуск установщика безопасен (перезаписывает те же файлы).

### Проверка внутри Windows Sandbox

Режим проверяет подписку, запуск sing-box и прокси **поверх включённого
Durev**, не создавая TUN на хосте. Это не тест маршрутизации приложений хоста,
но позволяет отладить ноды без потери соединения. Однократно включите
компонент Sandbox (потребуется перезагрузка):

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
```

После перезагрузки, с включённым Durev:

```powershell
.\windows\sandbox\Prepare-Sandbox.ps1
Start-Process "$env:LOCALAPPDATA\GolemVLESS\sandbox\Golem-VPN-Test.wsb"
```

Результат после закрытия Sandbox:

```powershell
Get-Content "$env:LOCALAPPDATA\GolemVLESS\sandbox\results\report.txt"
```

## Частые проблемы

### Провайдер подписки блокируется по DPI

Симптом: ссылка подписки открывается в браузере, но
`render_config.py --fetch` виснет и падает по таймауту на TLS-рукопожатии
(TCP до `:443` проходит, дальше тишина). Это блокировка по SNI: браузер
скрывает имя домена через ECH, а `curl`/Python — нет. Обход без VPN (иначе
курица и яйцо):

1. открыть ссылку подписки в браузере;
2. скопировать тело ответа — обычно один base64-блок;
3. вставить его в `endpoints.txt` **вместо** строки со ссылкой (саму ссылку
   закомментировать `#`, не удалять — пригодится для обновления вручную).

Рендерер понимает вставленный base64-блок так же, как скачанный, — `--fetch`
для такой строки не нужен.

### Требуется sing-box ≥ 1.12 (и при чём тут xhttp)

Конфиг рендерится в формат DNS-серверов и inbound-полей sing-box 1.12+; на
sing-box 1.11 конфиг упадёт с «legacy DNS servers is deprecated». Установщик
ставит 1.13.16; при ручном обновлении следите за версией.

Ноды многих подписок (в т.ч. основные ноды Durev) используют транспорт
**xhttp** (`type=xhttp`, `:8443`, `mode=stream-one`). sing-box **не
реализует** xhttp/splithttp вообще — но клиент такие ноды не отбрасывает
(B-011): они идут через отдельно запускаемый `xray-core`, который эту связку
понимает нативно (та же схема, что у официального приложения Durev). Признак
того, что это работает: `state\xray-config.json` существует, и
`vpnctl status`/`GolemVpn.ps1 status` показывают `xray-core PID ...`. Если
xray не установлен (скачивание не удалось при установке) — рендерер тихо
предупреждает и не включает такие ноды в пул, но не падает; поставьте бинарник
вручную в `bin\xray.exe` (Windows) / поставить `xray` в `PATH` (Linux) или
перезапустите установку.

### После включения TUN ничего не работает — ни VPN, ни напрямую

Проверьте `sing-box version` → секция `Tags` должна содержать `with_gvisor`.
Стек TUN в конфиге всегда `gvisor` (задаётся в коде рендерера, не
настраивается через `policy.conf`) — со стеком `system` на некоторых
ядрах/ВМ TUN оказывается **полностью мёртв**: пакеты доходят до интерфейса
(счётчики RX/TX растут), но ни одно соединение не устанавливается — ни через
VPN, ни напрямую, — и это выглядит как «сломался только прямой доступ», хотя
сломан весь datapath. Ошибок в логе при этом нет. Если кто-то менял
`tun_stack` в `render_config.py` вручную — верните `gvisor`.

### `policy.conf` вроде настроен правильно, а программа всё равно идёт напрямую

На Linux правила `[processes-via-vpn]` работают только благодаря capability в
systemd-юните: `CAP_DAC_READ_SEARCH` + `CAP_SYS_PTRACE`. sing-box определяет
программу, читая `/proc` чужого процесса — без этих прав он молча не находит
процесс (**в логе никакой ошибки не будет**) и просто не применяет правило.
Если юнит переустанавливали руками или урезали capability — проверьте после
этого `vpnctl check <имя>`. (На Windows process-matching работает через сам
sing-box, дополнительных прав не нужно.)

### Правило по `node`/`python`/другому интерпретатору заворачивает не ту программу

`process_name` matching в sing-box смотрит на имя исполняемого файла. Все
Node-приложения запускаются как `node`, все Python — как `python3`. Если
вписать в `[processes-via-vpn]` голое имя интерпретатора — через VPN уйдут
**все** программы на этом языке, а не одна нужная. Используйте полный путь
(`process_path`, вторая форма записи в `policy.conf`): на Linux —
`readlink -f $(command -v claude)`, на Windows — абсолютный путь к `.exe`.

## Удаление

### Linux

```bash
sudo bash scripts/uninstall.sh            # оставляет policy.conf и endpoints.txt
sudo bash scripts/uninstall.sh --purge    # удаляет вообще всё, включая ключ
```

Скрипт снимает и systemd-таймер телеметрии `golem-vless-stats.timer`.

### Windows

```powershell
& "$env:LOCALAPPDATA\GolemVLESS\bin\GolemVpn.ps1" uninstall
```

Подтвердите удаление — команда снимет задачи `GolemVLESS`,
`GolemVLESS-Watchdog`, `GolemVLESS-Refresh`, убьёт sing-box/xray, выключит
системный прокси, удалит ярлыки «Golem VPN Windows» и весь каталог
`%LOCALAPPDATA%\GolemVLESS`.

## Безопасность

- `secrets/endpoints.txt`, `/etc/golem-vless/endpoints.txt`,
  `%LOCALAPPDATA%\GolemVLESS\config\endpoints.txt` — секреты, не коммитить
  (защищены `.gitignore`), права `0600` на Linux.
- Не убирайте `CAP_DAC_READ_SEARCH`/`CAP_SYS_PTRACE` из systemd-юнита, не
  проверив после этого `vpnctl check` — молча сломается маршрутизация по
  программам (см. «Частые проблемы» выше).
- После первого включения на удалённом сервере проверяйте доступ **новой**
  SSH-сессией, не текущей.
- `[domains-direct]` в `policy.conf` — держите там банки и госуслуги: трафик
  к ним через чужой сервер — лишний риск блокировки/фрода-фильтров.
- Запасной вход по паролю (B-016): логин/пароль хранится в
  `secrets/server-access.txt` (в `.gitignore`), применяется
  `scripts/enable-password-login.sh`. Парольный SSH разрешён **только из
  локальной сети** (`Match Address 192.168.88.0/24` в конце `sshd_config`);
  извне — лишь ключевой вход. Консоль с монитора/клавиатуры доступна всегда.

## Лицензия

Проект распространяется под лицензией [MIT](LICENSE).

## Структура проекта

```text
vpn-client/
  docs/
    backlog.yaml                ← бэклог идей/задач (машиночитаемый YAML, см. шапку файла)
  policy.conf                     ← ЕДИНСТВЕННЫЙ файл, который обычно нужно править
  secrets/
    endpoints.txt                 ← ваш ключ (gitignore, создаётся из example при install.sh)
    endpoints.example.txt         ← шаблон
    server-access.txt             ← запасной логин/пароль сервера (в .gitignore, B-016)
    server-access.txt.example     ← шаблон
  scripts/
    install.sh                    ← установка на Linux (мультидистрибутивная)
    uninstall.sh                  ← удаление с Linux
    vpnctl                        ← команда управления Linux (ставится в /usr/local/bin)
    render_config.py              ← policy.conf + endpoints.txt → generated/config.json (общий движок)
    stats.py                      ← телеметрия качества нод (B-015)
    enable-password-login.sh      ← запасной вход по паролю: консоль + SSH только из LAN (B-016)
  systemd/
    golem-vless-client.service    ← systemd-юнит (capabilities для TUN и process-routing)
    golem-vless-stats.timer       ← телеметрия каждые 30 минут (B-015)
    golem-vless-stats.service     ← oneshot-сбор телеметрии
  windows/
    Install-GolemVless.ps1        ← установка на Windows (TUN-клиент)
    GolemVpn.ps1                  ← команда управления Windows
    Run-GolemVless.ps1            ← лаунчер (вызывается задачей/ярлыком)
    Watch-GolemVless.ps1          ← watchdog (каждые 5 минут)
    Refresh-Subscription.ps1      ← ежедневное обновление подписки
    Run-Hidden.vbs                ← скрытый запуск задач без консольного окна
  desktop/                        ← опционально: ярлыки для управления сервером Dell
    vpn.ps1
    install-shortcuts.ps1
  generated/                      ← артефакты рендера (gitignore, пересоздаётся)
```