# vpn-rules-selfupdate.rsc
# Обновление скриптов с GitHub (raw): fetch, сравнение SHA-512, /system/script/set source.
#
# Установка: System -> Scripts -> Add, имя vpn-rules-selfupdate, policies: read, write, test, policy, ftp.
#
:global vpnRulesGitBase "https://raw.githubusercontent.com/SimyriK/mikrotik-vpn-rules-import/main/"
:do { /system/script/run vpn-rules-config } on-error={
  :log warning "vpn-rules-selfupdate: vpn-rules-config failed (optional for URL read)"
}
:local configUrl ""
:do {
  :set configUrl [:tostr $vpnRulesConfigSourceUrl]
} on-error={ :set configUrl "" }

:local base [:tostr $vpnRulesGitBase]
:if ([:len $base] = 0) do={
  :log error "vpn-rules-selfupdate: vpnRulesGitBase empty"
  :error "vpnRulesGitBase empty"
}

:local snames ({})
:local urls ({})
:set snames ($snames, "vpn-rules-import")
:set urls ($urls, ($base . "vpn-rules-import.rsc"))
:if ([:len $configUrl] > 0) do={
  :set snames ($snames, "vpn-rules-config")
  :set urls ($urls, $configUrl)
}
:set snames ($snames, "vpn-rules-cron")
:set urls ($urls, ($base . "vpn-rules-cron.rsc"))
:set snames ($snames, "vpn-rules-selfupdate")
:set urls ($urls, ($base . "vpn-rules-selfupdate.rsc"))

:log info "vpn-rules-selfupdate: start"
:put "vpn-rules-selfupdate: start"
:put ("vpn-rules-selfupdate: gitBase " . $base)

:local idx 0
:local n [:len $snames]
:while ($idx < $n) do={
  :local scriptName [:pick $snames $idx]
  :local url [:pick $urls $idx]
  :set idx ($idx + 1)
  :local tmpName ("vpnRulesSu_" . $scriptName)
  :local content ""
  :local fetchOk false
  :do {
    /tool fetch url=$url mode=https check-certificate=yes-without-crl dst-path=$tmpName http-header-field="User-Agent: vpn-rules-selfupdate/1" as-value
    :set fetchOk true
  } on-error={
    :log warning ("vpn-rules-selfupdate: fetch failed " . $scriptName . " url=" . $url)
    :put ("vpn-rules-selfupdate: fetch failed " . $scriptName)
  }
  :if ($fetchOk = true) do={
    :local fid [/file find name~$tmpName]
    :if ([:len $fid] > 0) do={
      :local fpath [/file get [:pick $fid 0] name]
      :local fileSize [/file get [:pick $fid 0] size]
      :local off 0
      :local chunkLen 32768
      :while ($off < $fileSize) do={
        :local toRead $chunkLen
        :if (($off + $chunkLen) > $fileSize) do={ :set toRead ($fileSize - $off) }
        :local c [/file read file=$fpath offset=$off chunk-size=$toRead as-value]
        :set content ($content . ($c->"data"))
        :set off ($off + $toRead)
      }
      :foreach id in=[/file find name~$tmpName] do={ /file remove $id }
    }
  }
  :if ([:len $content] = 0) do={
    :put ("vpn-rules-selfupdate: skip " . $scriptName . " (empty body)")
  } else={
    :local newSrc [:tolf $content]
    :local sid [/system script find where name=$scriptName]
    :if ([:len $sid] = 0) do={
      :log warning ("vpn-rules-selfupdate: script not found: " . $scriptName)
      :put ("vpn-rules-selfupdate: script not found: " . $scriptName)
    } else={
      :local cur [/system script get [:pick $sid 0] source]
      :local curLf [:tolf $cur]
      :local hNew [:convert $newSrc transform=sha512 to=hex]
      :local hCur [:convert $curLf transform=sha512 to=hex]
      :if ($hNew = $hCur) do={
        :put ("vpn-rules-selfupdate: up to date " . $scriptName)
      } else={
        /system script set [:pick $sid 0] source=$newSrc
        :log info ("vpn-rules-selfupdate: updated " . $scriptName)
        :put ("vpn-rules-selfupdate: updated " . $scriptName)
      }
    }
  }
}

:log info "vpn-rules-selfupdate: done"
:put "vpn-rules-selfupdate: done"
