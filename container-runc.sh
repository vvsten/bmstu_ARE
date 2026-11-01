#!/bin/bash
set -e

CONTAINER_NAME="alpine-fastapi"
NETNS="container-net"
VETH_HOST="veth0"
VETH_CONT="veth1"
HOST_IP="10.0.0.1"
CONTAINER_IP="10.0.0.2"
ALPINE_VERSION="3.20"
MEMORY_LIMIT=1073741824
CPU_QUOTA=50000
CPU_PERIOD=100000

BASE_DIR=$(mktemp -d /tmp/runc-container.XXXXXX)
BUNDLE_DIR="$BASE_DIR/bundle"
LOWER_DIR="$BASE_DIR/lower"
UPPER_DIR="$BASE_DIR/upper"
WORK_DIR="$BASE_DIR/work"
MERGED_DIR="$BUNDLE_DIR/rootfs"
STATE_DIR="$BASE_DIR/state"
MINIROOTFS_TGZ="$BASE_DIR/minirootfs.tar.gz"
mkdir -p "$LOWER_DIR" "$UPPER_DIR" "$WORK_DIR" "$MERGED_DIR" "$STATE_DIR" "$BUNDLE_DIR"

cleanup() {
    echo "==> Очистка..."
    runc kill "$CONTAINER_NAME" KILL 2>/dev/null || true
    sleep 1
    runc delete --force "$CONTAINER_NAME" 2>/dev/null || true

    iptables -t nat -D PREROUTING  -p tcp --dport 8000 -j DNAT --to-destination ${CONTAINER_IP}:8000 2>/dev/null || true
    iptables -t nat -D OUTPUT      -p tcp --dport 8000 -j DNAT --to-destination ${CONTAINER_IP}:8000 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 127.0.0.1 -d ${CONTAINER_IP} -p tcp --dport 8000 -j SNAT --to-source ${HOST_IP} 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s 10.0.0.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d 10.0.0.0/24 -j ACCEPT 2>/dev/null || true

    ip link del "$VETH_HOST" 2>/dev/null || true
    ip netns del "$NETNS" 2>/dev/null || true

    umount "$MERGED_DIR" 2>/dev/null || true
    rm -rf "$BASE_DIR" 2>/dev/null || true
    echo "==> Готово"
}
trap cleanup EXIT INT TERM

case "$(uname -m)" in
    x86_64)  ARCH="x86_64" ;;
    aarch64) ARCH="aarch64" ;;
    armv7l)  ARCH="armv7" ;;
    armv6l)  ARCH="armhf" ;;
    i686)    ARCH="x86" ;;
    *)       ARCH="$(uname -m)" ;;
esac
echo "==> Архитектура: $ARCH"

HOST_IFACE=$(ip route | awk '/^default/ {print $5; exit}')
echo "==> Основной интерфейс хоста: $HOST_IFACE"

BASE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ARCH}"
TARBALL="alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz"

echo "==> Скачивание Alpine minirootfs..."
if ! curl -fsSL -o "$MINIROOTFS_TGZ" "$BASE_URL/$TARBALL" 2>/dev/null; then
    TARBALL=$(curl -fsSL "$BASE_URL/" | grep -oE 'alpine-minirootfs-[0-9.]+-'"$ARCH"'\.tar\.gz' | tail -1)
    curl -fsSL -o "$MINIROOTFS_TGZ" "$BASE_URL/$TARBALL"
fi

echo "==> Распаковка minirootfs..."
tar -xzf "$MINIROOTFS_TGZ" -C "$LOWER_DIR"

echo "==> Монтирование overlayfs..."
mount -t overlay overlay -o "lowerdir=$LOWER_DIR,upperdir=$UPPER_DIR,workdir=$WORK_DIR" "$MERGED_DIR"

cp /etc/resolv.conf "$MERGED_DIR/etc/resolv.conf"
echo "==> resolv.conf скопирован с хоста"

cat > "$MERGED_DIR/root/init.sh" <<'INIT_EOF'
#!/bin/sh
set -e
echo $$ > /host/container.pid
apk add --no-cache python3 py3-pip >/dev/null
mkdir -p /app
python3 -m venv /app/venv
/app/venv/bin/pip install --no-cache-dir --quiet fastapi uvicorn
cat > /app/app.py <<'PYEOF'
from fastapi import FastAPI
app = FastAPI()
@app.get("/health")
def health():
    return {"status": "ok"}
PYEOF
cd /app
exec /app/venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
INIT_EOF
chmod +x "$MERGED_DIR/root/init.sh"

