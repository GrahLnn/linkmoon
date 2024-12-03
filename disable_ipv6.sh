#!/bin/bash

# 禁用IPv6
echo "禁用IPv6..."

# 编辑sysctl.conf文件，添加禁用IPv6的配置
if ! grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv6.conf.default.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv6.conf.lo.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf
fi

# 重新加载sysctl配置
sudo sysctl -p

# 确认IPv6是否禁用
echo "当前IPv6状态:"
ip a | grep inet6

echo "IPv6已被禁用。"
