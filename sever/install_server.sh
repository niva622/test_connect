#!/bin/sh
REPO="https://raw.githubusercontent.com/niva622/test_connect/main/server"
TOKEN=""; PORT=8080
while [ $# -gt 0 ]; do
    case "$1" in
        -t) TOKEN="$2"; shift 2 ;;
        -p) PORT="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$TOKEN" ] || { echo "ukazhite token: -t SEKRET"; exit 1; }

apt-get install -y python3 >/dev/null 2>&1
id sitemon >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin sitemon
mkdir -p /opt/sitemon /var/lib/sitemon

fetch() {
    wget -qO- "$1" | tr -d '\r' > "$2"
    if [ ! -s "$2" ]; then
        echo "oshibka zagruzki $1"
        exit 1
    fi
}

fetch "$REPO/sitemon_server.py" /opt/sitemon/sitemon_server.py
fetch "$REPO/sitemon-server.service" /etc/systemd/system/sitemon-server.service
chown -R sitemon:sitemon /var/lib/sitemon

cat > /etc/sitemon.env <<EOF
TOKEN=$TOKEN
PORT=$PORT
STATE_FILE=/var/lib/sitemon/state.json
STALE_SEC=9000
EOF
chmod 600 /etc/sitemon.env

systemctl daemon-reload
systemctl unmask sitemon-server 2>/dev/null
systemctl enable --now sitemon-server
systemctl restart sitemon-server
echo "Server zapushen: http://$(hostname -I | awk '{print $1}'):$PORT/"
