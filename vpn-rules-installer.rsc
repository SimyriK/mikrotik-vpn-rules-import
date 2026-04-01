# vpn-rules-installer.rsc
# Quick run (SSH / Terminal).
#
:global vpnRulesInstallerBase "https://raw.githubusercontent.com/SimyriK/mikrotik-vpn-rules-import/main/"
:global vpnRulesInstallerRead do={:return}
:global vpnRulesInstallerCleanup do={
  :foreach id in=[/file find where name="vpn-rules-installer.rsc"] do={ /file remove $id }
}
:global vpnRulesInstallerAbort false
:set vpnRulesInstallerAbort false

:local base [:tostr $vpnRulesInstallerBase]
:if ([:len $base] = 0) do={ :error "vpnRulesInstallerBase is empty" }

:put ""
:put "=== vpn-rules installer ==="
:put ("raw base: " . $base)
:put ""

:local names { "vpn-rules-import"; "vpn-rules-config"; "vpn-rules-selfupdate"; "vpn-rules-cron" }
:local found ({})
:foreach n in=$names do={
  :if ([:len [/system script find where name=$n]] > 0) do={ :set found ($found, $n) }
}

:local reinstallMode "all"
:if ([:len $found] > 0) do={
  :put "Scripts already on device:"
  :foreach n in=$found do={ :put ("  - " . $n) }
  :put ""
  :local hasCfg false
  :if ([:len [/system script find where name=vpn-rules-config]] > 0) do={ :set hasCfg true }
  :local ans ""
  :if ($hasCfg) do={
    :put "Reinstall?"
    :put "  1 - No (exit)"
    :put "  2 - Yes, update all except vpn-rules-config"
    :put "  3 - Yes, overwrite everything"
    :put "Choice [1]:"
    :set ans [:tostr [$vpnRulesInstallerRead]]
    :if ([:len $ans] = 0) do={ :set ans "1" }
    :if ($ans = "1") do={ [$vpnRulesInstallerCleanup]; :put "Cancelled."; :set vpnRulesInstallerAbort true }
    :if ($ans = "2") do={ :set reinstallMode "keep-config" }
    :if ($ans = "3") do={ :set reinstallMode "all" }
    :if (($ans != "1") && ($ans != "2") && ($ans != "3")) do={ [$vpnRulesInstallerCleanup]; :put "Cancelled."; :set vpnRulesInstallerAbort true }
  } else={
    :put "Reinstall?"
    :put "  1 - No (exit)"
    :put "  2 - Yes, overwrite all"
    :put "Choice [1]:"
    :set ans [:tostr [$vpnRulesInstallerRead]]
    :if ([:len $ans] = 0) do={ :set ans "1" }
    :if ($ans = "1") do={ [$vpnRulesInstallerCleanup]; :put "Cancelled."; :set vpnRulesInstallerAbort true }
    :if ($ans = "2") do={ :set reinstallMode "all" }
    :if (($ans != "1") && ($ans != "2")) do={ [$vpnRulesInstallerCleanup]; :put "Cancelled."; :set vpnRulesInstallerAbort true }
  }
  :put ""
} else={
  :put "No scripts found - fresh install."
  :put ""
}

:if (!$vpnRulesInstallerAbort) do={
  :local wantAuto false
  :local wantSch false
  :put "Download auto-update (selfupdate + cron)? y/n [n]:"
  :local ansAuto [:tostr [$vpnRulesInstallerRead]]
  :if ($ansAuto = "y" || $ansAuto = "Y" || $ansAuto = "yes" || $ansAuto = "YES") do={ :set wantAuto true }

  :put "Add daily scheduler 04:00 ? y/n [n]:"
  :local ansSch [:tostr [$vpnRulesInstallerRead]]
  :if ($ansSch = "y" || $ansSch = "Y" || $ansSch = "yes" || $ansSch = "YES") do={ :set wantSch true }

  :if ($wantSch && (!$wantAuto)) do={
    :put "Sched will run vpn-rules-import only (no selfupdate in chain)."
  }

  :local jobs ({})
  :if ($wantAuto) do={
    :set jobs {
      { "script"="vpn-rules-import"; "file"="vpn-rules-import.rsc" };
      { "script"="vpn-rules-config"; "file"="vpn-rules-config.rsc" };
      { "script"="vpn-rules-selfupdate"; "file"="vpn-rules-selfupdate.rsc" };
      { "script"="vpn-rules-cron"; "file"="vpn-rules-cron.rsc" }
    }
  } else={
    :set jobs {
      { "script"="vpn-rules-import"; "file"="vpn-rules-import.rsc" };
      { "script"="vpn-rules-config"; "file"="vpn-rules-config.rsc" }
    }
  }

  :put ""
  :put "Fetching and writing scripts..."
  :foreach j in=$jobs do={
    :local sname ($j->"script")
    :local fname ($j->"file")
    :if (($sname = "vpn-rules-config") && ($reinstallMode = "keep-config")) do={
      :put ("SKIP " . $sname . " (keep local config)")
    } else={
      :local url ($base . $fname)
      :local tmpName ("vpnInst_" . $sname)
      :local content ""
      :do {
        /tool fetch url=$url mode=https check-certificate=yes-without-crl dst-path=$tmpName as-value
      } on-error={
        :put ("FETCH ERR: " . $url)
        [$vpnRulesInstallerCleanup]
        :error ("fetch failed: " . $fname)
      }
      :local fid [/file find name~$tmpName]
      :if ([:len $fid] = 0) do={ [$vpnRulesInstallerCleanup]; :error ("temp file missing: " . $tmpName) }
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
      :if ([:len $content] = 0) do={ [$vpnRulesInstallerCleanup]; :error ("empty body: " . $fname) }
      :local body [:tolf $content]
      :local sid [/system script find where name=$sname]
      :if ([:len $sid] = 0) do={
        /system script add name=$sname owner=$sname policy=read,write,test,policy,ftp source=$body
        :put ("ADD " . $sname)
      } else={
        /system script set [:pick $sid 0] source=$body
        :put ("SET " . $sname)
      }
    }
  }

  :if ($wantSch) do={
    :foreach id in=[/system scheduler find where name=vpn-rules-daily] do={
      /system scheduler remove $id
    }
    :local ev ""
    :if ($wantAuto) do={
      :set ev "/system/script/run vpn-rules-cron"
    } else={
      :set ev "/system/script/run vpn-rules-import"
    }
    /system scheduler add name=vpn-rules-daily interval=1d start-time=04:00:00 on-event=$ev policy=read,write,test,policy,ftp
    :put ("scheduler vpn-rules-daily -> " . $ev)
  }

  :put ""
  :put "=== done ==="
  :put "Edit vpn-rules-config (sources)."
  :if ($wantAuto) do={
    :put "Set vpnRulesConfigSourceUrl there if you want remote config updates."
  }
  :if ($wantSch) do={
    :put "Daily 04:00 enabled - change in System -> Scheduler -> vpn-rules-daily if needed."
  }
  :put "Manual: /system/script/run vpn-rules-import"
  :put ""
  :put "Removing installer file vpn-rules-installer.rsc if present..."
  :delay 1s
  [$vpnRulesInstallerCleanup]
}
