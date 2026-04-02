# vpn-rules-import.rsc
# Импорт правил из JSON в MikroTik RouterOS v7
#
# Установка: System -> Scripts -> Add, имя vpn-rules-import, policies: read, write, test, policy, ftp.
#
:local ScriptVersion "v1.0"
# Режим "только вывод": true = только :put команд в терминал, без выполнения
:global dryRun false
# Принудительное применение: true = не пропускать source при совпадении hash
:global forceApply false
:local drySuffix ""
:if ($dryRun) do={ :set drySuffix " DRY-RUN" }
:if ($forceApply) do={ :set drySuffix ($drySuffix . " FORCE") }
:log info ("vpn-rules-import: script " . $ScriptVersion . $drySuffix)
:local dryPutSuffix ""
:if ($dryRun) do={ :set dryPutSuffix " DRY-RUN (no changes)" }
:if ($forceApply) do={ :set dryPutSuffix ($dryPutSuffix . " FORCE") }
:put ("vpn-rules-import: script " . $ScriptVersion . $dryPutSuffix)
# Минимальный dns cache-size (если на роутере уже больше — не уменьшаем).
:global dnsCacheMinSize "4096KiB"
:global listName "to-vpn"
:global forwardTo "8.8.8.8"
:global stateDir "vpn-rules-state"
:global vpnRulesSources
# Конфиг: скрипт vpn-rules-config (содержимое vpn-rules-config.rsc)
/system/script/run vpn-rules-config;

# Конвертер размера в KiB (поддержка суффиксов KiB/MiB/GiB/B)
:global sizeToKiB do={
  :local s [:tostr $size]
  :local n [:len $s]
  :if ($n = 0) do={ :return 0 }
  :if (($n > 3) && ([:pick $s ($n - 3) $n] = "KiB")) do={ :return [:tonum [:pick $s 0 ($n - 3)]] }
  :if (($n > 3) && ([:pick $s ($n - 3) $n] = "MiB")) do={ :return ([:tonum [:pick $s 0 ($n - 3)]] * 1024) }
  :if (($n > 3) && ([:pick $s ($n - 3) $n] = "GiB")) do={ :return ([:tonum [:pick $s 0 ($n - 3)]] * 1048576) }
  :if (($n > 1) && ([:pick $s ($n - 1) $n] = "B")) do={ :return ([:tonum [:pick $s 0 ($n - 1)]] / 1024) }
  :return [:tonum $s]
}

:local currentDnsCacheSize ""
:do {
  :set currentDnsCacheSize [:tostr [/ip dns get cache-size]]
} on-error={
  :set currentDnsCacheSize ""
}

:local needKiB [$sizeToKiB size=$dnsCacheMinSize]
:local curKiB [$sizeToKiB size=$currentDnsCacheSize]

:if (($needKiB > 0) && ($curKiB >= $needKiB)) do={
  :put ("vpn-rules-import: dns cache-size OK (current=" . $currentDnsCacheSize . ", min=" . $dnsCacheMinSize . ")")
} else={
  :if ($dryRun) do={
    :put ("vpn-rules-import: [DRY-RUN] would set /ip dns cache-size=" . $dnsCacheMinSize . " (current=" . $currentDnsCacheSize . ")")
  } else={
    :do {
      /ip dns set cache-size=$dnsCacheMinSize
      :put ("vpn-rules-import: set dns cache-size to min=" . $dnsCacheMinSize . " (was " . $currentDnsCacheSize . ")")
    } on-error={ :log warning "vpn-rules-import: failed to set /ip dns cache-size" }
  }
}

# --- Вспомогательные "функции" (RouterOS: global do={}, параметры по имени, :return для значения) ---

# Преобразование GitHub blob URL в raw
:global resolveRawUrl do={
  :local u $url
  :if ([:find $u "github.com"] >= 0 && [:find $u "/blob/"] >= 0) do={
    :local blobPos [:find $u "/blob/"]
    :local prefix [:pick $u 0 $blobPos]
    :local suffix [:pick $u ($blobPos + 6) [:len $u]]
    :local ghPos [:find $prefix "github.com"]
    :local newPrefix ([:pick $prefix 0 $ghPos] . "raw.githubusercontent.com" . [:pick $prefix ($ghPos + 10) [:len $prefix]])
    :set u ($newPrefix . "/" . $suffix)
  }
  :return $u
}

