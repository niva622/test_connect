#!/bin/sh
# sni-check.sh — подбор рабочего SNI для VLESS (Reality/TLS) на конкретном сервере.
# Рассчитан на Entware + busybox ash (Keenetic). Нужен curl: opkg install curl ca-bundle
#
# Запуск с GitHub:
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/sni-check.sh | sh -s -- -s 1.2.3.4 -p 443
#
# Как работает: для каждого SNI открывается TLS 1.3 соединение на IP:порт вашего
# сервера с этим SNI в ClientHello. Если handshake дошёл до конца — оператор этот
# SNI пропускает. Таймаут обычно означает drop от DPI, reset — активный сброс.

VERSION="0.1"
SERVER="${SERVER:-}"
PORT="${PORT:-443}"
TIMEOUT="${TIMEOUT:-5}"
JOBS="${JOBS:-4}"
LIST_FILE=""
EXTRA=""
OUT_FILE="${OUT_FILE:-}"

usage() {
cat <<EOF
sni-check $VERSION — проверка SNI для VLESS на конкретном сервере

Использование: sh sni-check.sh -s SERVER [опции]

  -s SERVER   IP или домен вашего VLESS-сервера
  -p PORT     порт (по умолчанию 443)
  -t SEC      таймаут на одну проверку (по умолчанию 5)
  -j N        параллельных проверок (по умолчанию 4)
  -f FILE     свой список SNI (по одному в строке, # — комментарий)
  -e LIST     добавить SNI через запятую: -e a.com,b.com
  -o FILE     сохранить рабочие SNI в файл
  -h          эта справка

Переменные окружения: SERVER, PORT, TIMEOUT, JOBS, OUT_FILE.
EOF
}

# --- встроенный список кандидатов ---------------------------------------
builtin_list() {
cat <<'EOF'
# Международные (популярные для Reality, TLS 1.3 + h2)
www.microsoft.com
www.apple.com
www.cloudflare.com
www.google.com
dl.google.com
gateway.icloud.com
www.samsung.com
www.amazon.com
www.nvidia.com
www.oracle.com
www.cisco.com
www.intel.com
www.mozilla.org
www.bing.com
addons.mozilla.org
cdn.jsdelivr.net
www.github.com
www.speedtest.net
www.asus.com
www.logitech.com
# Российские (часто в «белых списках» операторов)
ya.ru
yandex.ru
dzen.ru
mail.ru
vk.com
ok.ru
rutube.ru
kinopoisk.ru
sberbank.ru
online.sberbank.ru
gosuslugi.ru
www.tbank.ru
2gis.ru
ozon.ru
wildberries.ru
avito.ru
rbc.ru
mts.ru
beeline.ru
megafon.ru
EOF
}

# --- аргументы ----------------------------------------------------------
while getopts "s:p:t:j:f:e:o:h" opt; do
  case "$opt" in
    s) SERVER="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    j) JOBS="$OPTARG" ;;
    f) LIST_FILE="$OPTARG" ;;
    e) EXTRA="$OPTARG" ;;
    o) OUT_FILE="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# --- проверки окружения -------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
  echo "Ошибка: не найден curl. Установите: opkg update && opkg install curl ca-bundle" >&2
  exit 1
fi

# При запуске через pipe stdin занят скриптом — спрашиваем через /dev/tty
if [ -z "$SERVER" ]; then
  if [ -r /dev/tty ]; then
    printf "IP или домен сервера: " >/dev/tty
    read -r SERVER </dev/tty
  fi
  [ -z "$SERVER" ] && { echo "Не указан сервер (-s)." >&2; usage; exit 1; }
fi

case "$PORT$TIMEOUT$JOBS" in
  *[!0-9]*) echo "Порт, таймаут и число потоков должны быть числами." >&2; exit 1 ;;
esac
[ "$JOBS" -lt 1 ] && JOBS=1

if [ -n "$LIST_FILE" ] && [ ! -r "$LIST_FILE" ]; then
  echo "Не могу прочитать файл списка: $LIST_FILE" >&2
  exit 1
fi

