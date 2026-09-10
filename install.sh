#!/bin/sh
REPO="https://raw.githubusercontent.com/niva622/test_connect/main"
CONF=/opt/etc/sitemon.conf
NAME=""; SERVER=""; TOKEN=""; SITES=""; UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        -n) NAME="$2"; shift 2 ;;
        -s) SERVER="$2"; shift 2 ;;
        -t) TOKEN="$2"; shift 2 ;;
        -u) SITES="$2"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        *) echo "неизвестный параметр: $1"; exit 1 ;;
    esac
done

[ -d /opt/etc ] || { echo "Entware не найден (/opt/etc)"; exit 1; }

if [ "$UNINSTALL" = 1 ]; then
    [ -x /opt/etc/init.d/S99sitemon ] && /opt/etc/init.d/S99sitemon stop
    rm -f /opt/etc/init.d/S99sitemon /opt/bin/sitemon.sh /opt/var/log/sitemon.log
    echo "sitemon удален (конфиг $CONF оставлен)"
    exit 0
fi

if ! wget --version 2>/dev/null | grep -q "GNU Wget"; then
    echo "Устанавливаю wget-ssl..."
    opkg update >/dev/null && opkg install wget-ssl || { echo "не удалось установить wget-ssl"; exit 1; }
fi

[ -x /opt/etc/init.d/S99sitemon ] && /opt/etc/init.d/S99sitemon stop >/dev/null 2>&1

mkdir -p /opt/bin /opt/etc/init.d /opt/var/log /opt/var/run /opt/tmp

fetch() {
    wget -qO- "$REPO/$1" | tr -d '\r' > "$2"
    if [ ! -s "$2" ]; then
        echo "ошибка загрузки $1"
        exit 1
    fi
}

fetch sitemon.sh /opt/bin/sitemon.sh
fetch S99sitemon /opt/etc/init.d/S99sitemon
chmod +x /opt/bin/sitemon.sh /opt/etc/init.d/S99sitemon

sh -n /opt/bin/sitemon.sh || { echo "ошибка синтаксиса в sitemon.sh"; exit 1; }
sh -n /opt/etc/init.d/S99sitemon || { echo "ошибка синтаксиса в S99sitemon"; exit 1; }

if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<EOF
ROUTER_NAME="$(cat /proc/sys/kernel/hostname 2>/dev/null || echo router)"
SITES="https://ya.ru https://google.com"
SERVER_URL="http://127.0.0.1:8080/report"
TOKEN="changeme"
INTERVAL=3600
RETRY_DELAY=300
MAX_ATTEMPTS=3
SEND_ATTEMPTS=2
HTTP_TIMEOUT=30
EOF
fi

setconf() {
    if grep -q "^$1=" "$CONF"; then
        sed -i "s#^$1=.*#$1=\"$2\"#" "$CONF"
    else
        echo "$1=\"$2\"" >> "$CONF"
    fi
}
[ -n "$NAME" ]   && setconf ROUTER_NAME "$NAME"
[ -n "$SERVER" ] && setconf SERVER_URL "$SERVER"
[ -n "$TOKEN" ]  && setconf TOKEN "$TOKEN"
[ -n "$SITES" ]  && setconf SITES "$SITES"

/opt/etc/init.d/S99sitemon start
echo "Готово. Конфиг: $CONF   Лог: /opt/var/log/sitemon.log"