# Нативный хэш RouterOS: SHA-512 (hex).
:global contentHash do={
  :return [:convert $content transform=sha512 to=hex]
}

# Разбиение строки по разделителю
:global splitStr do={
  :local out ({})
  :local rest $str
  :while ([:len $rest] > 0) do={
    :local pos [:find $rest $delim]
    :if ($pos < 0) do={
      :set out ($out, $rest)
      :set rest ""
    } else={
      :set out ($out, [:pick $rest 0 $pos])
      :set rest [:pick $rest ($pos + 1) [:len $rest]]
    }
  }
  :return $out
}

# Замена всех вхождений подстроки в строке
:global replaceAll do={
  :local s $str
  :local f $find
  :local r $repl
  :if ([:len $f] = 0) do={ :return $s }
  :local out ""
  :local rest $s
  :while ([:len $rest] >= 0) do={
    :local pos [:find $rest $f]
    :if ($pos < 0) do={
      :set out ($out . $rest)
      :return $out
    }
    :set out ($out . [:pick $rest 0 $pos] . $r)
    :set rest [:pick $rest ($pos + [:len $f]) [:len $rest]]
  }
  :return $out
}

# Получить значение ключа: сначала пробуем (node)->key (объект ROS), иначе перебор пар [key,val]
:global getKey do={
  :local n $node
  :local k $key
  :do {
    :local v (($n)->$k)
    :if ([:typeof $v] != "nothing") do={ :return $v }
  } on-error={}
  :if ([:typeof $n] = "array") do={
    :foreach p in=$n do={
      :if ([:typeof $p] = "array" && [:len $p] >= 2 && [:pick $p 0] = $k) do={
        :return [:pick $p 1]
      }
    }
  }
  :return ""
}

# Извлечение по пути вида "rules.key": (data)->rules, затем у каждого rule (rule)->key, tostr и split по ";"
:global extractRulesByPath do={
  :global splitStr
  :global getKey
  :local parts [$splitStr str=$path delim="."]
  :local key ""
  :foreach p in=$parts do={ :set key $p }
  :if ([:len $key] = 0) do={ :set key "domain" }
  :local result ({})
  :do {
    :local rules (($root)->"rules")
    :foreach rule in=$rules do={
      :local val [$getKey node=$rule key=$key]
      :local s [:tostr $val]
      :if ([:len $s] > 0) do={
        :local items [$splitStr str=$s delim=";"]
        :foreach item in=$items do={
          :if ([:len $item] > 0) do={ :set result ($result, $item) }
        }
      }
    }
  } on-error={}
  :return $result
}

# Извлечение значений по JSON-пути (fallback). ROS после deserialize отдаёт значения как строки "a;b;c".
:global extractByPath do={
  :global splitStr
  :global getKey
  :global extractRulesByPath
  :if ([:find $path "rules."] = 0) do={
    :return [$extractRulesByPath root=$root path=$path]
  }
  :local parts [$splitStr str=$path delim="."]
  :local nodes ({})
  :set nodes ($nodes, $root)
  :local result ({})
  :local i 0
  :local partsLen [:len $parts]
  :while ($i < $partsLen) do={
    :local key [:pick $parts $i]
    :local nextNodes ({})
    :local isLast ($i = $partsLen - 1)
    :foreach node in=$nodes do={
      :local v [$getKey node=$node key=$key]
      :if ([:typeof $v] = "nothing") do={ } else={
      :if ([:typeof $v] = "array") do={
        :foreach el in=$v do={
          :if ($isLast) do={
            :if ([:typeof $el] = "str") do={ :set result ($result, $el) }
          } else={
            :if ([:typeof $el] != "str") do={ :set nextNodes ($nextNodes, $el) }
          }
        }
      } else={
        :if ($isLast) do={
          :local s [:tostr $v]
          :if ([:len $s] > 0) do={
            :local items [$splitStr str=$s delim=";"]
            :foreach item in=$items do={
              :if ([:len $item] > 0) do={ :set result ($result, $item) }
            }
          }
        } else={
          :if ([:typeof $v] != "str" && [:typeof $v] != "nothing") do={ :set nextNodes ($nextNodes, $v) }
        }
      }
      }
    }
    :set nodes $nextNodes
    :set i ($i + 1)
  }
  :return $result
}