# --- рабочая директория -------------------------------------------------
BASE="${TMPDIR:-/opt/tmp}"
[ -d "$BASE" ] && [ -w "$BASE" ] || BASE="/tmp"
TMP="$(mktemp -d "$BASE/sni-check.XXXXXX" 2>/dev/null)" || { echo "Не удалось создать tmp-директорию" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- список SNI: нормализация и дедупликация ----------------------------
{
  if [ -n "$LIST_FILE" ]; then cat "$LIST_FILE"; else builtin_list; fi
  [ -n "$EXTRA" ] && echo "$EXTRA" | tr ',' '\n'
} | tr -d '\r' | sed 's/#.*//; s/[[:space:]]//g' | awk 'NF && !seen[$0]++' > "$TMP/list"

TOTAL="$(wc -l < "$TMP/list" | tr -d ' ')"
[ "$TOTAL" -eq 0 ] && { echo "Список SNI пуст." >&2; exit 1; }

# --- проверка одного SNI ------------------------------------------------
# Результат пишется в $TMP/res.N в формате: sni|STATUS|ms|curl_rc
check_one() {
  sni="$1"; idx="$2"
  t="$(curl -sk -o /dev/null --http1.1 --tlsv1.3 \
        --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
        --connect-to "$sni:$PORT:$SERVER:$PORT" \
        -w '%{time_appconnect}' "https://$sni:$PORT/" </dev/null 2>/dev/null)"
  rc=$?
  ms="$(echo "${t:-0}" | awk '{printf "%d", $1*1000}')"
  if [ "${ms:-0}" -gt 0 ]; then
    st="OK"
  else
    case "$rc" in
      28) st="TIMEOUT" ;;
      7)  st="NOCONNECT" ;;
      35|52|55|56) st="RESET" ;;
      *)  st="ERR" ;;
    esac
    ms=0
  fi
  echo "$sni|$st|$ms|$rc" > "$TMP/res.$idx"
}

echo "Сервер: $SERVER:$PORT | SNI: $TOTAL | таймаут: ${TIMEOUT}s | потоков: $JOBS"
echo "------------------------------------------------------------"

i=0; running=0
while IFS= read -r sni; do
  i=$((i+1))
  check_one "$sni" "$i" &
  running=$((running+1))
  if [ "$running" -ge "$JOBS" ]; then
    wait
    running=0
  fi
done < "$TMP/list"
wait

# --- вывод результатов в исходном порядке -------------------------------
n=1
: > "$TMP/ok"
while [ "$n" -le "$TOTAL" ]; do
  IFS='|' read -r sni st ms rc < "$TMP/res.$n"
  case "$st" in
    OK) printf "  [ OK ]     %-28s %5s ms\n" "$sni" "$ms"; echo "$sni|$ms" >> "$TMP/ok" ;;
    *)  printf "  [%-9s] %-28s (curl rc=%s)\n" "$st" "$sni" "$rc" ;;
  esac
  n=$((n+1))
done

OKN="$(wc -l < "$TMP/ok" | tr -d ' ')"
echo "------------------------------------------------------------"
echo "Рабочих SNI: $OKN из $TOTAL"

# Диагностика «всё плохо»
if [ "$OKN" -eq 0 ]; then
  CNT_NC="$(cat "$TMP"/res.* | awk -F'|' '$2=="NOCONNECT"' | wc -l | tr -d ' ')"
  CNT_TO="$(cat "$TMP"/res.* | awk -F'|' '$2=="TIMEOUT"' | wc -l | tr -d ' ')"
  if [ "$CNT_NC" -eq "$TOTAL" ]; then
    echo "Ни одного TCP-соединения: проверьте адрес/порт сервера и что он запущен."
  elif [ "$CNT_TO" -eq "$TOTAL" ]; then
    echo "Все таймауты: возможно, заблокирован IP/порт сервера целиком, а не SNI."
  else
    echo "Ни один SNI не прошёл. Проверьте, что на сервере TLS 1.3 (Reality) на этом порту."
  fi
  exit 2
fi

echo
echo "Топ по скорости handshake:"
sort -t'|' -k2 -n "$TMP/ok" | head -n 5 | awk -F'|' '{printf "  %-28s %s ms\n", $1, $2}'

BEST="$(sort -t'|' -k2 -n "$TMP/ok" | head -n 1 | cut -d'|' -f1)"
echo
echo "Подсказка для Reality: serverNames=[\"$BEST\"], dest=\"$BEST:443\""

if [ -n "$OUT_FILE" ]; then
  sort -t'|' -k2 -n "$TMP/ok" | cut -d'|' -f1 > "$OUT_FILE" && echo "Список рабочих SNI сохранён: $OUT_FILE"
fi
exit 0
