#!/bin/sh
# sni-fp-check.sh — этап 2: перебор пар SNI × fingerprint через реальный xray (VLESS Reality, tcp/xhttp).
# Для Entware + busybox ash. Нужны: xray, curl.
#
# Запуск:
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/sni-fp-check.sh | \
#     sh -s -- -u 'vless://UUID@IP:443?type=tcp&security=reality&pbk=...&sid=...&flow=xtls-rprx-vision#name' \
#              -f /opt/tmp/sni-ok.txt
#
# ВАЖНО: все проверяемые SNI должны быть в serverNames Reality на СЕРВЕРЕ,
# иначе сервер отклонит их независимо от оператора.

VERSION="0.1"
VLESS_URL="${VLESS_URL:-}"
LIST_FILE=""
FPS="${FPS:-chrome,firefox,safari,ios,android,edge,random}"
TIMEOUT="${TIMEOUT:-8}"
JOBS="${JOBS:-2}"
BASE_PORT="${BASE_PORT:-10800}"
TEST_URL="${TEST_URL:-http://cp.cloudflare.com/generate_204}"
XRAY_BIN="${XRAY_BIN:-}"
OUT_FILE="${OUT_FILE:-}"
EXTRA=""
DRY=0
VERBOSE=0

usage() {
cat <<EOF
sni-fp-check $VERSION — перебор SNI × fingerprint через xray (VLESS Reality, tcp/xhttp)

  -u URL      ссылка vless://... (или переменная VLESS_URL)
  -f FILE     файл со списком SNI (например из sni-check.sh -o)
  -e LIST     дополнительные SNI через запятую
  -F LIST     fingerprints через запятую (по умолчанию: $FPS)
  -t SEC      таймаут на одну пару (по умолчанию $TIMEOUT)
  -j N        параллельных xray (по умолчанию $JOBS; на слабом роутере держите 1-2)
  -P PORT     базовый локальный порт для socks (по умолчанию $BASE_PORT)
  -U URL      URL для проверки через прокси (по умолчанию $TEST_URL)
  -x PATH     путь к xray (по умолчанию ищется в PATH и /opt/sbin)
  -o FILE     сохранить рабочие пары "sni fp" в файл
  -n          только показать сгенерированный конфиг и выйти
  -v          показывать хвост лога xray для неудачных пар
  -h          справка
EOF
}

while getopts "u:f:e:F:t:j:P:U:x:o:nvh" opt; do
  case "$opt" in
    u) VLESS_URL="$OPTARG" ;;
    f) LIST_FILE="$OPTARG" ;;
    e) EXTRA="$OPTARG" ;;
    F) FPS="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    j) JOBS="$OPTARG" ;;
    P) BASE_PORT="$OPTARG" ;;
    U) TEST_URL="$OPTARG" ;;
    x) XRAY_BIN="$OPTARG" ;;
    o) OUT_FILE="$OPTARG" ;;
    n) DRY=1 ;;
    v) VERBOSE=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# --- окружение ----------------------------------------------------------
if ! curl --version >/dev/null 2>&1; then
  echo "Ошибка: curl не работает. Попробуйте: opkg update && opkg upgrade curl libcurl (или /opt/bin/curl)." >&2
  exit 1
fi

if [ -z "$XRAY_BIN" ]; then
  for c in xray /opt/sbin/xray /opt/bin/xray; do
    if command -v "$c" >/dev/null 2>&1; then XRAY_BIN="$c"; break; fi
  done
fi
[ -z "$XRAY_BIN" ] && { echo "Не найден xray. Укажите путь: -x /opt/sbin/xray" >&2; exit 1; }

if [ -z "$VLESS_URL" ] && [ -r /dev/tty ]; then
  printf "Ссылка vless://...: " >/dev/tty
  read -r VLESS_URL </dev/tty
fi
[ -z "$VLESS_URL" ] && { echo "Не указана ссылка vless:// (-u)." >&2; usage; exit 1; }

case "$VLESS_URL" in vless://*) ;; *) echo "Ссылка должна начинаться с vless://" >&2; exit 1 ;; esac
case "$TIMEOUT$JOBS$BASE_PORT" in *[!0-9]*) echo "-t, -j, -P должны быть числами." >&2; exit 1 ;; esac
[ "$JOBS" -lt 1 ] && JOBS=1

# --- разбор vless:// ----------------------------------------------------
u="${VLESS_URL#vless://}"
u="${u%%#*}"
UUID="${u%%@*}"
rest="${u#*@}"
hostport="${rest%%\?*}"
QUERY="${rest#*\?}"
[ "$QUERY" = "$rest" ] && QUERY=""
HOST="${hostport%:*}"
SPORT="${hostport##*:}"
HOST="${HOST#[}"; HOST="${HOST%]}"

urldecode() {
  sed 's/%22/"/g; s/%7[Bb]/{/g; s/%7[Dd]/}/g; s/%3[Aa]/:/g; s/%2[Cc]/,/g; s/%2[Ff]/\//g; s/%5[Bb]/[/g; s/%5[Dd]/]/g; s/%20/ /g'
}

