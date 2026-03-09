#!/usr/bin/env bash
set -euo pipefail

PROXY_USER="${PROXY_USER:-guestpool}"
PROXY_PASS="${PROXY_PASS:-}"
PORT="${PORT:-3128}"
ALLOW_SOURCE="${ALLOW_SOURCE:-100.64.0.0/10}"
SRC_DIR="/usr/local/src/3proxy"
SERVICE_FILE="/etc/systemd/system/3proxy.service"
CONFIG_FILE="/etc/3proxy/3proxy.cfg"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

if [[ -z "${PROXY_PASS}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "PROXY_PASS is required in non-interactive mode."
    echo "Example:"
    echo "  sudo PROXY_PASS='your-strong-password' bash $0"
    exit 1
  fi

  while true; do
    read -rsp "Enter proxy password: " PROXY_PASS
    echo

    if [[ -z "${PROXY_PASS}" ]]; then
      echo "Password cannot be empty."
      continue
    fi

    read -rsp "Confirm proxy password: " PROXY_PASS_CONFIRM
    echo

    if [[ "${PROXY_PASS}" != "${PROXY_PASS_CONFIRM}" ]]; then
      echo "Passwords do not match. Please try again."
      continue
    fi

    unset PROXY_PASS_CONFIRM
    break
  done
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale is not installed. Install and join Tailscale first."
  echo "Official install:"
  echo "  curl -fsSL https://tailscale.com/install.sh | sh"
  exit 1
fi

if ! tailscale status >/dev/null 2>&1; then
  echo "tailscale is installed but not connected."
  echo "Run:"
  echo "  sudo tailscale up"
  exit 1
fi

TS_IP="$(tailscale ip -4 | head -n1 || true)"
if [[ -z "${TS_IP}" ]]; then
  echo "Could not detect Tailscale IPv4."
  exit 1
fi

echo "[1/7] Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git build-essential

echo "[2/7] Resolving latest 3proxy release tag..."
TAG="$(curl -fsSL https://api.github.com/repos/3proxy/3proxy/releases/latest | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
if [[ -z "${TAG}" ]]; then
  echo "Failed to resolve latest 3proxy tag from GitHub API."
  exit 1
fi

echo "[3/7] Fetching source for ${TAG}..."
rm -rf "${SRC_DIR}"
git clone --depth=1 --branch "${TAG}" https://github.com/3proxy/3proxy.git "${SRC_DIR}"

echo "[4/7] Building and installing 3proxy..."
cd "${SRC_DIR}"
ln -sf Makefile.Linux Makefile
make -j"$(nproc)"
make install

BIN_PATH="$(command -v 3proxy || true)"
if [[ -z "${BIN_PATH}" && -x /usr/local/3proxy/bin/3proxy ]]; then
  BIN_PATH="/usr/local/3proxy/bin/3proxy"
fi
if [[ -z "${BIN_PATH}" ]]; then
  BIN_PATH="$(find /usr/local -type f -name 3proxy 2>/dev/null | head -n1 || true)"
fi
if [[ -z "${BIN_PATH}" ]]; then
  echo "3proxy binary not found after install."
  exit 1
fi

echo "[5/7] Writing config..."
mkdir -p /etc/3proxy
chmod 700 /etc/3proxy

cat > "${CONFIG_FILE}" <<EOF
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536

timeouts 1 5 30 60 180 1800 15 60

users ${PROXY_USER}:CL:${PROXY_PASS}
auth strong
allow ${PROXY_USER} ${ALLOW_SOURCE}
proxy -p${PORT} -i${TS_IP}
flush
EOF

chmod 600 "${CONFIG_FILE}"

echo "[6/7] Creating systemd service..."
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=3proxy HTTP proxy bound to Tailscale
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} ${CONFIG_FILE}
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

echo "[7/7] Enabling service..."
systemctl daemon-reload
systemctl enable --now 3proxy

echo
echo "Done."
echo "Tailscale IP : ${TS_IP}"
echo "Proxy URL    : http://${PROXY_USER}:${PROXY_PASS}@${TS_IP}:${PORT}"
echo "Allowed src  : ${ALLOW_SOURCE}"
echo
echo "Check service:"
echo "  systemctl status 3proxy --no-pager"
echo
echo "Check logs:"
echo "  journalctl -u 3proxy -f"
echo
echo "From your controller machine, test with:"
echo "  curl -x http://${PROXY_USER}:${PROXY_PASS}@${TS_IP}:${PORT} https://api.ipify.org"
