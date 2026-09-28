#!/bin/sh
# dns_diag.sh — диагностика DNS-серверов (DoH/DoT/UDP) на роутере netcraze ultra nc 1812
# (Entware, BusyBox v1.37.0, ash). Запуск: ssh root@router 'sh /opt/dns_diag.sh'
#
# Проверяет для каждого сервера из списков ниже:
#   - время отклика (мс) на резолв тестового домена
#   - работоспособность (успешный ответ NOERROR / успешное HTTP-подключение)
#
# Требуемые пакеты Entware (ставятся через opkg):
#   curl      — для проверки DoH (curl --doh-url, поддерживается с curl 7.62+)
#   knot-dig  — даёт бинарь kdig, нужен для проверки DoT (+tls) и UDP
# Если что-то из этого не установлено, соответствующий блок тестов будет пропущен
# с подсказкой, что поставить.

set -u

# неинтерактивный sh (ssh host 'sh script.sh') не подтягивает /opt/etc/profile,
# поэтому /opt/bin и /opt/sbin (куда opkg ставит бинари) могут отсутствовать в PATH
export PATH="/opt/bin:/opt/sbin:$PATH"

# ---------- настройки ----------
TEST_DOMAIN="${TEST_DOMAIN:-example.com}"   # домен для тестового резолва
TIMEOUT="${TIMEOUT:-3}"                     # таймаут одного запроса, сек
RESULTS_FILE="/tmp/dns_diag_results.$$"
: > "$RESULTS_FILE"

# ---------- определение доступных утилит ----------
HAVE_CURL=0
HAVE_CURL_DOH=0
HAVE_KDIG=0

if command -v curl >/dev/null 2>&1; then
    HAVE_CURL=1
    if curl --help all 2>&1 | grep -q -- '--doh-url'; then
        HAVE_CURL_DOH=1
    fi
fi

if command -v kdig >/dev/null 2>&1; then
    HAVE_KDIG=1
fi

echo "=== Диагностика DNS-серверов (netcraze ultra nc 1812) ==="
echo "Тестовый домен : $TEST_DOMAIN"
echo "Таймаут запроса: ${TIMEOUT}s"
echo "curl            : $([ "$HAVE_CURL" = 1 ] && echo "найден" || echo "НЕ найден")"
echo "curl --doh-url  : $([ "$HAVE_CURL_DOH" = 1 ] && echo "поддерживается" || echo "НЕ поддерживается (нужна свежая версия curl)")"
echo "kdig            : $([ "$HAVE_KDIG" = 1 ] && echo "найден" || echo "НЕ найден")"
echo

if [ "$HAVE_CURL_DOH" != 1 ]; then
    echo "! DoH-тесты будут пропущены. Установите/обновите curl:"
    echo "    opkg update && opkg install curl ca-certificates"
    echo
fi

if [ "$HAVE_KDIG" != 1 ]; then
    echo "! DoT- и UDP-тесты будут пропущены (нужен kdig из пакета knot-dig)."
    echo "    opkg update && opkg install knot-dig ca-certificates"
    echo
fi

# ---------- списки серверов (name|target) ----------

DOH_LIST='
Google|https://dns.google/dns-query
Cloudflare|https://cloudflare-dns.com/dns-query
Cloudflare (M)|https://mozilla.cloudflare-dns.com/dns-query
Cloudflare (S)|https://security.cloudflare-dns.com/dns-query
Cloudflare dns|https://dns.cloudflare.com/dns-query
Cloudflare dot|https://1dot1dot1dot1.cloudflare-dns.com/dns-query
Cloudflare IP|https://1.1.1.1/dns-query
Cloudflare IP 2|https://1.0.0.1/dns-query
Cloudflare one|https://one.one.one.one/dns-query
Quad9|https://dns.quad9.net/dns-query
Quad9 (S)|https://dns11.quad9.net/dns-query
Quad9 (UN)|https://dns10.quad9.net/dns-query
Quad9 (UN2)|https://dns12.quad9.net/dns-query
AdGuard|https://dns.adguard-dns.com/dns-query
AdGuard (F)|https://family.adguard-dns.com/dns-query
AdGuard (L)|https://dns.adguard.com/dns-query
AdGuard (UN)|https://unfiltered.adguard-dns.com/dns-query
Alibaba|https://dns.alidns.com/dns-query
CleanBrowsing|https://doh.cleanbrowsing.org/doh/security-filter
ControlD|https://freedns.controld.com/p0
DNS.SB|https://dns.sb/dns-query
DNS4all|https://doh.dns4all.eu/dns-query
dnsforge|https://dnsforge.de/dns-query
Gesellschaft|https://dns.digitale-gesellschaft.ch/dns-query
LibreDNS|https://doh.libredns.gr/dns-query
Mullvad|https://dns.mullvad.net/dns-query
NextDNS|https://dns.nextdns.io/dns-query
OpenDNS #1|https://doh.opendns.com/dns-query
OpenDNS #2|https://dns.opendns.com/dns-query
UncensoredDNS|https://anycast.uncensoreddns.org/dns-query
Wikimedia|https://wikimedia-dns.org/dns-query
XboxDNS (RU)|https://xbox-dns.ru/dns-query
Comss.one #1|https://dns.comss.one/dns-query
Comss.one #2|https://doh.comss.one/dns-query
Yandex|https://common.dot.dns.yandex.net/dns-query
Geohide|https://dns.geohide.ru:444/dns-query
'

