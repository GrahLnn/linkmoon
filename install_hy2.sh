#!/bin/bash

# 定义颜色
GREEN="\033[32m"
RED="\033[31m"
PLAIN="\033[0m"

# 检查是否为 root 用户
if [ $(id -u) -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# 菜单函数
menu() {
    clear
    echo "#############################################################"
    if [ -f /etc/hysteria/config.yaml ]; then
        echo -e "# 当前配置："
        cat /etc/hysteria/config.yaml
        echo "#############################################################"
    else
        echo -e "# ${RED}无配置，请按提示进行安装${PLAIN}"
        echo "#############################################################"
    fi
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 安装 Hysteria 2"
    echo -e " ${RED}2.${PLAIN} 卸载 Hysteria 2"
    echo " ------------------------------------------------------------"
    echo -e " 3. 启动、停止、重启 Hysteria 2"
    echo -e " 4. 修改 Hysteria 2 配置"
    echo " ------------------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo ""
    read -rp "请输入选项 [0-4]: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) changeconf ;;
        0 ) exit 0 ;;
        * ) echo -e "${RED}请输入正确的选项！${PLAIN}"; sleep 2; menu ;;
    esac
}

# 安装 Hysteria 2 的函数
insthysteria() {
    # 安装 Hysteria
    bash <(curl -fsSL https://get.hy2.sh/)

    # 随机生成端口号
    PORT=$(shuf -i 1000-65535 -n 1)

    # 提示使用随机端口，用户可选择修改
    echo "系统已随机选择监听端口号：$PORT"
    read -p "如需更改，请输入新的端口号（直接回车以使用随机端口）： " INPUT_PORT

    if [ ! -z "$INPUT_PORT" ]; then
        while ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] || [ "$INPUT_PORT" -lt 1000 ] || [ "$INPUT_PORT" -gt 65535 ]; do
            echo "无效的端口号，请输入1000-65535之间的数字。"
            read -p "请输入监听端口号（1000-65535）：" INPUT_PORT
        done
        PORT=$INPUT_PORT
    fi

    # 获取域名
    echo -e "${GREEN}注意：请确保您的域名已解析到本机 IP，且在 Cloudflare 后台关闭 DNS 代理（灰色云朵）${PLAIN}"
    read -p "请输入您的域名：" DOMAIN

    # 获取邮箱
    read -p "请输入您的邮箱：" EMAIL

    # 获取 Cloudflare API 令牌
    read -p "请输入您的 Cloudflare API Token：" CF_API_TOKEN

    # 获取密码，用户可选择输入或随机生成
    read -p "请输入密码（留空则自动生成随机密码）：" PASSWORD

    if [ -z "$PASSWORD" ]; then
        # 生成随机密码
        PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        echo "已生成随机密码：$PASSWORD"
    fi

    # 创建配置文件 /etc/hysteria/config.yaml
    cat <<EOF >/etc/hysteria/config.yaml
listen: :$PORT

acme:
  domains:
    - $DOMAIN
  email: $EMAIL
  type: dns
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: $CF_API_TOKEN

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://en.snu.ac.kr
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF

    echo "配置文件 /etc/hysteria/config.yaml 已创建。"

    # 启用并启动 Hysteria 服务
    systemctl enable hysteria-server.service
    systemctl start hysteria-server.service

    # 设置系统缓冲区大小，将发送、接收两个缓冲区都设置为16 MB
    sysctl -w net.core.rmem_max=16777216
    sysctl -w net.core.wmem_max=16777216

    # 创建服务优先级配置文件
    mkdir -p /etc/systemd/system/hysteria-server.service.d/
    cat <<EOF >/etc/systemd/system/hysteria-server.service.d/priority.conf
[Service]
CPUSchedulingPolicy=rr
CPUSchedulingPriority=99
EOF

    # 重新加载 systemd 配置并重启服务
    systemctl daemon-reload
    systemctl restart hysteria-server.service

    # 检查并配置防火墙
    if command -v ufw >/dev/null 2>&1; then
        UFW_STATUS=$(ufw status | grep -o "Status: active")
        if [ "$UFW_STATUS" == "Status: active" ]; then
            ufw allow $PORT
            echo "已在防火墙中开放端口 $PORT。"
        fi
    else
        echo "未检测到 UFW 防火墙，跳过防火墙配置。"
    fi

    echo "Hysteria 安装和配置完成。"
    sleep 2
    menu
}

# 卸载 Hysteria 2 的函数
unsthysteria() {
    read -p "确定要卸载 Hysteria 2 吗？[y/N]：" CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        systemctl stop hysteria-server.service
        systemctl disable hysteria-server.service
        rm -f /etc/systemd/system/hysteria-server.service
        rm -rf /etc/hysteria/
        rm -rf /usr/local/bin/hysteria
        systemctl daemon-reload
        echo "Hysteria 2 已卸载。"
    else
        echo "卸载已取消。"
    fi
    sleep 2
    menu
}

# 启动、停止、重启 Hysteria 2 的函数
hysteriaswitch() {
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 启动 Hysteria 2"
    echo -e " ${RED}2.${PLAIN} 停止 Hysteria 2"
    echo -e " ${GREEN}3.${PLAIN} 重启 Hysteria 2"
    echo -e " ${GREEN}4.${PLAIN} 查看 Hysteria 2 状态"
    echo -e " ${GREEN}0.${PLAIN} 返回上级菜单"
    echo ""
    read -rp "请输入选项 [0-4]: " actionInput
    case $actionInput in
        1 ) systemctl start hysteria-server.service; echo "Hysteria 2 已启动。";;
        2 ) systemctl stop hysteria-server.service; echo "Hysteria 2 已停止。";;
        3 ) systemctl restart hysteria-server.service; echo "Hysteria 2 已重启。";;
        4 ) systemctl status hysteria-server.service; read -p "按任意键返回...";;
        0 ) menu ;;
        * ) echo -e "${RED}请输入正确的选项！${PLAIN}";;
    esac
    sleep 2
    hysteriaswitch
}

# 修改 Hysteria 2 配置的函数
changeconf() {
    if [ -f /etc/hysteria/config.yaml ]; then
        vi /etc/hysteria/config.yaml
        systemctl restart hysteria-server.service
        echo "配置已修改并重启 Hysteria 2 服务。"
    else
        echo -e "${RED}配置文件不存在，请先安装 Hysteria 2。${PLAIN}"
    fi
    sleep 2
    menu
}

# 运行菜单
menu