#!/bin/bash

set -e

VERSION="v1.19.11"
ARCH="amd64"
BIN_URL="https://github.com/MetaCubeX/mihomo/releases/download/$VERSION/mihomo-linux-amd64-$VERSION.gz"
SERVICE_PATH="/etc/systemd/system/mihomo.service"
CONFIG_DIR="/etc/mihomo"
BIN_PATH="/usr/local/bin/mihomo"
CONFIG_PATH="$CONFIG_DIR/config.yaml"

echo "==> 停止并禁用已存在的 mihomo 服务（如有）"
systemctl stop mihomo 2>/dev/null || true
systemctl disable mihomo 2>/dev/null || true

echo "==> 下载 mihomo 二进制"
wget -O /tmp/mihomo.gz "$BIN_URL"

echo "==> 解压 mihomo"
gzip -dc /tmp/mihomo.gz > /tmp/mihomo
chmod +x /tmp/mihomo

echo "==> 备份旧 mihomo"
[ -f "$BIN_PATH" ] && mv "$BIN_PATH" "$BIN_PATH.bak.$(date +%s)" || true

echo "==> 移动到 /usr/local/bin/"
mv /tmp/mihomo "$BIN_PATH"

echo "==> 准备配置目录"
mkdir -p "$CONFIG_DIR"

echo "==> 写入专用 config.yaml（直接覆盖！）"
cat > "$CONFIG_PATH" <<EOF
mixed-port: 7897
allow-lan: true
mode: rule
log-level: warning
ipv6: false
find-process-mode: strict
unified-delay: true
tcp-concurrent: true
global-client-fingerprint: chrome

dns:
  enable: true
  enhanced-mode: fake-ip
  listen: 0.0.0.0:7874
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.lan"
    - "*.local"
  nameserver:
    - system

tun:
  enable: true
  stack: system
  auto-route: true
  auto-redirect: true
  dns-hijack:
    - "any:53"
    - "tcp://any:53"

profile:
  store-selected: true
  store-fake-ip: true

proxies: []
proxy-groups: []
rules: []
EOF

echo "==> 生成 systemd 服务配置"
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=mihomo Daemon, Another Clash Kernel.
After=network.target NetworkManager.service systemd-networkd.service iwd.service

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
Restart=always
ExecStartPre=/usr/bin/sleep 1s
ExecStart=$BIN_PATH -d $CONFIG_DIR
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF

echo "==> 重新加载 systemd 配置"
systemctl daemon-reload

echo "==> 启用 mihomo 开机启动"
systemctl enable mihomo

echo "==> 启动 mihomo 服务"
systemctl start mihomo

echo "==> 安装完成"
systemctl status mihomo --no-pager

echo "==> 查看日志命令: journalctl -u mihomo -f"
