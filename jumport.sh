#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 打印带颜色的信息
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        error "请以root权限运行此脚本"
        exit 1
    fi
}

# 获取网络接口
get_interface() {
    local interface=$(ip -o -4 route show to default | awk '{print $5}')
    if [ -z "$interface" ]; then
        error "未找到网络接口"
        exit 1
    fi
    echo "$interface"
}

# 验证端口号
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if netstat -tuln | grep -q ":$port "; then
        while true; do
            warn "端口 $port 已被使用"
            echo -n "是否继续? [y/N]: "
            read answer
            case $answer in
                [Yy]* ) return 0;;
                [Nn]* ) return 1;;
                "" ) return 1;;
                * ) echo "请输入 y 或 n";;
            esac
        done
    fi
    return 0
}

# 验证端口范围
validate_port_range() {
    local port_input=$1
    local start_port
    local end_port

    if [[ "$port_input" =~ ^[0-9]+:[0-9]+$ ]]; then
        start_port=$(echo $port_input | cut -d: -f1)
        end_port=$(echo $port_input | cut -d: -f2)

        if ! validate_port "$start_port" || ! validate_port "$end_port"; then
            error "端口必须在1-65535之间"
            return 1
        fi

        if [ "$start_port" -ge "$end_port" ]; then
            error "起始端口必须小于结束端口"
            return 1
        fi
    elif [[ "$port_input" =~ ^[0-9]+$ ]]; then
        if ! validate_port "$port_input"; then
            error "端口必须在1-65535之间"
            return 1
        fi
    else
        error "无效的端口格式"
        return 1
    fi
    return 0
}

# 检查规则冲突
check_rule_conflict() {
    local interface=$1
    local protocol=$2
    local port_range=$3
    local target_port=$4

    local existing_rules=$(iptables -t nat -S PREROUTING)

    if [[ "$port_range" =~ ^([0-9]+):([0-9]+)$ ]]; then
        local new_start_port=${BASH_REMATCH[1]}
        local new_end_port=${BASH_REMATCH[2]}
    elif [[ "$port_range" =~ ^([0-9]+)$ ]]; then
        local new_start_port=$port_range
        local new_end_port=$port_range
    else
        error "无效的端口范围格式"
        return 1
    fi

    local protocols=()
    if [ "$protocol" = "ut" ]; then
        protocols=("tcp" "udp")
    else
        protocols=("$protocol")
    fi

    while read -r line; do
        if [[ "$line" =~ ^-A\ PREROUTING ]]; then
            existing_interface=""
            existing_protocol=""
            existing_port_range=""
            existing_target_port=""

            if [[ "$line" =~ -i[[:space:]]+([^ ]+) ]]; then
                existing_interface=${BASH_REMATCH[1]}
            fi

            if [[ "$line" =~ -p[[:space:]]+([^ ]+) ]]; then
                existing_protocol=${BASH_REMATCH[1]}
            fi

            if [[ "$line" =~ --dport[[:space:]]+([^ ]+) ]]; then
                existing_port_range=${BASH_REMATCH[1]}
            fi

            if [[ "$line" =~ --to-ports[[:space:]]+([^ ]+) ]]; then
                existing_target_port=${BASH_REMATCH[1]}
            fi

            if [[ "$existing_port_range" =~ ^([0-9]+):([0-9]+)$ ]]; then
                local existing_start_port=${BASH_REMATCH[1]}
                local existing_end_port=${BASH_REMATCH[2]}
            elif [[ "$existing_port_range" =~ ^([0-9]+)$ ]]; then
                local existing_start_port=$existing_port_range
                local existing_end_port=$existing_port_range
            else
                continue
            fi

            for proto in "${protocols[@]}"; do
                if [ "$proto" = "$existing_protocol" ] && [ "$interface" = "$existing_interface" ]; then
                    if [ "$new_start_port" -le "$existing_end_port" ] && [ "$new_end_port" -ge "$existing_start_port" ]; then
                        warn "检测到端口转发规则冲突: $line"
                        while true; do
                            echo -n "是否覆盖? [y/N]: "
                            read answer
                            case $answer in
                                [Yy]* ) 
                                    iptables -t nat -D PREROUTING -i "$existing_interface" -p "$existing_protocol" --dport "$existing_port_range" -j REDIRECT --to-ports "$existing_target_port"
                                    info "已删除冲突的规则"
                                    return 0
                                    ;;
                                [Nn]*|"" ) 
                                    info "操作已取消"
                                    exit 1
                                    ;;
                                * ) echo "请输入 y 或 n";;
                            esac
                        done
                    fi
                fi
            done
        fi
    done <<< "$existing_rules"

    return 0
}

