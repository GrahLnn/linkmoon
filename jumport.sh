# 新增函数：在ufw防火墙上开放端口
open_ufw_port() {
    local port_range=$1
    local protocol=$2

    if command -v ufw >/dev/null 2>&1; then
        if [[ "$port_range" =~ ^[0-9]+:[0-9]+$ ]]; then
            # 如果是端口范围，逐一开放
            local start_port=$(echo "$port_range" | cut -d: -f1)
            local end_port=$(echo "$port_range" | cut -d: -f2)
            for ((port=start_port; port<=end_port; port++)); do
                ufw allow "$port/$protocol"
                info "已在ufw中开放 $protocol 端口 $port"
            done
        else
            # 单个端口
            ufw allow "$port_range/$protocol"
            info "已在ufw中开放 $protocol 端口 $port_range"
        fi
    else
        warn "未检测到ufw，跳过防火墙端口开放"
    fi
}

# 修改 add_iptables_rule 函数以调用 open_ufw_port
add_iptables_rule() {
    local interface=$1
    local protocol=$2
    local port_range=$3
    local target_port=$4

    if [ "$protocol" = "ut" ]; then
        iptables -t nat -A PREROUTING -i "$interface" -p tcp --dport "$port_range" -j REDIRECT --to-ports "$target_port"
        iptables -t nat -A PREROUTING -i "$interface" -p udp --dport "$port_range" -j REDIRECT --to-ports "$target_port"
        info "已添加TCP和UDP端口转发规则"
        open_ufw_port "$port_range" "tcp"
        open_ufw_port "$port_range" "udp"
    else
        iptables -t nat -A PREROUTING -i "$interface" -p "$protocol" --dport "$port_range" -j REDIRECT --to-ports "$target_port"
        info "已添加${protocol}端口转发规则"
        open_ufw_port "$port_range" "$protocol"
    fi
}