echo "==> Настройка сети..."
ip netns add "$NETNS"
ip link add "$VETH_HOST" type veth peer name "$VETH_CONT"
ip link set "$VETH_CONT" netns "$NETNS"
ip addr add "${HOST_IP}/24" dev "$VETH_HOST"
ip link set "$VETH_HOST" up
ip netns exec "$NETNS" ip addr add "${CONTAINER_IP}/24" dev "$VETH_CONT"
ip netns exec "$NETNS" ip link set "$VETH_CONT" up
ip netns exec "$NETNS" ip link set lo up
ip netns exec "$NETNS" ip route add default via "$HOST_IP"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
sysctl -w net.ipv4.conf.${VETH_HOST}.route_localnet=1 >/dev/null
sysctl -w net.ipv4.conf.${VETH_HOST}.rp_filter=0 >/dev/null

iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o "$HOST_IFACE" -j MASQUERADE
iptables -I FORWARD -s 10.0.0.0/24 -j ACCEPT
iptables -I FORWARD -d 10.0.0.0/24 -j ACCEPT
iptables -t nat -A PREROUTING  -p tcp --dport 8000 -j DNAT --to-destination ${CONTAINER_IP}:8000
iptables -t nat -A OUTPUT      -p tcp --dport 8000 -j DNAT --to-destination ${CONTAINER_IP}:8000
iptables -t nat -A POSTROUTING -s 127.0.0.1 -d ${CONTAINER_IP} -p tcp --dport 8000 -j SNAT --to-source ${HOST_IP}

echo "==> Генерация OCI config.json..."
cat > "$BUNDLE_DIR/config.json" <<CONFIG_EOF
{
    "ociVersion": "1.0.2",
    "process": {
        "terminal": false,
        "user": {"uid": 0, "gid": 0},
        "args": ["/root/init.sh"],
        "env": [
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "TERM=xterm"
        ],
        "cwd": "/",
        "capabilities": {
            "bounding":   ["CAP_AUDIT_WRITE","CAP_KILL","CAP_NET_BIND_SERVICE","CAP_NET_RAW","CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_FOWNER","CAP_FSETID","CAP_SETGID","CAP_SETUID","CAP_SETPCAP","CAP_SYS_CHROOT","CAP_MKNOD"],
            "effective":  ["CAP_AUDIT_WRITE","CAP_KILL","CAP_NET_BIND_SERVICE","CAP_NET_RAW","CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_FOWNER","CAP_FSETID","CAP_SETGID","CAP_SETUID","CAP_SETPCAP","CAP_SYS_CHROOT","CAP_MKNOD"],
            "permitted":  ["CAP_AUDIT_WRITE","CAP_KILL","CAP_NET_BIND_SERVICE","CAP_NET_RAW","CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_FOWNER","CAP_FSETID","CAP_SETGID","CAP_SETUID","CAP_SETPCAP","CAP_SYS_CHROOT","CAP_MKNOD"]
        }
    },
    "root": {"path": "rootfs", "readonly": false},
    "hostname": "runc-container",
    "mounts": [
        {"destination": "/proc", "type": "proc", "source": "proc"},
        {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid","strictatime","mode=755","size=65536k"]},
        {"destination": "/tmp", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid","nodev","mode=1777"]},
        {"destination": "/host", "type": "bind", "source": "$STATE_DIR", "options": ["bind","rprivate"]}
    ],
    "linux": {
        "resources": {
            "memory": {"limit": $MEMORY_LIMIT},
            "cpu": {"quota": $CPU_QUOTA, "period": $CPU_PERIOD}
        },
        "cgroupsPath": "/container",
        "namespaces": [
            {"type": "pid"},
            {"type": "mount"},
            {"type": "uts"},
            {"type": "ipc"},
            {"type": "network", "path": "/var/run/netns/$NETNS"}
        ]
    }
}
CONFIG_EOF

echo "==> Запуск контейнера через runc..."
runc run -d --bundle "$BUNDLE_DIR" "$CONTAINER_NAME" </dev/null >"$BASE_DIR/runc.log" 2>&1

for i in $(seq 1 30); do
    CONTAINER_PID=$(runc state "$CONTAINER_NAME" 2>/dev/null | grep -o '"pid":[0-9]*' | cut -d: -f2 || true)
    [ -n "$CONTAINER_PID" ] && [ "$CONTAINER_PID" != "0" ] && break
    sleep 0.5
done
echo "==> Init-процесс контейнера (host PID): $CONTAINER_PID"

echo "==> Ожидание запуска FastAPI внутри контейнера..."
for i in $(seq 1 60); do
    if curl -fsS http://localhost:8000/health >/dev/null 2>&1; then
        echo "==> FastAPI готов!"
        break
    fi
    sleep 1
done

cat <<EOF

======================================================
  Контейнер запущен! (runc: $CONTAINER_NAME)
  FastAPI доступен: http://localhost:8000/health
  Ожидается ответ: {"status": "ok"}
  Для остановки нажмите Ctrl+C
======================================================
EOF

while runc state "$CONTAINER_NAME" >/dev/null 2>&1; do sleep 1; done