getp() {
  echo "$QUERY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1 | urldecode
}

SEC="$(getp security)"
NET="$(getp type)"; [ -z "$NET" ] && NET="tcp"
PBK="$(getp pbk)"
SID="$(getp sid)"
FLOW="$(getp flow)"
SPX="$(getp spx)"; [ -z "$SPX" ] && SPX="/"
ENC="$(getp encryption)"; [ -z "$ENC" ] && ENC="none"

# XHTTP-параметры
XPATH="$(getp path)"; [ -z "$XPATH" ] && XPATH="/"
XHOST="$(getp host)"
XMODE="$(getp mode)"; [ -z "$XMODE" ] && XMODE="auto"
XEXTRA="$(getp extra)"
XPAD="$(getp x_padding_bytes)"
if [ -z "$XEXTRA" ] && [ -n "$XPAD" ]; then
  XEXTRA="{\"xPaddingBytes\":\"$XPAD\"}"
fi

[ "$SEC" != "reality" ] && { echo "Поддерживается только security=reality (в ссылке: '$SEC')." >&2; exit 1; }
case "$NET" in
  tcp|xhttp) ;;
  *) echo "Поддерживаются type=tcp и type=xhttp (в ссылке: '$NET')." >&2; exit 1 ;;
esac
[ -z "$PBK" ] && { echo "В ссылке нет pbk (public key)." >&2; exit 1; }
if [ -z "$UUID" ] || [ -z "$HOST" ] || [ -z "$SPORT" ]; then
  echo "Не удалось разобрать uuid/host/port. В ссылке должен быть UUID: vless://UUID@host:port?..." >&2
  exit 1
fi

# --- рабочая директория -------------------------------------------------
BASE="${TMPDIR:-/opt/tmp}"
[ -d "$BASE" ] && [ -w "$BASE" ] || BASE="/tmp"
TMP="$(mktemp -d "$BASE/sni-fp.XXXXXX" 2>/dev/null)" || { echo "Не удалось создать tmp" >&2; exit 1; }

cleanup() {
  for f in "$TMP"/pid.*; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# --- конфиг xray --------------------------------------------------------
gen_config() { # sni fp port
  loglevel="none"; [ "$VERBOSE" -eq 1 ] && loglevel="warning"
  xh=""
  if [ "$NET" = "xhttp" ]; then
    xh=", \"xhttpSettings\": { \"path\": \"$XPATH\", \"mode\": \"$XMODE\""
    [ -n "$XHOST" ] && xh="$xh, \"host\": \"$XHOST\""
    [ -n "$XEXTRA" ] && xh="$xh, \"extra\": $XEXTRA"
    xh="$xh }"
  fi
  cat <<EOF
{
  "log": { "loglevel": "$loglevel" },
  "inbounds": [{
    "listen": "127.0.0.1", "port": $3, "protocol": "socks",
    "settings": { "udp": false }
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": { "vnext": [{
      "address": "$HOST", "port": $SPORT,
      "users": [{ "id": "$UUID", "encryption": "$ENC", "flow": "$FLOW" }]
    }]},
    "streamSettings": {
      "network": "$NET", "security": "reality",
      "realitySettings": {
        "serverName": "$1", "fingerprint": "$2",
        "publicKey": "$PBK", "shortId": "$SID", "spiderX": "$SPX"
      }$xh
    }
  }]
}
EOF
}

# --- список SNI ---------------------------------------------------------
if [ -z "$LIST_FILE" ] && [ -z "$EXTRA" ]; then
  [ -r /opt/tmp/sni-ok.txt ] && LIST_FILE="/opt/tmp/sni-ok.txt"
fi
if [ -n "$LIST_FILE" ] && [ ! -r "$LIST_FILE" ]; then
  echo "Не могу прочитать список: $LIST_FILE" >&2; exit 1
fi
{
  [ -n "$LIST_FILE" ] && cat "$LIST_FILE"
  [ -n "$EXTRA" ] && echo "$EXTRA" | tr ',' '\n'
} | tr -d '\r' | sed 's/#.*//; s/[[:space:]]//g' | awk 'NF && !seen[$0]++' > "$TMP/snis"
[ -s "$TMP/snis" ] || { echo "Нет SNI: укажите -f FILE или -e a.com,b.com (или сначала запустите sni-check.sh -o /opt/tmp/sni-ok.txt)." >&2; exit 1; }

echo "$FPS" | tr ',' '\n' | sed 's/[[:space:]]//g' | awk 'NF' > "$TMP/fps"

# пары sni|fp
: > "$TMP/pairs"
while IFS= read -r s; do
  while IFS= read -r f; do echo "$s|$f" >> "$TMP/pairs"; done < "$TMP/fps"
done < "$TMP/snis"
TOTAL="$(wc -l < "$TMP/pairs" | tr -d ' ')"

if [ "$DRY" -eq 1 ]; then
  s1="$(head -n 1 "$TMP/snis")"; f1="$(head -n 1 "$TMP/fps")"
  echo "# xray: $XRAY_BIN | server: $HOST:$SPORT | transport: $NET | flow: '$FLOW' | пар: $TOTAL"
  gen_config "$s1" "$f1" "$BASE_PORT"
  exit 0