DOT_LIST='
Google #1|dns.google
Google #2|8.8.8.8
Google #3|8.8.4.4
Cloudflare (S)|security.cloudflare-dns.com
Cloudflare dot|1dot1dot1dot1.cloudflare-dns.com
Cloudflare IP|1.1.1.1
Cloudflare IP 2|1.0.0.1
Cloudflare one|one.one.one.one
Quad9|dns.quad9.net
Quad9 (S)|dns11.quad9.net
Quad9 (UN)|dns10.quad9.net
Quad9 (UN2)|dns12.quad9.net
AdGuard|dns.adguard-dns.com
AdGuard (F)|family.adguard-dns.com
AdGuard (L)|dns.adguard.com
AdGuard (UN)|unfiltered.adguard-dns.com
Alibaba|dns.alidns.com
CleanBrowsing|security-filter-dns.cleanbrowsing.org
ControlD|freedns.controld.com
DNS.SB|dot.sb
DNS4all|dot.dns4all.eu
dnsforge|dnsforge.de
Gesellschaft|dns.digitale-gesellschaft.ch
LibreDNS|dot.libredns.gr
Mullvad|dns.mullvad.net
NextDNS|dns.nextdns.io
OpenDNS|dns.opendns.com
UncensoredDNS|unicast.censurfridns.dk
Wikimedia|wikimedia-dns.org
XboxDNS (RU)|xbox-dns.ru
Comss.one|dns.comss.one
Yandex|common.dot.dns.yandex.net
Geohide|dns.geohide.ru
'

UDP_LIST='
Google #1|8.8.4.4
Google #2|8.8.8.8
Cloudflare IP|1.1.1.1
Cloudflare IP 2|1.0.0.1
Quad9 #1|9.9.9.9
Quad9 #2|149.112.112.112
Quad9 (S)|9.9.9.11
Quad9 (UN)|9.9.9.10
Quad9 (UN2)|9.9.9.12
AdGuard #1|94.140.14.14
AdGuard #2|94.140.15.15
AdGuard (F)|94.140.14.15
AdGuard (UN)|94.140.14.140
Alibaba #1|223.5.5.5
Alibaba #2|223.6.6.6
CleanBrowsing #1|185.228.168.9
CleanBrowsing #2|185.228.169.9
ControlD #1|76.76.2.11
ControlD #2|76.76.10.11
DNS.SB #1|185.222.222.222
DNS.SB #2|45.11.45.11
DNS4all|194.0.5.3
dnsforge|176.9.93.198
NextDNS #1|45.90.28.0
NextDNS #2|45.90.30.0
OpenDNS #1|208.67.220.220
OpenDNS #2|208.67.222.222
XboxDNS (RU)|111.88.96.55
Comss.one #1|83.220.169.155
Comss.one #2|212.109.195.93
Yandex #1|77.88.8.1
Yandex #2|77.88.8.8
Geohide|45.155.204.190
MSK-IX #1|62.76.62.76
MSK-IX #2|62.76.76.62
НСДИ #1|195.208.4.1
НСДИ #2|195.208.5.1
'

# ---------- вспомогательные функции ----------

# переводит секунды (float, вывод curl) в целые миллисекунды
sec_to_ms() {
    awk -v t="$1" 'BEGIN{printf "%.0f", t*1000}'
}

# тест одного DoH-сервера: $1=имя $2=url
test_doh() {
    name="$1"; url="$2"
    printf '  %-18s %-55s ' "$name" "$url"
    if [ "$HAVE_CURL_DOH" != 1 ]; then
        echo "ПРОПУЩЕНО (нет curl --doh-url)"
        echo "DoH|$name|$url|SKIP|-" >> "$RESULTS_FILE"
        return
    fi
    t=$(curl -s -o /dev/null -w '%{time_namelookup}' --max-time "$TIMEOUT" \
        --doh-url "$url" -I "https://$TEST_DOMAIN" 2>/dev/null)
    rc=$?
    if [ $rc -eq 0 ] && [ -n "$t" ]; then
        ms=$(sec_to_ms "$t")
        echo "OK   ${ms} ms"
        echo "DoH|$name|$url|OK|$ms" >> "$RESULTS_FILE"
    else
        echo "FAIL (curl exit $rc)"
        echo "DoH|$name|$url|FAIL|-" >> "$RESULTS_FILE"
    fi
}

