#!/bin/sh
# =========================================================
#  check-dns-resolvers.sh
#  Проверка DoT/DoH DNS-резолверов на роутере (Entware/BusyBox)
#  Пинг + доступность портов 853 (DoT) / 443 (DoH) + тестовый DoH-запрос
#  Совместим с BusyBox ash, зависимостей от bash нет.
# =========================================================

# ---------- Настройки по умолчанию (можно менять здесь) ----------

domains_data='youtube.com
rutor.org'

# Формат: Имя|IP|DoH-хост   (если DoH-хоста нет — ставим "-")
resolvers_data='Cloudflare|1.1.1.1|cloudflare-dns.com
Google|8.8.8.8|dns.google
Quad9|9.9.9.9|dns.quad9.net
AdGuard|94.140.14.14|dns.adguard-dns.com
OpenDNS|208.67.222.222|doh.opendns.com
CleanBrowsing|185.228.168.9|security-filter-dns.cleanbrowsing.org
Yandex|77.88.8.8|common.dot.dns.yandex.net
Comodo Secure|8.26.56.26|-'

PING_COUNT=2
PING_TIMEOUT=2      # сек, ожидание ответа на ping (-W)
NC_TIMEOUT=3         # сек, таймаут проверки TCP-портов
CURL_TIMEOUT=5       # сек, таймаут DoH-запросов
CURL_INSECURE=""     # добавьте -k флагом, если нет ca-bundle

# ---------- Цвета (отключаются, если вывод не в терминал, напр. в лог) ----------

if [ -t 1 ]; then
    C_RED=$(printf '\033[31m')
    C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m')
    C_CYAN=$(printf '\033[36m')
    C_MAGENTA=$(printf '\033[35m')
    C_GRAY=$(printf '\033[90m')
    C_NC=$(printf '\033[0m')
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_MAGENTA=""; C_GRAY=""; C_NC=""
fi

# ---------- Разбор аргументов ----------

usage() {
    cat <<EOF
Использование: $0 [опции]

  -d "domain1,domain2"   Список доменов через запятую
                         (по умолчанию: youtube.com,rutor.org)
  -c N                   Количество ping-пакетов (по умолчанию: $PING_COUNT)
  -w N                   Таймаут ожидания ping, сек (по умолчанию: $PING_TIMEOUT)
  -n N                   Таймаут проверки TCP-портов через nc, сек (по умолчанию: $NC_TIMEOUT)
  -T N                   Таймаут curl-запросов DoH, сек (по умолчанию: $CURL_TIMEOUT)
  -k                     Отключить проверку TLS-сертификата в curl (curl -k)
  -h                     Показать эту справку
EOF
}

while getopts "d:c:w:n:T:kh" opt; do
    case "$opt" in
        d) domains_data=$(printf '%s' "$OPTARG" | tr ',' '\n') ;;
        c) PING_COUNT="$OPTARG" ;;
        w) PING_TIMEOUT="$OPTARG" ;;
        n) NC_TIMEOUT="$OPTARG" ;;
        T) CURL_TIMEOUT="$OPTARG" ;;
        k) CURL_INSECURE="-k" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# ---------- Проверка наличия утилит ----------

missing=""
for tool in curl nslookup ping; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    printf "%s\n" "${C_RED}Внимание: не найдены утилиты:$missing${C_NC}"
    printf "%s\n" "Установите их, например: opkg update && opkg install curl ca-bundle"
fi
if ! command -v nc >/dev/null 2>&1; then
    printf "%s\n" "${C_YELLOW}Утилита nc не найдена — проверка портов 853/443 будет пропущена. Установите: opkg install netcat${C_NC}"
fi

# ---------- Вспомогательные функции ----------

check_port() {
    ip="$1"
    port="$2"
    if command -v nc >/dev/null 2>&1; then
        if nc -w "$NC_TIMEOUT" "$ip" "$port" </dev/null >/dev/null 2>&1; then
            printf "    %s\n" "${C_GREEN}Открыт${C_NC}"
        else
            printf "    %s\n" "${C_RED}Недоступен${C_NC}"
        fi
    else
        printf "    %s\n" "${C_GRAY}nc не установлен — пропущено${C_NC}"
    fi
}

# =========================================================
#  Блок 0: обычный DNS (порт 53, UDP) — "стоковые" запросы
# =========================================================

printf "%s\n" "${C_CYAN}==================================================${C_NC}"
printf "%s\n" "${C_CYAN} Обычный DNS (порт 53) через стоковые резолверы${C_NC}"
printf "%s\n" "${C_CYAN}==================================================${C_NC}"

