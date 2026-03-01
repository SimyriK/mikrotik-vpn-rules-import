# vpn-rules-sync for MikroTik RouterOS v7

Скрипт синхронизирует правила из JSON-источников (MetaCubeX `meta-rules-dat`) в MikroTik:

- `/ip firewall address-list` и `/ipv6 firewall address-list` (list `to-vpn`)
- `/ip dns static` (`type=FWD`, `forward-to=8.8.8.8`)

Основной файл в репозитории сейчас: `vpn-rules-import.rsc` (внутри имя скрипта и логов: `vpn-rules-sync`).

## Что умеет

- Поддержка источников в формате JSON (`fmt=json`)
- Типы правил: `ip`, `domain`, `subdomain`, `regex`
- Преобразование GitHub `blob` URL в `raw.githubusercontent.com`
- Хранение состояния (fingerprint) в файлах `vpn-rules-state/source-<tag>-<id>.sha512`
- Пропуск неизменившихся источников
- `forceApply=true` для принудительного пере-применения
- `enabled=false` удаляет правила источника и его state-файл
- Cleanup источников, удалённых из `sources`
- `dryRun=true` (показ команд без изменений)
- Контроль минимального DNS `cache-size` в начале выполнения

## Установка в RouterOS

1. Откройте **System -> Scripts**.
2. Создайте скрипт с именем `vpn-rules-sync`.
3. Вставьте содержимое `vpn-rules-import.rsc`.
4. Запустите вручную первый раз и проверьте лог.

## Что именно создаёт скрипт

Скрипт пишет правила с `comment=<tag>-<id>` и перед обновлением удаляет старые правила этого же source.

- `type=ip`:
`/ip firewall address-list add list=to-vpn address=<IPv4/CIDR> comment=<tag>-<id>`
- `type=ip` (IPv6):
`/ipv6 firewall address-list add list=to-vpn address=<IPv6/CIDR> comment=<tag>-<id>`
- `type=domain`:
`/ip firewall address-list add list=to-vpn address=<domain> comment=<tag>-<id>`
- `type=subdomain`:
`/ip dns static add type=FWD name=<domain> match-subdomain=yes address-list=to-vpn forward-to=8.8.8.8 comment=<tag>-<id>`
- `type=regex`:
`/ip dns static add type=FWD regexp=<normalized-regex> address-list=to-vpn forward-to=8.8.8.8 comment=<tag>-<id>`

## Что должно быть настроено на роутере

Сам скрипт только наполняет `address-list` и DNS FWD-правила. Чтобы трафик реально уходил в VPN, нужны firewall/routing правила.

Минимально обычно настраивают:

- `mangle` по `dst-address-list=to-vpn` с установкой `routing-mark` (или `connection-mark`)
- маршрут/таблицу маршрутизации для этого `routing-mark` через VPN-интерфейс
- NAT/masquerade для VPN-интерфейса (если требуется вашей схемой)
- использование DNS роутера клиентами LAN (иначе DNS static правила не будут задействованы)

Пример (адаптируй под свою схему):

```rsc
/ip firewall mangle add chain=prerouting dst-address-list=to-vpn action=mark-routing new-routing-mark=to-vpn passthrough=no
/routing table add name=to-vpn fib
/ip route add dst-address=0.0.0.0/0 gateway=<vpn-gateway-or-interface> routing-table=to-vpn
```

## Права (policies) для скрипта

Рекомендуемый минимум:

- `read`
- `write`
- `test`
- `policy`
- `ftp`

`ftp` нужен для `tool fetch ... dst-path=...` (иначе возможна ошибка `cannot open file: permission denied`).

## Scheduler

Добавление планировщика (раз в сутки):

```rsc
/system scheduler add name=vpn-rules-sync interval=1d start-time=04:00:00 on-event="/system script run vpn-rules-sync"
```

## Конфигурация

В начале скрипта:

- `dryRun` — только вывод команд
- `forceApply` — игнорировать совпадение hash и применить заново
- `listName` — целевой address-list (по умолчанию `to-vpn`)
- `forwardTo` — DNS forwarder для `FWD` записей
- `stateDir` — директория для state-файлов
- `dnsCacheMinSize` — минимальный `cache-size` DNS cache (если текущее больше, не уменьшается)

### Блок `sources`

Для каждого источника:

- `id` — уникальный идентификатор
- `tag` — префикс комментария, итог: `<tag>-<id>`
- `enabled` — `"true"` / `"false"`
- `src` — URL JSON
- `map` — сопоставление `json-path|type` через запятую

Пример `map`:

`rules.domain|domain,rules.domain_suffix|subdomain,rules.domain_regex|regex,rules.ip_cidr|ip`

## Поведение при изменениях

- Если источник не изменился и конфиг для него не изменился, он пропускается.
- Если `enabled=false`, правила этого источника удаляются.
- Если источник удалён из `sources`, cleanup удалит его правила и state-файл.

## Логи

Префикс логов: `vpn-rules-sync:`.

Типичные сообщения:

- `skip (unchanged)`
- `apply <id>`
- `fetch failed <id>`
- `disabled -> remove rules and state`
- `cleanup removed source key=...`

## Linux helper: список geosite JSON

Файл `list-geosite-files.sh` получает полный список JSON-файлов в `MetaCubeX/meta-rules-dat/sing/geo/geosite` через GitHub API и сохраняет в `list.txt`.

Запуск:

```bash
./list-geosite-files.sh
```

Или в другой файл:

```bash
./list-geosite-files.sh geosite-list.txt
```

Требование: установлен `jq`.

## Файлы репозитория

- `vpn-rules-import.rsc` — основной RouterOS-скрипт (`vpn-rules-sync`)
- `list-geosite-files.sh` — Linux-скрипт для сбора списка geosite JSON
- `README.md` — документация
