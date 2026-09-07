#!/bin/sh
# sitemon - монитор доступности сайтов для Keenetic/Entware
# Требует только busybox + GNU wget (wget-ssl ставится вместе с Entware)

CONF=/opt/etc/sitemon.conf
PIDFILE=/opt/var/run/sitemon.pid
LOG=/opt/var/log/sitemon.log
TMPDIR=/opt/tmp/sitemon.$$
LOG_MAX=204800          # 200 КБ, дальше обрезаем

# --- значения по умолчанию (переопределяются в sitemon.conf) ---
ROUTER_NAME="$(cat /proc/sys/kernel/hostname 2>/dev/null || echo router)"
SITES="https://ya.ru https://google.com"
SERVER_URL="http://127.0.0.1:8080/report"
TOKEN="changeme"
INTERVAL=3600           # период проверки, сек
RETRY_DELAY=300         # пауза перед повторной проверкой, сек
MAX_ATTEMPTS=3          # 1 проверка + 2 повтора
SEND_ATTEMPTS=2         # попыток отправки на VPS
SEND_RETRY_DELAY=30     # пауза между попытками отправки
HTTP_TIMEOUT=30         # таймаут wget, сек
QUOTA=10m               # лимит скачивания при полной загрузке

SLEEP_PID=""

load_conf() { [ -f "$CONF" ] && . "$CONF"; }

log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    # ротация: не даём логу расти бесконечно
    if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ]; then
        tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi
}

# миллисекунды из /proc/uptime ("12345.67 ...")
now_ms() {
    local up rest
    read up rest < /proc/uptime
    echo "${up%.*}${up#*.}0"
}

# прерываемый sleep (чтобы stop срабатывал сразу)
nap() {
    sleep "$1" &
    SLEEP_PID=$!
    wait $SLEEP_PID 2>/dev/null
    SLEEP_PID=""
}

# url-encode любых байт (UTF-8 в имени роутера — не проблема)
urlenc() {

cleanup() {
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
    rm -rf "$TMPDIR"
    rm -f "$PIDFILE"
    log "остановлен"
    exit 0
}
trap cleanup TERM INT

# Проверка одного сайта. Выводит: STATUS|open_ms|full_ms
check_site() {
    local url="$1" t0 t1 status=FAIL open=0 full=0

    t0=$(now_ms)
    if wget -q -O /dev/null -T "$HTTP_TIMEOUT" -t 1 --no-check-certificate "$url" 2>/dev/null; then
        t1=$(now_ms)
        open=$((t1 - t0))
        status=OK

        rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
        t0=$(now_ms)
        # -p: страница со всеми ресурсами, -H: в т.ч. с CDN, -Q: лимит объёма
        wget -q -p -H -nd -e robots=off -Q "$QUOTA" -P "$TMPDIR" \
             -T "$HTTP_TIMEOUT" -t 1 --no-check-certificate "$url" >/dev/null 2>&1
        t1=$(now_ms)
        full=$((t1 - t0))
        rm -rf "$TMPDIR"
    fi
    echo "$status|$open|$full"
}

# Отправка отчёта. $1 = данные, $2 = номер попытки проверки
send_report() {
    local body
    body="token=$(urlenc "$TOKEN")&name=$(urlenc "$ROUTER_NAME")&attempt=$2&data=$(urlenc "$1")"
    wget -q -O /dev/null -T 20 -t 1 --no-check-certificate \
         --post-data="$body" "$SERVER_URL" 2>/dev/null
}

# ----------------------------------------------------------------
mkdir -p "$(dirname "$PIDFILE")" /opt/tmp 2>/dev/null
echo $$ > "$PIDFILE"
load_conf
log "запущен: name=$ROUTER_NAME sites=[$SITES] server=$SERVER_URL"

while :; do
    load_conf   # изменения в конфиге подхватываются без рестарта

    # --- фаза проверки (до MAX_ATTEMPTS раз) ---
    attempt=1
    while :; do
        RESULTS=""; ALL_OK=1
        for url in $SITES; do
            r=$(check_site "$url")
            case "$r" in FAIL*) ALL_OK=0 ;; esac
            RESULTS="${RESULTS}${RESULTS:+;}${url}|${r}"
        done
        log "проверка #$attempt: $RESULTS"

        [ "$ALL_OK" = 1 ] && break
        [ "$attempt" -ge "$MAX_ATTEMPTS" ] && break
        attempt=$((attempt + 1))
        nap "$RETRY_DELAY"
    done

    # --- фаза отправки (до SEND_ATTEMPTS раз) ---
    sent=0; s=1
    while [ "$s" -le "$SEND_ATTEMPTS" ]; do
        if send_report "$RESULTS" "$attempt"; then
            sent=1; break
        fi
        log "отправка на сервер не удалась (попытка $s)"
        s=$((s + 1))
        [ "$s" -le "$SEND_ATTEMPTS" ] && nap "$SEND_RETRY_DELAY"
    done

    if [ "$sent" = 1 ]; then
        nap "$INTERVAL"
    else
        log "сервер недоступен, цикл начнётся заново через $RETRY_DELAY с"
        nap "$RETRY_DELAY"
    fi
done