# 新增函数：在ufw防火墙上开放端口
open_ufw_port() {
    local port_range=$1
    local protocol=$2

    if command -v ufw >/dev/null 2>&1; then
        if [[ "$port_range" =~ ^[0-9]+:[0-9]+$ ]]; then
            local start_port=$(echo "$port_range" | cut -d: -f1)
            local end_port=$(echo "$port_range" | cut -d: -f2)
            for ((port=start_port; port<=end_port; port++)); do
                ufw allow "$port/$protocol"
                info "已在ufw中开放 $protocol 端口 $port"
            done
        else
            ufw allow "$port_range/$protocol"
            info "已在ufw中开放 $protocol 端口 $port_range"
        fi
    else
        warn "未检测到ufw，跳过防火墙端口开放"
    fi
}

# 添加iptables规则
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

# 保存iptables规则
save_rules() {
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables.rules

        if [ ! -f /etc/network/if-pre-up.d/iptables ]; then
            cat > /etc/network/if-pre-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
            chmod +x /etc/network/if-pre-up.d/iptables
        fi

        info "iptables规则已保存并将在开机时自动加载"
    else
        warn "无法找到 iptables-save 命令,规则将在重启后失效"
    fi
}

# 显示使用帮助
show_usage() {
    echo "用法: $0 target_port port_range|single_port protocol"
    echo "协议(protocol)可选值:"
    echo "  tcp - 仅转发TCP"
    echo "  udp - 仅转发UDP"
    echo "  ut  - 同时转发TCP和UDP"
    echo
    echo "示例:"
    echo "  $0 443 1000:2000 ut     # 将1000-2000端口的TCP和UDP都转发到443"
    echo "  $0 443 8080 tcp         # 将8080端口的TCP转发到443"
    echo "  $0 443 8080 udp         # 将8080端口的UDP转发到443"
}

# 主函数
main() {
    if [ "$#" -ne 3 ]; then
        show_usage
        exit 1
    fi

    check_root

    local target_port=$1
    local port_input=$2
    local protocol=$3

    if ! validate_port "$target_port"; then
        error "无效的目标端口号"
        exit 1
    fi

    if ! check_port "$target_port"; then
        info "操作已取消"
        exit 1
    fi

    if ! validate_port_range "$port_input"; then
        exit 1
    fi

    if [[ ! "$protocol" =~ ^(tcp|udp|ut)$ ]]; then
        error "协议必须是 tcp、udp 或 ut(同时转发TCP和UDP)"
        exit 1
    fi

    local interface=$(get_interface)

    if ! check_rule_conflict "$interface" "$protocol" "$port_input" "$target_port"; then
        exit 1
    fi

    add_iptables_rule "$interface" "$protocol" "$port_input" "$target_port"
    save_rules

    if [ "$protocol" = "ut" ]; then
        info "端口转发规则已添加:"
        info "将 $interface 接口上的 TCP和UDP 端口 $port_input 转发到端口 $target_port"
    else
        info "端口转发规则已添加:"
        info "将 $interface 接口上的 $protocol 端口 $port_input 转发到端口 $target_port"
    fi
}

# 执行主函数
main "$@"
