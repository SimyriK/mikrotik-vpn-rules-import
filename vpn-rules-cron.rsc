# vpn-rules-cron.rsc
# Один вход по расписанию: selfupdate, затем vpn-rules-import.
#
# Установка: System -> Scripts -> имя vpn-rules-cron, policies: read, write, test, policy, ftp.
#
/system/script/run vpn-rules-selfupdate;
/system/script/run vpn-rules-import;
