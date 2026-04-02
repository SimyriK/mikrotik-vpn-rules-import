# vpn-rules-import for MikroTik RouterOS v7

Скрипт синхронизирует правила из JSON (в т.ч. MetaCubeX `meta-rules-dat`) и из **простого текста** (списки токенов в одном файле) в MikroTik:

- `/ip firewall address-list` и `/ipv6 firewall address-list` (list `to-vpn`)
- `/ip dns static` (`type=FWD`, `forward-to=8.8.8.8`)

Основной файл в репозитории сейчас: `vpn-rules-import.rsc` (внутри имя скрипта и логов: `vpn-rules-import`).

## 🚀 Быстрая установка (одна команда)

Выполните в терминале MikroTik:

```
/tool/fetch url="https://raw.githubusercontent.com/SimyriK/mikrotik-vpn-rules-import/main/vpn-rules-installer.rsc" dst-path="vpn-rules-installer.rsc"; /import file-name="vpn-rules-installer.rsc"
```

Или если предпочитаете сохранить как скрипт для повторного использования:

```
/system/script/add name=vpn-rules-installer policy=read,write,test,policy,ftp source=([/tool/fetch url="https://raw.githubusercontent.com/SimyriK/mikrotik-vpn-rules-import/main/vpn-rules-installer.rsc" output=user as-value]->"data")
/system/script/run vpn-rules-installer
```

### Быстрая конфигурация (автообновление)

Если при установке вы выбрали автообновление (`vpn-rules-selfupdate` + `vpn-rules-cron`), настройте конфиг в `gist`:

1. Откройте gist: https://gist.github.com/SimyriK/60d355e73bbd0b0dbf7d45ef24c1de11
2. Сделайте fork и заполните под свои нужды
3. Внутри самого gist задайте `listName` (имя `address-list` для VPN) и `vpnRulesConfigSourceUrl` на `raw`-URL вашего форка

Важно: `vpnRulesConfigSourceUrl` указывайте в формате без `commit/hash`-сегмента после `raw`, то есть вида `.../raw/<file-name>`, а не `.../raw/<commit-sha>/<file-name>`.

Далее на роутере откройте `System -> Scripts` и перейдите в скрипт `vpn-rules-config`. Минимум:

```rsc
# Полный HTTPS raw URL тела vpn-rules-config для selfupdate.
# Пусто — не обновлять конфиг по URL.
:global vpnRulesConfigSourceUrl "https://gist.githubusercontent.com/<username>/<id>/raw/<file-name>"
```

Для обновления и приминения правил - запустите обёртку вручную (она сначала selfupdate, потом применяет правила):

```
/system/script/run vpn-rules-cron
```

В дальнейшем обновление и приминение будет происходить по расписанию (по умолчанию каждый день в 04:00:00)

## Что умеет

- Поддержка источников **`fmt=json`** (разбор JSON и `map` с путями) и **`fmt=text`** (plain-text: токены выделяются из текста, тип определяется эвристикой)
- Типы правил: `ip`, `domain`, `subdomain`, `regex` (для `fmt=text` доступны только `ip`, `domain`, `subdomain`; см. ниже)
- Преобразование GitHub `blob` URL в `raw.githubusercontent.com`
- Хранение состояния (fingerprint) в файлах `vpn-rules-state/source-<tag>-<id>.sha512`
- Пропуск неизменившихся источников
- `forceApply=true` для принудительного пере-применения
- `enabled=false` удаляет правила источника и его state-файл
- Cleanup источников, удалённых из `sources`
- `dryRun=true` (показ команд без изменений)
- Контроль минимального DNS `cache-size` в начале выполнения

## Установка в RouterOS

### Вручную

1. Откройте **System -> Scripts**.
2. Скрипт **`vpn-rules-config`**: вставьте содержимое `vpn-rules-config.rsc` (см. комментарии в файле про имя и policies).
3. Скрипт **`vpn-rules-import`**: вставьте содержимое `vpn-rules-import.rsc`.
4. Запустите `vpn-rules-import` вручную и проверьте лог.

Опционально: **`vpn-rules-selfupdate`** и **`vpn-rules-cron`** (содержимое `vpn-rules-cron.rsc`, то же имя на роутере) для планировщика и автообновления; см. «Самообновление с GitHub». Скрипт **`vpn-rules-cron`** должен существовать на устройстве — иначе selfupdate выдаст предупреждение и не обновит его.

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
/system scheduler add name=vpn-rules-import interval=1d start-time=04:00:00 on-event="/system/script/run vpn-rules-import"
```

## Самообновление с GitHub

Отдельный скрипт **`vpn-rules-selfupdate`** (файл `vpn-rules-selfupdate.rsc`): `tool fetch` в файл на флеш, сборка тела как в основном скрипте (без лимита `output=user`), сравнение SHA-512 с текущим `source`, при отличии — `/system script set ... source=`.

В начале файла:

- **`vpnRulesGitBase`** — каталог raw ветки для **`vpn-rules-import.rsc`**, **`vpn-rules-cron.rsc`** и **`vpn-rules-selfupdate.rsc`** (например форк этого репозитория). **`vpn-rules-config.rsc` из основного репо не подтягивается** — на клиентах свой конфиг.
- **`vpnRulesConfigSourceUrl`** — задаётся в **`vpn-rules-config`** (не в selfupdate: иначе при обновлении `vpn-rules-selfupdate.rsc` с GitHub сбросился бы URL). Если непусто, полный **HTTPS** raw одного файла с телом **`vpn-rules-config`**. Пустая строка — selfupdate конфиг по URL не качает.

**Предпочтительный вариант для персонального конфига — [Gist](https://gist.github.com/)**: создай gist, открой **Raw** и используй URL вида:

`https://gist.githubusercontent.com/<user>/<gist-id>/raw/<file-name>`

