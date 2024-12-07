#!/bin/bash

# 提示用户输入 Cloudflare 的 API 密钥
read -p "请输入您的 Cloudflare API 密钥 (Token 或 Global API Key): " CF_TOKEN
read -p "请输入您的 Cloudflare 账号邮箱 (如果使用 Token 可留空): " CF_EMAIL

# 确保输入不为空
if [ -z "$CF_TOKEN" ]; then
  echo "API 密钥不能为空，请重新运行脚本并输入密钥！"
  exit 1
fi

# 写入到 ~/.bashrc 文件
echo "正在将 API 密钥配置到 ~/.bashrc 文件中..."
echo "export CF_Token=\"$CF_TOKEN\"" >> ~/.bashrc

# 如果用户提供了邮箱，也一并写入
if [ -n "$CF_EMAIL" ]; then
  echo "export CF_Email=\"$CF_EMAIL\"" >> ~/.bashrc
fi

# 重新加载 ~/.bashrc
echo "重新加载 ~/.bashrc 文件以使配置生效..."
source ~/.bashrc

# 输出结果确认
echo "配置完成！以下是您当前的 API 配置："
echo "-----------------------------------"
echo "CF_Token: $CF_TOKEN"
[ -n "$CF_EMAIL" ] && echo "CF_Email: $CF_EMAIL"
echo "-----------------------------------"

# 提示用户后续操作
echo "现在可以运行需要 Cloudflare API 的脚本了！"