# Нормализация PCRE-подобного regex под более совместимый формат RouterOS DNS regexp.
:global normalizeRegex do={
  :global replaceAll
  :local s $re
  :local n [:len $s]
  :if ($n > 0) do={
    :local first [:pick $s 0 1]
    :if ([:convert $first to=hex] = "5e") do={
      :set s [:pick $s 1 $n]
      :set n [:len $s]
    }
  }
  :local bs ""
  :local alnum "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
  :local c ""
  :local pS [:find $s "S+"]
  :if ($pS > 0) do={
    :set c [:pick $s ($pS - 1) $pS]
    :if ([:convert $c to=hex] = "5c") do={ :set bs $c }
  }
  :if ([:len $bs] = 0) do={
    :local pD [:find $s "d+"]
    :if ($pD > 0) do={
      :set c [:pick $s ($pD - 1) $pD]
      :if ([:convert $c to=hex] = "5c") do={ :set bs $c }
    }
  }
  :if ([:len $bs] = 0) do={
    :local pW [:find $s "w+"]
    :if ($pW > 0) do={
      :set c [:pick $s ($pW - 1) $pW]
      :if ([:convert $c to=hex] = "5c") do={ :set bs $c }
    }
  }
  :if ([:len $bs] = 0) do={
    :local i 0
    :while ($i < [:len $s]) do={
      :local p [:find $s "S" $i]
      :if ($p < 0) do={ :set i [:len $s] } else={
        :if ($p > 0) do={
          :set c [:pick $s ($p - 1) $p]
          :if ([:convert $c to=hex] = "5c") do={ :set bs $c; :set i [:len $s] }
        }
        :set i ($p + 1)
      }
    }
  }
  :if ([:len $bs] = 0) do={
    :local i 0
    :while ($i < [:len $s]) do={
      :local p [:find $s "d" $i]
      :if ($p < 0) do={ :set i [:len $s] } else={
        :if ($p > 0) do={
          :set c [:pick $s ($p - 1) $p]
          :if ([:convert $c to=hex] = "5c") do={ :set bs $c; :set i [:len $s] }
        }
        :set i ($p + 1)
      }
    }
  }
  :if ([:len $bs] = 0) do={
    :local i 0
    :while ($i < [:len $s]) do={
      :local p [:find $s "w" $i]
      :if ($p < 0) do={ :set i [:len $s] } else={
        :if ($p > 0) do={
          :set c [:pick $s ($p - 1) $p]
          :if ([:convert $c to=hex] = "5c") do={ :set bs $c; :set i [:len $s] }
        }
        :set i ($p + 1)
      }
    }
  }
  :if ([:len $bs] = 0) do={
    :local pDot [:find $s "."]
    :if ($pDot > 0) do={
      :set c [:pick $s ($pDot - 1) $pDot]
      :if ([:convert $c to=hex] = "5c") do={
        :set bs $c
      }
    }
  }
  :set n [:len $s]
  :if ($n > 0) do={
    :local last [:pick $s ($n - 1) $n]
    :if ([:convert $last to=hex] = "24") do={
      :if (($n > 1) && ([:len $bs] > 0)) do={
        :local prev [:pick $s ($n - 2) ($n - 1)]
        :if ($prev != $bs) do={ :set s [:pick $s 0 ($n - 1)] }
      } else={
        :set s [:pick $s 0 ($n - 1)]
      }
    }
  }
  :if ([:len $bs] > 0) do={
    :set s [$replaceAll str=$s find=($bs . ".") repl="[.]"]
    :set s [$replaceAll str=$s find=($bs . "d+") repl="[0-9][0-9]*"]
    :set s [$replaceAll str=$s find=($bs . "d") repl="[0-9]"]
    :set s [$replaceAll str=$s find=($bs . "w+") repl="[A-Za-z0-9_][A-Za-z0-9_]*"]
    :set s [$replaceAll str=$s find=($bs . "w") repl="[A-Za-z0-9_]"]
    :set s [$replaceAll str=$s find=($bs . "S+") repl="[^-][^-]*"]
    :set s [$replaceAll str=$s find=($bs . "S") repl="[^-]"]
  }
  :set s [$replaceAll str=$s find=".+" repl="..*"]
  :return $s
}