Пример:

`https://gist.githubusercontent.com/SimyriK/60d355e73bbd0b0dbf7d45ef24c1de11/raw/vpn-rules-config-public`

Важно: для `vpnRulesConfigSourceUrl` используй ссылку без commit/hash-сегмента после `raw` (не `.../raw/<commit-sha>/<file-name>`), иначе URL будет привязан к конкретной версии файла и не обновится.

Дополнительно: GitHub/Gist иногда отдаёт закэшированную версию. В `vpn-rules-selfupdate` для URL на `gist.githubusercontent.com` автоматически добавляется параметр `?ts=...` (cache-buster), чтобы забирать актуальный конфиг.

Режим gist *Secret* — это **не шифрование**: ссылка не индексируется как публичная, но **любой, у кого есть URL, может скачать файл**; для RouterOS `tool fetch` без токена этого достаточно.

Порядок в selfupdate: сначала **`run vpn-rules-config`** (глобалы с устройства, в т.ч. URL), затем `vpn-rules-import` → опционально `vpn-rules-config` с URL → **`vpn-rules-cron`** → **`vpn-rules-selfupdate`**.

Те же policies, что у основного скрипта (`read`, `write`, `test`, `policy`, `ftp`).

### Расписание

В **System → Scheduler** логично повесить одно задание на скрипт **`vpn-rules-cron`**: он сначала вызывает selfupdate (скачивает актуальные `vpn-rules-import.rsc`, `vpn-rules-cron.rsc`, `vpn-rules-selfupdate.rsc` и при необходимости конфиг по URL), затем **`vpn-rules-import`**, так что правила применяются уже новой версией импорта. Интервал и время старта задай под себя.

## Конфигурация

Глобальные параметры списков и источников — в скрипте **`vpn-rules-config`** (`vpn-rules-config.rsc`).

- `dryRun` — только вывод команд
- `forceApply` — игнорировать совпадение hash и применить заново
- `listName` — целевой address-list (по умолчанию `to-vpn`)
- `forwardTo` — DNS forwarder для `FWD` записей
- `stateDir` — директория для state-файлов
- `dnsCacheMinSize` — минимальный `cache-size` DNS cache (если текущее больше, не уменьшается)
- `vpnRulesConfigSourceUrl` — URL для raw файла с конфигом (см. «Самообновление с GitHub»)

### Блок `sources` (`vpnRulesSources`)

Общие поля для любого источника:

- `id` — уникальный идентификатор
- `fmt` — формат: `"json"` или `"text"`
- `tag` — префикс комментария, итог: `<tag>-<id>`
- `enabled` — `"true"` / `"false"`
- `src` — URL тела источника (HTTPS; для GitHub `blob` преобразуется в `raw`)

**Только при `fmt=json`:**

- `map` — список пар `json-path|type` через запятую, например  
  `rules.domain|domain,rules.domain_suffix|subdomain,rules.domain_regex|regex,rules.ip_cidr|ip`

**Только при `fmt=text`:**

Файл — обычный текст: строки и токены извлекаются по допустимым символам (цифры, буквы, `.:/*-#` и т.д.); разделители — всё остальное.

- `filter` — какие типы токенов **применять** как правила:  
  - `"all"` — все поддерживаемые для текста типы (`ip`, `domain`, `subdomain`);  
  - или один тип / список через запятую, например `"ip"` или `"ip,domain"`.  
  Пусто или отсутствует поле — как `"all"`.  
  Токены неподходящего типа или нераспознанные пропускаются.

Эвристика типа токена в тексте:

- строка с `#` в начале — комментарий, не правило;
- есть `/` или `:` — **ip** (IPv4/IPv6 CIDR или фрагмент IPv6);
- начинается с `*.` — **subdomain** (в правило попадает суффикс без `*.`);
- иначе, если строка целиком из допустимых для домена символов — **domain**.

В логе консоли для `fmt=text` по завершении показываются строки вида `typ=ip -> N values` (как смысловой аналог строк `path ... -> N values` у JSON), затем `total rules applied: ...`.

Пример источника plain-text (официальный список сетей Telegram):

```rsc
{
  "id"="tg-cidr";
  "fmt"="text";
  "tag"="tgCidr";
  "enabled"="true";
  "src"="https://core.telegram.org/resources/cidr.txt";
  "filter"="ip"
};
```

Fingerprint для пропуска неизменённых источников учитывает `fmt`, для JSON — ещё `map`, для текста — ещё `filter` (и общие `listName`, `forwardTo`).

## Поведение при изменениях

- Если источник не изменился и конфиг для него не изменился, он пропускается.
- Если `enabled=false`, правила этого источника удаляются.
- Если источник удалён из `sources`, cleanup удалит его правила и state-файл.

## Логи

Префикс логов: `vpn-rules-import:`.

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

- `vpn-rules-import.rsc` — основной RouterOS-скрипт (`vpn-rules-import`)
- `vpn-rules-config.rsc` — конфиг (`vpn-rules-config` на роутере)
- `vpn-rules-selfupdate.rsc` — самообновление скриптов с GitHub (`vpn-rules-selfupdate`)
- `vpn-rules-cron.rsc` — обёртка для планировщика: selfupdate, затем `vpn-rules-import` (`vpn-rules-cron`)
- `vpn-rules-installer.rsc` — интерактивная установка с GitHub (`vpn-rules-installer`)
- `list-geosite-files.sh` — Linux-скрипт для сбора списка geosite JSON
- `README.md` — документация
