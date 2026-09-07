#!/bin/sh
# На VPS (от root):
#   wget -qO- https://raw.githubusercontent.com/USER/REPO/main/server/install_server.sh | sh -s -- -t СЕКРЕТ [-p 8080]
REPO="https://raw.githubusercontent.com/niva622/test_connect/main"
TOKEN=""; PORT=8080
while [ $# -gt 0 ]; do
    case "$1" in
        -t) TOKEN="$2"; shift 2 ;;
        -p) PORT="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$TOKEN" ] || { echo "укажите токен: -t СЕКРЕТ"; exit 1; }

apt-get install -y python3 >/dev/null 2>&1
id sitemon >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin sitemon
mkdir -p /opt/sitemon /var/lib/sitemon
wget -qO /opt/sitemon/sitemon_server.py "$REPO/sitemon_server.py"
wget -qO /etc/systemd/system/sitemon-server.service "$REPO/sitemon-server.service"
chown -R sitemon:sitemon /var/lib/sitemon

cat > /etc/sitemon.env <<EOF
TOKEN=$TOKEN
PORT=$PORT
STATE_FILE=/var/lib/sitemon/state.json
STALE_SEC=9000
EOF
chmod 600 /etc/sitemon.env

systemctl daemon-reload
systemctl enable --now sitemon-server
systemctl restart sitemon-server
echo "Сервер запущен: http://$(hostname -I | awk '{print $1}'):$PORT/"