# Загрузка URL в файл и чтение целиком по кускам (обход лимита 64KB у output=user).
# Идея из eworm-de/routeros-scripts (FetchHuge). Возвращает содержимое или "" при ошибке.
:global fetchToContent do={
  :local tmpName [:tostr $tmpName]
  :if ([:len $tmpName] = 0) do={ :set tmpName "metaRulesTmp" }
  :do {
    :foreach oldId in=[/file find name=$tmpName] do={ /file remove $oldId }
  } on-error={}
  :do {
    /tool fetch url=$url mode=https check-certificate=yes-without-crl dst-path=$tmpName http-header-field="User-Agent: vpn-rules-import-fetch/1" as-value
  } on-error={
    :foreach id in=[/file find name=$tmpName] do={ /file remove $id }
    :do {
      /tool fetch url=$url mode=https check-certificate=no dst-path=$tmpName http-header-field="User-Agent: vpn-rules-import-fetch/1" as-value
    } on-error={
      :log warning "vpn-rules-import: fetch to file failed (strict and no-cert)"
      :return ""
    }
  }
  :local fid [/file find name=$tmpName]
  :if ([:len $fid] = 0) do={ :log warning "vpn-rules-import: temp file not found"; :return "" }
  :local oneFid [:pick $fid 0]
  :local fpath [/file get $oneFid name]
  :local fileSize [/file get $oneFid size]
  :local content ""
  :local off 0
  :local chunkLen 32768
  :while ($off < $fileSize) do={
    :local toRead $chunkLen
    :if (($off + $chunkLen) > $fileSize) do={ :set toRead ($fileSize - $off) }
    :local c [/file read file=$fpath offset=$off chunk-size=$toRead as-value]
    :local part ($c->"data")
    :set content ($content . $part)
    :set off ($off + $toRead)
  }
  :do { /file remove $oneFid } on-error={}
  :return $content
}

# Удаление старых правил по comment
:global removeOldRules do={
  :global dryRun
  :global listName
  :local c $comment
  :if ($dryRun) do={
    :put ("vpn-rules-import: [DRY-RUN] would remove old rules comment=" . $c)
    :foreach id in=[/ip firewall address-list find list=$listName comment=$c] do={
      :put ("vpn-rules-import: [DRY-RUN]   /ip firewall address-list remove " . $id)
    }
    :foreach id in=[/ipv6 firewall address-list find list=$listName comment=$c] do={
      :put ("vpn-rules-import: [DRY-RUN]   /ipv6 firewall address-list remove " . $id)
    }
    :foreach id in=[/ip dns static find comment=$c] do={
      :put ("vpn-rules-import: [DRY-RUN]   /ip dns static remove " . $id)
    }
  } else={
    :do {
      /ip firewall address-list remove [/ip firewall address-list find list=$listName comment=$c]
    } on-error={}
    :do {
      /ipv6 firewall address-list remove [/ipv6 firewall address-list find list=$listName comment=$c]
    } on-error={}
    :do {
      /ip dns static remove [/ip dns static find comment=$c]
    } on-error={}
  }
}

