#!/bin/sh
# check-site.sh - проверка загрузки страницы (с ресурсами) через туннель.
# Для BusyBox/Entware. Нужен curl (opkg install curl), grep, sed, sort, tr.
#
# Использование:
#   sh check-site.sh [-i интерфейс] [-u URL] [-m макс_ресурсов] [-t таймаут] [-T]
#
#   -i  интерфейс туннеля (nwg0, tun0 ...). Без него идёт обычный маршрут роутера
#   -u  страница для проверки (по умолчанию https://web.telegram.org)
#   -m  максимум ресурсов (css/js/картинки) для загрузки (по умолчанию 30)
#   -t  таймаут соединения в секундах (по умолчанию 10)
#   -T  дополнительно проверить TCP/TLS до IP дата-центров Telegram
#
# Примеры:
#   sh check-site.sh -i nwg0
#   sh check-site.sh -i nwg0 -u https://example.com -T

IFACE=""
URL="https://web.telegram.org"
MAXRES=30
TMO=10
TGDC=0

usage() {
  sed -n '2,19p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
}

while getopts "i:u:m:t:Th" o; do
  case "$o" in
    i) IFACE=$OPTARG ;;
    u) URL=$OPTARG ;;
    m) MAXRES=$OPTARG ;;
    t) TMO=$OPTARG ;;
    T) TGDC=1 ;;
    *) usage; exit 2 ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "curl не найден. Установите: opkg install curl ca-certificates"
  exit 2
fi

CURL_IF=""
[ -n "$IFACE" ] && CURL_IF="--interface $IFACE"

TMP=/tmp/check-site.$$
mkdir -p "$TMP" || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM

# fetch URL OUTFILE -> печатает "код размер время"
fetch() {
  r=$(curl -4 -sSL $CURL_IF --connect-timeout "$TMO" --max-time $((TMO * 3)) \
        -o "$2" -w '%{http_code} %{size_download} %{time_total}' "$1" 2>/dev/null)
  [ -z "$r" ] && r="000 0 0"
  echo "$r"
}

ok_code() {
  case "$1" in
    2*|3*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "=== Проверка: $URL"
if [ -n "$IFACE" ]; then
  echo "=== Интерфейс: $IFACE"
else
  echo "=== Интерфейс: не задан (обычный маршрут роутера)"
fi
echo

# 1. Внешний IP
echo "--- Внешний IP"
ip_now=$(curl -4 -s $CURL_IF --connect-timeout "$TMO" --max-time 15 https://ifconfig.me 2>/dev/null)
ip_dir=$(curl -4 -s --connect-timeout "$TMO" --max-time 15 https://ifconfig.me 2>/dev/null)
echo "С выбранным маршрутом : ${ip_now:-НЕТ ОТВЕТА}"
echo "Обычный маршрут       : ${ip_dir:-НЕТ ОТВЕТА}"
if [ -n "$IFACE" ]; then
  if [ -z "$ip_now" ]; then
    echo "ВНИМАНИЕ: через $IFACE нет ответа. Проверьте имя интерфейса (ip a) и что туннель поднят."
  elif [ "$ip_now" = "$ip_dir" ]; then
    echo "ВНИМАНИЕ: IP совпадает с обычным маршрутом. Возможно, туннель не используется."
  else
    echo "IP отличается от обычного, запросы идут через $IFACE."
  fi
fi
echo

# 2. Главная страница
echo "--- Главная страница"
res=$(fetch "$URL" "$TMP/main.html")
code=${res%% *}
rest=${res#* }
size=${rest%% *}
tm=${rest#* }
echo "HTTP $code, ${size} байт, ${tm} c"

MAIN_OK=0
ok_code "$code" && MAIN_OK=1
echo

# 3. Ресурсы страницы
TOTAL=0
FAILED=0

if [ "$MAIN_OK" = 1 ] && [ -s "$TMP/main.html" ]; then
  origin=$(echo "$URL" | sed -E 's#^(https?://[^/]+).*#\1#')
  scheme=${URL%%://*}
  noq=${URL%%\?*}
  case "$noq" in
    */*/*/*) base=${noq%/*}/ ;;
    *) base=$origin/ ;;
  esac

  {
    tr "'" '"' < "$TMP/main.html" | grep -oE 'src="[^"]+"' | sed -E 's/^src="//; s/"$//'
    tr "'" '"' < "$TMP/main.html" | grep -oE 'href="[^"]+\.(css|js|ico|png|svg|jpg|jpeg|gif|webp|woff2?)([?][^"]*)?"' | sed -E 's/^href="//; s/"$//'
  } | grep -vE '^(data:|#|mailto:|javascript:)' | sort -u | head -n "$MAXRES" > "$TMP/list.txt"

  n=$(wc -l < "$TMP/list.txt" | tr -d ' ')
  echo "--- Ресурсы страницы (найдено: $n, лимит: $MAXRES)"

  while IFS= read -r r; do
    case "$r" in
      http://*|https://*) full=$r ;;
      //*) full="$scheme:$r" ;;
      /*) full="$origin$r" ;;
      *) full="$base$r" ;;
    esac
    TOTAL=$((TOTAL + 1))
    rr=$(fetch "$full" "$TMP/res.bin")
    rc=${rr%% *}
    rrest=${rr#* }
    rsz=${rrest%% *}
    rtm=${rrest#* }
    if ok_code "$rc"; then
      st="OK  "
    else
      st="FAIL"
      FAILED=$((FAILED + 1))
    fi
    echo "$st $rc ${rsz}Б ${rtm}c  $full"
  done < "$TMP/list.txt"
  echo
elif [ "$MAIN_OK" = 1 ]; then
  echo "--- Страница пустая, ресурсов нет"
  echo
fi

# 4. Дата-центры Telegram (по желанию)
TG_FAIL=0
if [ "$TGDC" = 1 ]; then
  echo "--- Telegram: доступность дата-центров по IP (как у приложения)"
  for ip in 149.154.167.51 149.154.175.53 149.154.167.91 149.154.175.100 91.108.56.130; do
    t=$(curl -4 -sk -o /dev/null $CURL_IF --connect-timeout 5 --max-time 10 \
          -w '%{time_connect}' "https://$ip" 2>/dev/null)
    if [ -n "$t" ] && [ "$t" != "0.000000" ] && [ "$t" != "0.000" ]; then
      echo "OK   $ip  соединение за ${t}c"
    else
      echo "FAIL $ip  нет соединения"
      TG_FAIL=$((TG_FAIL + 1))
    fi
  done
  echo
fi

# 5. Итог
echo "=== ИТОГ"
RC=0
if [ "$MAIN_OK" = 1 ]; then
  echo "Главная страница: ОТКРЫВАЕТСЯ (HTTP $code)"
else
  echo "Главная страница: НЕ ОТКРЫВАЕТСЯ (HTTP $code)"
  RC=1
fi
if [ "$TOTAL" -gt 0 ]; then
  echo "Ресурсы: загружено $((TOTAL - FAILED)) из $TOTAL"
  [ "$FAILED" -gt 0 ] && RC=1
fi
if [ "$TGDC" = 1 ]; then
  echo "Дата-центры Telegram: недоступно $TG_FAIL из 5"
  [ "$TG_FAIL" -gt 0 ] && RC=1
fi
exit $RC