fi

# --- проверка одной пары ------------------------------------------------
check_pair() { # sni fp idx
  sni="$1"; fp="$2"; idx="$3"
  port=$((BASE_PORT + idx))
  cfg="$TMP/cfg.$idx.json"
  log="$TMP/xray.$idx.log"
  gen_config "$sni" "$fp" "$port" > "$cfg"

  "$XRAY_BIN" run -c "$cfg" >"$log" 2>&1 &
  xp=$!
  echo "$xp" > "$TMP/pid.$idx"

  out=""; rc=7; tries=0
  while [ "$rc" -eq 7 ] && [ "$tries" -lt 4 ]; do
    sleep 1
    out="$(curl -s -o /dev/null --socks5-hostname "127.0.0.1:$port" \
          --max-time "$TIMEOUT" -w '%{http_code} %{time_total}' "$TEST_URL" </dev/null 2>/dev/null)"
    rc=$?
    tries=$((tries+1))
  done

  kill "$xp" 2>/dev/null
  wait "$xp" 2>/dev/null
  rm -f "$TMP/pid.$idx"

  code="${out%% *}"
  tt="${out#* }"
  case "$code" in
    2??|3??) st="OK" ;;
    *)
      case "$rc" in 28) st="TIMEOUT" ;; 7) st="NOSTART" ;; *) st="FAIL" ;; esac
      ;;
  esac
  ms="$(echo "${tt:-0}" | awk '{printf "%d", $1*1000}')"
  [ "$st" != "OK" ] && ms=0
  echo "$sni|$fp|$st|$ms|$rc" > "$TMP/res.$idx"
}

echo "xray: $XRAY_BIN | сервер: $HOST:$SPORT | транспорт: $NET | flow: '${FLOW:-none}'"
echo "SNI: $(wc -l < "$TMP/snis" | tr -d ' ') × fp: $(wc -l < "$TMP/fps" | tr -d ' ') = пар: $TOTAL | потоков: $JOBS | таймаут: ${TIMEOUT}s"
echo "------------------------------------------------------------"

i=0; running=0
while IFS='|' read -r sni fp; do
  i=$((i+1))
  check_pair "$sni" "$fp" "$i" &
  running=$((running+1))
  if [ "$running" -ge "$JOBS" ]; then
    wait
    running=0
    printf "  проверено %s/%s\r" "$i" "$TOTAL"
  fi
done < "$TMP/pairs"
wait
printf "                              \r"

# --- результаты ---------------------------------------------------------
n=1
: > "$TMP/all"
while [ "$n" -le "$TOTAL" ]; do
  cat "$TMP/res.$n" >> "$TMP/all"
  IFS='|' read -r sni fp st ms rc < "$TMP/res.$n"
  if [ "$st" = "OK" ]; then
    printf "  [ OK ]      %-26s %-9s %5s ms\n" "$sni" "$fp" "$ms"
  else
    printf "  [%-9s] %-26s %-9s\n" "$st" "$sni" "$fp"
    if [ "$VERBOSE" -eq 1 ] && [ -s "$TMP/xray.$n.log" ]; then
      tail -n 2 "$TMP/xray.$n.log" | sed 's/^/        xray: /'
    fi
  fi
  n=$((n+1))
done

echo "------------------------------------------------------------"
echo "Матрица (мс до ответа, '-' = не прошло):"
awk -F'|' -v fps="$FPS" '
BEGIN { n = split(fps, F, ",") }
{ if (!($1 in seen)) { seen[$1] = 1; order[++c] = $1 }
  r[$1, $2] = ($3 == "OK") ? $4 : "-" }
END {
  printf "%-26s", "SNI"; for (i = 1; i <= n; i++) printf "%-9s", F[i]; print ""
  for (k = 1; k <= c; k++) { s = order[k]; printf "%-26s", s
    for (i = 1; i <= n; i++) { v = r[s, F[i]]; printf "%-9s", (v == "" || v == "-") ? "-" : v }
    print "" }
}' "$TMP/all"

awk -F'|' '$3=="OK"{print $4"|"$1"|"$2}' "$TMP/all" | sort -n > "$TMP/ok"
OKN="$(wc -l < "$TMP/ok" | tr -d ' ')"
echo
echo "Рабочих пар: $OKN из $TOTAL"

if [ "$OKN" -eq 0 ]; then
  echo "Ничего не прошло. Проверьте: SNI есть в serverNames на сервере, pbk/sid/flow верны,"
  echo "xray стартует (запустите с -v и -j 1), порт $BASE_PORT+ свободен."
  exit 2
fi

echo "Лучшие:"
head -n 5 "$TMP/ok" | awk -F'|' '{printf "  sni=%-26s fp=%-9s %s ms\n", $2, $3, $1}'

if [ -n "$OUT_FILE" ]; then
  awk -F'|' '{print $2" "$3}' "$TMP/ok" > "$OUT_FILE" && echo "Сохранено: $OUT_FILE"
fi
exit 0