# тест одного DoT-сервера: $1=имя $2=host
test_dot() {
    name="$1"; host="$2"
    printf '  %-18s %-40s ' "$name" "$host"
    if [ "$HAVE_KDIG" != 1 ]; then
        echo "ПРОПУЩЕНО (нет kdig)"
        echo "DoT|$name|$host|SKIP|-" >> "$RESULTS_FILE"
        return
    fi
    out=$(kdig +tls +timeout="$TIMEOUT" +retry=0 -p 853 @"$host" "$TEST_DOMAIN" 2>&1)
    rc=$?
    ms=$(echo "$out" | grep -oE '[0-9]+\.?[0-9]* ms' | tail -n1 | awk '{printf "%.0f", $1}')
    if [ $rc -eq 0 ] && echo "$out" | grep -q "NOERROR"; then
        echo "OK   ${ms:-?} ms"
        echo "DoT|$name|$host|OK|${ms:-?}" >> "$RESULTS_FILE"
    else
        echo "FAIL (kdig exit $rc)"
        echo "DoT|$name|$host|FAIL|-" >> "$RESULTS_FILE"
    fi
}

# тест одного UDP-сервера: $1=имя $2=ip
test_udp() {
    name="$1"; ip="$2"
    printf '  %-18s %-40s ' "$name" "$ip"
    if [ "$HAVE_KDIG" != 1 ]; then
        echo "ПРОПУЩЕНО (нет kdig)"
        echo "UDP|$name|$ip|SKIP|-" >> "$RESULTS_FILE"
        return
    fi
    out=$(kdig +timeout="$TIMEOUT" +retry=0 @"$ip" "$TEST_DOMAIN" 2>&1)
    rc=$?
    ms=$(echo "$out" | grep -oE '[0-9]+\.?[0-9]* ms' | tail -n1 | awk '{printf "%.0f", $1}')
    if [ $rc -eq 0 ] && echo "$out" | grep -q "NOERROR"; then
        echo "OK   ${ms:-?} ms"
        echo "UDP|$name|$ip|OK|${ms:-?}" >> "$RESULTS_FILE"
    else
        echo "FAIL (kdig exit $rc)"
        echo "UDP|$name|$ip|FAIL|-" >> "$RESULTS_FILE"
    fi
}

# ---------- запуск тестов ----------

echo "--- DoH ---"
echo "$DOH_LIST" | while IFS='|' read -r name target; do
    [ -z "$name" ] && continue
    test_doh "$name" "$target"
done

echo
echo "--- DoT ---"
echo "$DOT_LIST" | while IFS='|' read -r name target; do
    [ -z "$name" ] && continue
    test_dot "$name" "$target"
done

echo
echo "--- UDP ---"
echo "$UDP_LIST" | while IFS='|' read -r name target; do
    [ -z "$name" ] && continue
    test_udp "$name" "$target"
done

# ---------- итоговая таблица ----------

echo
echo "=== ИТОГ ==="
for proto in DoH DoT UDP; do
    total=$(grep -c "^$proto|" "$RESULTS_FILE" 2>/dev/null || echo 0)
    ok=$(grep "^$proto|" "$RESULTS_FILE" 2>/dev/null | awk -F'|' '$4=="OK"' | wc -l)
    fail=$(grep "^$proto|" "$RESULTS_FILE" 2>/dev/null | awk -F'|' '$4=="FAIL"' | wc -l)
    skip=$(grep "^$proto|" "$RESULTS_FILE" 2>/dev/null | awk -F'|' '$4=="SKIP"' | wc -l)
    echo "$proto: всего $total, ок $ok, ошибка $fail, пропущено $skip"
done

echo
echo "--- Топ-10 самых быстрых рабочих серверов (все протоколы) ---"
awk -F'|' '$4=="OK"{printf "%s|%s|%s|%s\n",$5,$1,$2,$3}' "$RESULTS_FILE" \
    | sort -n -t'|' -k1,1 \
    | head -n 10 \
    | awk -F'|' '{printf "  %-5s мс  %-4s  %-18s %s\n",$1,$2,$3,$4}'

echo
echo "--- Полная таблица результатов ---"
printf '  %-4s %-18s %-45s %-6s %s\n' "ПРОТО" "ИМЯ" "АДРЕС" "СТАТУС" "МС"
awk -F'|' '{printf "  %-4s %-18s %-45s %-6s %s\n",$1,$2,$3,$4,$5}' "$RESULTS_FILE"

rm -f "$RESULTS_FILE"