printf "%s\n" "$domains_data" | while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    printf "\n%s\n" "${C_MAGENTA}### Домен: $domain ###${C_NC}"

    printf "%s\n" "$resolvers_data" | while IFS='|' read -r rname rip rdoh; do
        [ -z "$rname" ] && continue
        printf "  %s (%s):\n" "$rname" "$rip"

        result=$(nslookup "$domain" "$rip" 2>&1)
        ips=$(printf "%s\n" "$result" | awk '/^Name:/{f=1;next} f && /^Address/{print $NF}' | tr '\n' ',' | sed 's/,$//')

        if [ -n "$ips" ]; then
            printf "    %s\n" "${C_GREEN}Резолвится: $ips${C_NC}"
        elif printf "%s" "$result" | grep -qiE "can't find|NXDOMAIN|SERVFAIL|REFUSED|timed out|no servers"; then
            printf "    %s\n" "${C_RED}Не резолвится / ошибка${C_NC}"
        else
            printf "    %s\n" "${C_YELLOW}Ответ получен, но A-записей нет${C_NC}"
        fi
    done
done

printf "\n"
printf "%s\n" "${C_CYAN}==================================================${C_NC}"
printf "%s\n" "${C_CYAN} Проверка DoT/DoH резолверов (пинг, порты, DoH-запросы)${C_NC}"
printf "%s\n" "${C_CYAN}==================================================${C_NC}"

printf "%s\n" "$resolvers_data" | while IFS='|' read -r rname rip rdoh; do
    [ -z "$rname" ] && continue

    printf "\n%s\n" "${C_CYAN}----- $rname ($rip) -----${C_NC}"

    # 1. Пинг (ICMP)
    printf "[1] Ping:\n"
    if command -v ping >/dev/null 2>&1; then
        ping_out=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$rip" 2>/dev/null)
        rtt_line=$(printf "%s\n" "$ping_out" | grep -E "min/avg/max|round-trip")
        if [ -n "$rtt_line" ]; then
            avg=$(printf "%s\n" "$rtt_line" | sed -E 's#.*= *[0-9.]+/([0-9.]+)/.*#\1#')
            printf "    %s\n" "${C_GREEN}OK, средний RTT: ${avg} ms${C_NC}"
        else
            printf "    %s\n" "${C_YELLOW}Нет ответа на ICMP (может быть заблокирован файрволом)${C_NC}"
        fi
    else
        printf "    %s\n" "${C_GRAY}ping не установлен — пропущено${C_NC}"
    fi

    # 2. Порт 853 (DoT)
    printf "[2] DoT порт 853:\n"
    check_port "$rip" 853

    # 3. Порт 443 (DoH / HTTPS)
    printf "[3] DoH порт 443:\n"
    check_port "$rip" 443

    # 4. Реальный DoH-запрос для каждого домена (если у резолвера есть DoH-хост)
    if [ -n "$rdoh" ] && [ "$rdoh" != "-" ]; then
        printf "[4] DoH-запросы (%s):\n" "$rdoh"
        printf "%s\n" "$domains_data" | while IFS= read -r domain; do
            [ -z "$domain" ] && continue
            printf "    Домен: %s\n" "$domain"

            if ! command -v curl >/dev/null 2>&1; then
                printf "      %s\n" "${C_GRAY}curl не установлен — пропущено${C_NC}"
                continue
            fi

            resp=$(curl -s $CURL_INSECURE --max-time "$CURL_TIMEOUT" \
                -H "accept: application/dns-json" \
                "https://$rdoh/dns-query?name=$domain&type=A" 2>&1)

            if [ -z "$resp" ]; then
                printf "      %s\n" "${C_RED}Ошибка запроса: нет ответа / нет соединения${C_NC}"
                continue
            fi

            ips=$(printf "%s" "$resp" | grep -o '"data":"[^"]*"' | sed 's/"data":"//;s/"$//' | tr '\n' ',' | sed 's/,$//')
            if [ -n "$ips" ]; then
                printf "      %s\n" "${C_GREEN}Резолвится: $ips${C_NC}"
            else
                printf "      %s\n" "${C_YELLOW}Ответ получен, но записей A нет${C_NC}"
            fi
        done
    else
        printf "[4] %s\n" "${C_GRAY}DoH: не поддерживается этим резолвером — пропущено${C_NC}"
    fi
done

printf "\n"
printf "%s\n" "${C_CYAN}==================================================${C_NC}"
printf "%s\n" "${C_CYAN} Готово${C_NC}"
printf "%s\n" "${C_CYAN}==================================================${C_NC}"