# Применение одного правила по типу
:global applyRule do={
  :global dryRun
  :global listName
  :global forwardTo
  :global normalizeRegex
  :if ($typ = "ip") do={
    :if ([:find $value ":"] >= 0) do={
      :if ($dryRun) do={ :put ("vpn-rules-import: [DRY-RUN] /ipv6 firewall address-list add list=" . $listName . " address=" . $value . " comment=" . $comment) } else={ /ipv6 firewall address-list add list=$listName address=$value comment=$comment }
    } else={
      :if ($dryRun) do={ :put ("vpn-rules-import: [DRY-RUN] /ip firewall address-list add list=" . $listName . " address=" . $value . " comment=" . $comment) } else={ /ip firewall address-list add list=$listName address=$value comment=$comment }
    }
  }
  :if ($typ = "domain") do={
    :if ($dryRun) do={ :put ("vpn-rules-import: [DRY-RUN] /ip firewall address-list add list=" . $listName . " address=" . $value . " comment=" . $comment) } else={ /ip firewall address-list add list=$listName address=$value comment=$comment }
  }
  :if ($typ = "subdomain") do={
    :if ($dryRun) do={
      :put ("vpn-rules-import: [DRY-RUN] /ip firewall address-list add list=" . $listName . " address=" . $value . " comment=" . $comment)
      :put ("vpn-rules-import: [DRY-RUN] /ip dns static add address-list=" . $listName . " forward-to=" . $forwardTo . " match-subdomain=yes name=" . $value . " type=FWD comment=" . $comment)
    } else={
      /ip firewall address-list add list=$listName address=$value comment=$comment
      /ip dns static add address-list=$listName forward-to=$forwardTo match-subdomain=yes name=$value type=FWD comment=$comment
    }
  }
  :if ($typ = "regex") do={
    :local re [$normalizeRegex re=$value]
    :local variants ({})
    :if ([:find $re "(^|[.])"] = 0) do={
      :local base [:pick $re 7 [:len $re]]
      :if ([:len $base] > 0) do={
        :set variants ($variants, $base)
        :set variants ($variants, (".*[.]" . $base))
      }
    } else={
      :set variants ($variants, $re)
    }
    :foreach one in=$variants do={
      :if ($dryRun) do={
        :put ("vpn-rules-import: [DRY-RUN] /ip dns static add address-list=" . $listName . " forward-to=" . $forwardTo . " regexp=" . $one . " type=FWD comment=" . $comment)
      } else={
        :local existing [/ip dns static find type=FWD regexp=$one]
        :if ([:len $existing] > 0) do={
          :log info ("vpn-rules-import: regex already exists, skip " . $one)
        } else={
          :do {
            /ip dns static add address-list=$listName forward-to=$forwardTo regexp=$one type=FWD comment=$comment
          } on-error={
            :log warning ("vpn-rules-import: regex add failed src=" . $value . " norm=" . $one)
            :error ("regex add failed: " . $value)
          }
        }
      }
    }
  }
}

# Обеспечить наличие папки для state-файлов
:global ensureStateDir do={
  :global dryRun
  :global stateDir
  :local fid [/file find name=$stateDir]
  :if ([:len $fid] = 0) do={
    :if ($dryRun) do={
      :put ("vpn-rules-import: [DRY-RUN] would ensure state dir: " . $stateDir)
    } else={
      :do { /file make-directory $stateDir } on-error={ :log warning ("vpn-rules-import: failed to create state dir " . $stateDir) }
    }
  }
}

# Имя файла состояния для source: <stateDir>/source-<comment>.sha512
:global getStateFileName do={
  :global stateDir
  :return ($stateDir . "/source-" . $key . ".sha512")
}

# Чтение сохранённого hash из state-файла
:global getStoredFingerprint do={
  :global getStateFileName
  :local stateFile [$getStateFileName key=$key]
  :local fid [/file find name=$stateFile]
  :if ([:len $fid] = 0) do={ :return "" }
  :local content [/file get [:pick $fid 0] contents]
  :if ([:typeof $content] = "nothing") do={ :return "" }
  :return [:tostr $content]
}

# Запись hash в state-файл
:global setStoredFingerprint do={
  :global dryRun
  :global getStateFileName
  :local stateFile [$getStateFileName key=$key]
  :local cmdStr ("/file set [find name=\"" . $stateFile . "\"] contents=\"" . $fp . "\"")
  :if ($dryRun) do={
    :put ("vpn-rules-import: [DRY-RUN] would store hash: " . $cmdStr)
    :return ""
  }
  :local fid [/file find name=$stateFile]
  :if ([:len $fid] > 0) do={
    :do { /file set [:pick $fid 0] contents=$fp } on-error={ :log warning ("vpn-rules-import: setStoredFingerprint failed set " . $key) }
  } else={
    :do { /file add name=$stateFile contents=$fp } on-error={ :log warning ("vpn-rules-import: setStoredFingerprint failed add " . $key) }
  }
  :return ""
}

# Удаление state-файла fingerprint
:global removeStoredFingerprint do={
  :global dryRun
  :global getStateFileName
  :local stateFile [$getStateFileName key=$key]
  :local fid [/file find name=$stateFile]
  :if ([:len $fid] = 0) do={ :return "" }
  :if ($dryRun) do={
    :put ("vpn-rules-import: [DRY-RUN] would remove state file " . $stateFile)
    :return ""
  }
  :do { /file remove [:pick $fid 0] } on-error={ :log warning ("vpn-rules-import: removeStoredFingerprint failed " . $key) }
  :return ""
}

