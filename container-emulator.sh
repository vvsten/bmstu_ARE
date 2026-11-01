#!/bin/bash
set -e

NETNS="container-net"
CGROUP_DIR="/sys/fs/cgroup/container"
MEMORY_LIMIT="256M"
CPU_MAX="50000 100000"
TMP_BASE="$(mktemp -d /tmp/container.XXXXXX)"
ROOTFS_DIR="$TMP_BASE/rootfs"
UPPER_DIR="$TMP_BASE/upper"
WORK_DIR="$TMP_BASE/work"
MERGED_DIR="$TMP_BASE/merged"
STATE_DIR="$TMP_BASE/state"
mkdir -p "$ROOTFS_DIR" "$UPPER_DIR" "$WORK_DIR" "$MERGED_DIR" "$STATE_DIR"

BG_PID=""

cleanup() {
    echo "==> Очистка..."
    [ -n "$BG_PID" ] && kill "$BG_PID" 2>/dev/null || true
    sleep 1
    [ -n "$BG_PID" ] && kill -9 "$BG_PID" 2>/dev/null || true

    iptables -t nat -D PREROUTING -p tcp --dport 8000 -j DNAT --to-destination 10.0.0.2:8000 2>/dev/null || true
    iptables -t nat -D OUTPUT     -p tcp --dport 8000 -j DNAT --to-destination 10.0.0.2:8000 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 127.0.0.1 -d 10.0.0.2 -p tcp --dport 8000 -j SNAT --to-source 10.0.0.1 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s 10.0.0.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d 10.0.0.0/24 -j ACCEPT 2>/dev/null || true

    ip link del veth0 2>/dev/null || true
    ip netns del "$NETNS" 2>/dev/null || true

    umount "$MERGED_DIR/host" 2>/dev/null || true
    umount "$MERGED_DIR/dev"  2>/dev/null || true
    umount "$MERGED_DIR"      2>/dev/null || true

    [ -d "$CGROUP_DIR" ] && rmdir "$CGROUP_DIR" 2>/dev/null || true

    rm -rf "$TMP_BASE" 2>/dev/null || true
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

ALPINE_VER="3.20"
BASE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/releases/${ARCH}"
TARBALL="alpine-minirootfs-${ALPINE_VER}.0-${ARCH}.tar.gz"

echo "==> Скачивание Alpine minirootfs..."
if ! curl -fsSL -o "$TMP_BASE/$TARBALL" "$BASE_URL/$TARBALL" 2>/dev/null; then
    TARBALL=$(curl -fsSL "$BASE_URL/" | grep -oE 'alpine-minirootfs-[0-9.]+-'"$ARCH"'\.tar\.gz' | tail -1)
    curl -fsSL -o "$TMP_BASE/$TARBALL" "$BASE_URL/$TARBALL"
fi

echo "==> Распаковка minirootfs..."
tar -xzf "$TMP_BASE/$TARBALL" -C "$ROOTFS_DIR"

echo "==> Монтирование overlayfs..."
mount -t overlay overlay \
    -o "lowerdir=$ROOTFS_DIR,upperdir=$UPPER_DIR,workdir=$WORK_DIR" \
    "$MERGED_DIR"

mkdir -p "$MERGED_DIR/host" "$MERGED_DIR/dev"
mount --bind "$STATE_DIR" "$MERGED_DIR/host"
mount --bind /dev "$MERGED_DIR/dev"

cp /etc/resolv.conf "$MERGED_DIR/etc/resolv.conf"
echo "==> resolv.conf скопирован с хоста"

echo "==> Настройка cgroups v2..."
mkdir -p "$CGROUP_DIR"
echo "$MEMORY_LIMIT" > "$CGROUP_DIR/memory.max"
echo "$CPU_MAX" > "$CGROUP_DIR/cpu.max"

echo "==> Настройка сети..."
ip netns add "$NETNS"
ip link add veth0 type veth peer name veth1
ip link set veth1 netns "$NETNS"
ip addr add 10.0.0.1/24 dev veth0
ip link set veth0 up
ip netns exec "$NETNS" ip addr add 10.0.0.2/24 dev veth1
ip netns exec "$NETNS" ip link set veth1 up
ip netns exec "$NETNS" ip link set lo up
ip netns exec "$NETNS" ip route add default via 10.0.0.1

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
sysctl -w net.ipv4.conf.veth0.route_localnet=1 >/dev/null
sysctl -w net.ipv4.conf.veth0.rp_filter=0 >/dev/null

iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o "$HOST_IFACE" -j MASQUERADE
iptables -I FORWARD -s 10.0.0.0/24 -j ACCEPT
iptables -I FORWARD -d 10.0.0.0/24 -j ACCEPT
iptables -t nat -A PREROUTING  -p tcp --dport 8000 -j DNAT --to-destination 10.0.0.2:8000
iptables -t nat -A OUTPUT      -p tcp --dport 8000 -j DNAT --to-destination 10.0.0.2:8000
iptables -t nat -A POSTROUTING -s 127.0.0.1 -d 10.0.0.2 -p tcp --dport 8000 -j SNAT --to-source 10.0.0.1

CONTAINER_INIT='
set -e
mount -t proc proc /proc
mount -t tmpfs tmpfs /tmp
hostname container
echo $$ > /host/container.pid
apk add --no-cache python3 py3-pip >/dev/null
mkdir -p /app
python3 -m venv /app/venv
/app/venv/bin/pip install --no-cache-dir --quiet fastapi uvicorn
cat > /app/app.py <<PY
from fastapi import FastAPI
app = FastAPI()
@app.get("/health")
def health():
    return {"status": "ok"}
PY
cd /app
exec /app/venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
'

echo "==> Запуск контейнера..."
ip netns exec "$NETNS" unshare --mount --pid --uts --ipc --fork \
    chroot "$MERGED_DIR" /bin/sh -c "$CONTAINER_INIT" &
BG_PID=$!

while [ ! -s "$STATE_DIR/container.pid" ]; do sleep 0.1; done

UNSHARE_PID=$(pgrep -P "$BG_PID" | head -1)
CONTAINER_PID=$(pgrep -P "$UNSHARE_PID" | head -1)
echo "$CONTAINER_PID" > "$CGROUP_DIR/cgroup.procs"
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
  Контейнер запущен!
  FastAPI доступен: http://localhost:8000/health
  Ожидается ответ: {"status": "ok"}
  Для остановки нажмите Ctrl+C
======================================================
EOF

wait "$BG_PID"
