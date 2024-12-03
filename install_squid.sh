#!/bin/bash

# 安装所需软件包
echo "Installing required packages..."
apt update
apt install apache2-utils squid -y

# 创建认证文件并设置密码
echo "Creating authentication file and setting password..."
htpasswd -cb /etc/squid/passwords squid

# 配置 Squid 配置文件
cat <<EOL | sudo tee /etc/squid/squid.conf > /dev/null
# 启用 HTTP 代理端口 22013
http_port 22013

# Access Control Lists
acl SSL_ports port 443
acl Safe_ports port 443
acl purge method PURGE

# 认证配置
# 使用 Basic 认证
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwords
auth_param basic children 5 startup=5 idle=1
auth_param basic credentialsttl 2 hours

# 配置认证缓存
authenticate_cache_garbage_interval 1 hour
authenticate_ttl 1 hour

# 配置客户端 IP 地址相关缓存
authenticate_ip_ttl 1 second

# 认证的 Access Control List (ACL)
acl authenticated_users proxy_auth REQUIRED

# Access Control Rules
http_access allow authenticated_users   # 允许认证通过的用户
http_access deny purge
http_access deny !Safe_ports
http_access allow CONNECT SSL_ports

# 允许所有人访问 (注意：必须在认证相关规则后)
http_access allow all

# 日志设置
access_log /var/log/squid/access.log squid
cache_log /var/log/squid/cache.log

# 缓存设置
maximum_object_size_in_memory 8 KB
maximum_object_size 128 MB
cache_mem 64 MB
cache_dir ufs /var/spool/squid 100 16 256

# 其他设置
visible_hostname squid-server
EOL

# 自动判断并配置防火墙
if command -v ufw > /dev/null; then
    # 如果 ufw 被启用
    echo "UFW detected, opening port 22013..."
    sudo ufw allow 22013/tcp
    sudo ufw reload
    elif command -v iptables > /dev/null; then
    # 如果 iptables 被启用
    echo "Iptables detected, opening port 22013..."
    sudo iptables -A INPUT -p tcp --dport 22013 -j ACCEPT
    sudo iptables-save > /etc/iptables/rules.v4
else
    echo "No firewall tool (ufw or iptables) found. Please configure manually."
fi

# 启动 Squid 服务
sudo systemctl restart squid
sudo systemctl enable squid
echo "Squid is now running on port 22013."