# Очистка source, удалённых из config: удалить правила и state-файл
:global cleanupRemovedSources do={
  :global dryRun
  :global listName
  :global stateDir
  :local active ","
  :foreach s in=$sources do={
    :local sid ($s->"id")
    :local stag ($s->"tag")
    :if (([:len $stag] > 0) && ([:len $sid] > 0)) do={
      :set active ($active . $stag . "-" . $sid . ",")
    }
  }
  :local pref ($stateDir . "/source-")
  :local prefLen [:len $pref]
  :local suff ".sha512"
  :local suffLen [:len $suff]
  :foreach fid in=[/file find] do={
    :local fname [/file get $fid name]
    :if (([:find $fname $pref] = 0) && ([:len $fname] > ($prefLen + $suffLen)) && ([:pick $fname ([:len $fname] - $suffLen) [:len $fname]] = $suff)) do={
      :local key [:pick $fname $prefLen ([:len $fname] - $suffLen)]
      :if ([:find $active ("," . $key . ",")] < 0) do={
        :put ("vpn-rules-import: cleanup removed source key=" . $key)
        :if ($dryRun) do={
          :put ("vpn-rules-import: [DRY-RUN] would remove rules comment=" . $key)
          :foreach id in=[/ip firewall address-list find list=$listName comment=$key] do={
            :put ("vpn-rules-import: [DRY-RUN]   /ip firewall address-list remove " . $id)
          }
          :foreach id in=[/ipv6 firewall address-list find list=$listName comment=$key] do={
            :put ("vpn-rules-import: [DRY-RUN]   /ipv6 firewall address-list remove " . $id)
          }
          :foreach id in=[/ip dns static find comment=$key] do={
            :put ("vpn-rules-import: [DRY-RUN]   /ip dns static remove " . $id)
          }
          :put ("vpn-rules-import: [DRY-RUN]   /file remove " . $fid)
        } else={
          :do { /ip firewall address-list remove [/ip firewall address-list find list=$listName comment=$key] } on-error={}
          :do { /ipv6 firewall address-list remove [/ipv6 firewall address-list find list=$listName comment=$key] } on-error={}
          :do { /ip dns static remove [/ip dns static find comment=$key] } on-error={}
          :do { /file remove $fid } on-error={ :log warning ("vpn-rules-import: failed remove orphan state file " . $fname) }
        }
      }
    }
  }
}

# Обеспечить наличие списка to-vpn (создаётся при первом add)
:if (!$dryRun) do={
  :do {
    /ip firewall address-list add list=$listName address=0.0.0.1 comment="metaRules-placeholder"
    /ip firewall address-list remove [find list=$listName comment="metaRules-placeholder"]
  } on-error={}
} else={
  :put ("vpn-rules-import: [DRY-RUN] would ensure list: " . $listName)
}
:if ([:typeof $vpnRulesSources] != "array") do={
  :log warning "vpn-rules-import: vpnRulesSources is empty or invalid (check vpn-rules-config)"
  :put "vpn-rules-import: vpnRulesSources is empty or invalid (check vpn-rules-config)"
  :set vpnRulesSources ({})
}
$ensureStateDir
$cleanupRemovedSources sources=$vpnRulesSources

# Определение типа токена из plain-text строки (для fmt=text).
# Возвращает: "ip" | "domain" | "subdomain" | "" (пропустить).
# "#..."         → "" (комментарий)
# содержит "/"   → "ip" (IPv4/IPv6 CIDR)
# содержит ":"   → "ip" (IPv6 без маски)
# начинается "*."→ "subdomain"
# [a-z0-9A-Z.-]  → "domain"
# иначе          → ""
:global detectTokenType do={
  :local t $token
  :local tLen [:len $t]
  :if ($tLen = 0) do={ :return "" }
  :if ([:pick $t 0 1] = "#") do={ :return "" }
  :if ([:find $t "/"] >= 0) do={ :return "ip" }
  :if ([:find $t ":"] >= 0) do={ :return "ip" }
  :if (($tLen > 2) && ([:pick $t 0 2] = "*.")) do={ :return "subdomain" }
  :local allowed "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
  :local i 0
  :local isDomain true
  :while ($i < $tLen) do={
    :if ([:find $allowed [:pick $t $i ($i + 1)]] < 0) do={ :set isDomain false; :set i $tLen }
    :set i ($i + 1)
  }
  :if ($isDomain) do={ :return "domain" }
  :return ""
}

