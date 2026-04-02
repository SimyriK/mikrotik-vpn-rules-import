# vpn-rules-config.rsc
# Конфигурация источников правил.
#
# Установка: System -> Scripts -> Add, имя vpn-rules-config, policies: read, write, test, policy, ftp.
#
# Имя address-list
:global listName "to-vpn"
# DNS forward-to
:global forwardTo "8.8.8.8"
# Папка для state-файлов
:global stateDir "vpn-rules-state"
# Минимальный dns cache-size (если на роутере уже больше — не уменьшаем).
:global dnsCacheMinSize "4096KiB"
# Полный HTTPS URL raw тела vpn-rules-config для selfupdate. Пусто — не обновлять конфиг по URL.
:global vpnRulesConfigSourceUrl ""

# Поля source:
# id      - уникальный короткий идентификатор набора (используется в state/comment)
# fmt     - формат источника: "json" или "text"
# tag     - префикс комментария; итоговый comment = "<tag>-<id>"
# enabled - "true" или "false" (строкой) для включения/выключения source
# src     - URL источника (можно GitHub blob, будет преобразован в raw)
#
# Только для fmt=json:
# map     - список правил "<json-path>|<type>" через запятую: type: ip | domain | subdomain | regex
#
# Только для fmt=text (plain-text, один токен на строку):
# filter  - какие типы токенов применять: "all" | "ip" | "domain" | "subdomain" | "ip,domain" и т.п.
#           "all" = все реализованные типы (ip, domain, subdomain); нераспознанные пропускаются.
#           Если не указан — поведение как "all".
:global vpnRulesSources {
  {
    "id"="geosite-youtube";
    "fmt"="json";
    "tag"="metaRules";
    "enabled"="true";
    "src"="https://github.com/MetaCubeX/meta-rules-dat/blob/sing/geo/geosite/youtube.json";
    "map"="rules.domain|domain,rules.domain_suffix|subdomain,rules.domain_regex|regex,rules.ip_cidr|ip"
  };
  {
    "id"="geosite-x";
    "fmt"="json";
    "tag"="metaRules";
    "enabled"="true";
    "src"="https://github.com/MetaCubeX/meta-rules-dat/blob/sing/geo/geosite/x.json";
    "map"="rules.domain|domain,rules.domain_suffix|subdomain,rules.domain_regex|regex,rules.ip_cidr|ip"
  };
  {
    "id"="geosite-telegram";
    "fmt"="json";
    "tag"="metaRules";
    "enabled"="true";
    "src"="https://github.com/MetaCubeX/meta-rules-dat/blob/sing/geo/geosite/telegram.json";
    "map"="rules.domain|domain,rules.domain_suffix|subdomain,rules.domain_regex|regex,rules.ip_cidr|ip"
  };
  {
    "id"="tg-cidr";
    "fmt"="text";
    "tag"="tgCidr";
    "enabled"="true";
    "src"="https://core.telegram.org/resources/cidr.txt";
    "filter"="ip"
  };
}