# Токенизация plain-text: символы вне набора — разделители.
# Возвращает массив строк-токенов.
:global tokenizeText do={
  :local text $content
  :local allowed "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.:/.-_*#"
  :local tokens ({})
  :local tok ""
  :local i 0
  :local n [:len $text]
  :while ($i < $n) do={
    :local ch [:pick $text $i ($i + 1)]
    :if ([:find $allowed $ch] >= 0) do={
      :set tok ($tok . $ch)
    } else={
      :if ([:len $tok] > 0) do={
        :set tokens ($tokens, $tok)
        :set tok ""
      }
    }
    :set i ($i + 1)
  }
  :if ([:len $tok] > 0) do={ :set tokens ($tokens, $tok) }
  :return $tokens
}

# --- Обработка одного source + dispatcher форматов ---
:global processSource do={
  :global resolveRawUrl
  :global fetchToContent
  :global contentHash
  :global forceApply
  :global listName
  :global forwardTo
  :global getStoredFingerprint
  :global removeOldRules
  :global removeStoredFingerprint
  :global splitStr
  :global extractByPath
  :global applyRule
  :global setStoredFingerprint
  :global detectTokenType
  :global tokenizeText

  :local id ($src->"id")
  :local tag ($src->"tag")
  :local fmt ($src->"fmt")
  :local enabled ($src->"enabled")
  :local srcUrl ($src->"src")
  :local mapStr ($src->"map")
  :local comment ($tag . "-" . $id)

  :put ("--- source " . $id . " ---")
  :if ($enabled != "true") do={
    :put ("  disabled -> remove rules and state")
    :do { $removeOldRules comment=$comment } on-error={}
    :do { $removeStoredFingerprint key=$comment } on-error={}
    :return ""
  }

  :if (($fmt != "json") && ($fmt != "text")) do={
    :put ("  skipped (unsupported fmt=" . $fmt . ")")
    :log warning ("vpn-rules-import: source " . $id . " unsupported fmt " . $fmt)
    :return ""
  }

  :local url [$resolveRawUrl url=$srcUrl]
  :log info ("vpn-rules-import: source " . $id . " fetch " . $url . " fmt=" . $fmt)

  :local content [$fetchToContent url=$url tmpName=("metaRulesTmp-" . $id)]
  :put ("  fetch: content len=" . [:len $content])
  :if ([:len $content] = 0) do={
    :put ("  fetch failed or empty")
    :log warning ("vpn-rules-import: fetch failed " . $id)
    :return ""
  }

  :local fp [$contentHash content=$content]
  :local cfgKey ("cfg|comment=" . $comment . "|fmt=" . $fmt . "|list=" . $listName . "|fwd=" . $forwardTo)
  :if ($fmt = "json") do={ :set cfgKey ($cfgKey . "|map=" . $mapStr) }
  :if ($fmt = "text") do={ :set cfgKey ($cfgKey . "|filter=" . ($src->"filter")) }
  :set fp [$contentHash content=($fp . "|" . $cfgKey)]
  :local stored [$getStoredFingerprint key=$comment]

  :if (($fp = $stored) && (!$forceApply)) do={
    :put ("  skip (unchanged)")
    :log info ("vpn-rules-import: skip (unchanged) " . $id)
    :return ""
  }
  :if (($fp = $stored) && ($forceApply)) do={
    :put ("  force apply (unchanged hash)")
  }

  :put ("  apply (will parse and apply rules)")
  :log info ("vpn-rules-import: apply " . $id)

  # --- fmt=json ---
  :if ($fmt = "json") do={
    :local data ""
    :local jsonStr [:tolf [:tostr $content]]
    :do {
      :set data [:deserialize from=json $jsonStr]
    } on-error={
      :put ("  DESERIALIZE #1 FAILED, try version workaround")
      :local fixedJson $jsonStr
      :local vKeyPos [:find $fixedJson "\"version\""]
      :if ($vKeyPos >= 0) do={
        :local vColonPos [:find $fixedJson ":" $vKeyPos]
        :local vCommaPos [:find $fixedJson "," $vColonPos]
        :if (($vColonPos >= 0) && ($vCommaPos > $vColonPos)) do={
          :set fixedJson ([:pick $fixedJson 0 ($vColonPos + 1)] . "\"2\"" . [:pick $fixedJson $vCommaPos [:len $fixedJson]])
        }
      }
      :do {
        :set data [:deserialize from=json $fixedJson]
      } on-error={
        :put ("  DESERIALIZE FAILED")
        :log error ("vpn-rules-import: deserialize failed " . $id)
      }
    }
    :if ([:typeof $data] != "array") do={
      :put ("  data is NOT array, skip rules")
      :return ""
    }
    $removeOldRules comment=$comment
    :local pairs [$splitStr str=$mapStr delim=","]
    :local ruleCount 0
    :foreach pair in=$pairs do={
      :local sep [:find $pair "|"]
      :if ($sep >= 0) do={
        :local path [:pick $pair 0 $sep]
        :local typ [:pick $pair ($sep + 1) [:len $pair]]
        :local values [$extractByPath root=$data path=$path]
        :put ("  path " . $path . " -> " . [:len $values] . " values, typ=" . $typ)
        :foreach v in=$values do={
          :if ([:len $v] > 0) do={
            :set ruleCount ($ruleCount + 1)
            :do { $applyRule typ=$typ value=$v comment=$comment } on-error={ :log warning ("vpn-rules-import: apply rule failed " . $typ . " " . $v) }
          }
        }
      }
    }
    :put ("  total rules applied: " . $ruleCount)
  }

  # --- fmt=text ---
  # plain-text: каждый токен на строке авто-детектируется по типу (ip/domain/subdomain).
  # Поле filter: "all" | "<type>" | "<type>,<type>" — какие типы применять.
  # Токены, не соответствующие фильтру или нераспознанные — пропускаются.
  :if ($fmt = "text") do={
    :local filterStr [:tostr ($src->"filter")]
    :if ([:len $filterStr] = 0) do={ :set filterStr "all" }
    :local filterAll ($filterStr = "all")
    :local filterParts [$splitStr str=$filterStr delim=","]
    :local tokens [$tokenizeText content=$content]
    $removeOldRules comment=$comment
    :local ruleCount 0
    :local cntIp 0
    :local cntDomain 0
    :local cntSubdomain 0
    :local skipCount 0
    :foreach tok in=$tokens do={
      :local typ [$detectTokenType token=$tok]
      :if ([:len $typ] = 0) do={
        :set skipCount ($skipCount + 1)
      } else={
        :local pass $filterAll
        :if (!$filterAll) do={
          :foreach f in=$filterParts do={
            :if ($f = $typ) do={ :set pass true }
          }
        }
        :if ($pass) do={
          :local applyVal $tok
          :if ($typ = "subdomain") do={ :set applyVal [:pick $tok 2 [:len $tok]] }
          :set ruleCount ($ruleCount + 1)
          :if ($typ = "ip") do={ :set cntIp ($cntIp + 1) }
          :if ($typ = "domain") do={ :set cntDomain ($cntDomain + 1) }
          :if ($typ = "subdomain") do={ :set cntSubdomain ($cntSubdomain + 1) }
          :do { $applyRule typ=$typ value=$applyVal comment=$comment } on-error={
            :log warning ("vpn-rules-import: apply rule failed " . $typ . " " . $tok)
          }
        } else={
          :set skipCount ($skipCount + 1)
        }
      }
    }
    :if ($cntIp > 0) do={ :put ("  typ=ip -> " . $cntIp . " values") }
    :if ($cntDomain > 0) do={ :put ("  typ=domain -> " . $cntDomain . " values") }
    :if ($cntSubdomain > 0) do={ :put ("  typ=subdomain -> " . $cntSubdomain . " values") }
    :put ("  total rules applied: " . $ruleCount)
  }

  :do { $setStoredFingerprint key=$comment fp=$fp } on-error={ :log warning ("vpn-rules-import: setStoredFingerprint failed " . $id) }
  :return ""
}

:log info ("vpn-rules-import: script " . $ScriptVersion . " (run started)")
:foreach src in=$vpnRulesSources do={
  :do {
    $processSource src=$src
  } on-error={
    :log warning ("vpn-rules-import: source failed " . ($src->"id"))
    :put ("vpn-rules-import: source failed " . ($src->"id"))
  }
  :put ("")
}

:put ("vpn-rules-import: done")
:log info "vpn-rules-import: done"
