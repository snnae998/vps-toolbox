#!/bin/bash
# sz-install: 一键安装送中检测上报（在每台要监控的 VPS 上以 root 运行）
# 用法：bash sz-install.sh <收集器地址> <上报令牌> [面板节点名]
# 节点名可省略：省略时自动用本机主机名（hostname）上报
# 例： curl -sL <地址>/sz-install.sh | bash -s -- https://sz.example.com TOKEN
set -e

COLLECTOR=$1
TOKEN=$2
NAME=${3:-$(hostname)}
RAW_BASE=${SZ_RAW_BASE:-https://raw.githubusercontent.com/snnae998/vps-toolbox/main}

if [ -z "$COLLECTOR" ] || [ -z "$TOKEN" ] || [ -z "$NAME" ]; then
    echo "用法：bash sz-install.sh <收集器地址> <上报令牌> [面板节点名（省略=本机主机名）]" >&2
    exit 1
fi
echo "上报节点名：$NAME"

curl -sL "$RAW_BASE/sz-agent.sh" -o /usr/local/bin/sz-agent.sh
chmod +x /usr/local/bin/sz-agent.sh

cat > /etc/sz-agent.conf <<EOF
SZ_COLLECTOR="$COLLECTOR"
SZ_TOKEN="$TOKEN"
SZ_NAME="$NAME"
EOF
chmod 600 /etc/sz-agent.conf

# 每 6 小时跑一次；分钟位按节点名散列错峰，避免全舰队同一分钟齐发
MIN=$(( $(printf '%s' "$NAME" | cksum | cut -d' ' -f1) % 60 ))
if [ -d /etc/cron.d ] || command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; then
  mkdir -p /etc/cron.d
  printf '%s */6 * * * root /usr/local/bin/sz-agent.sh >/dev/null 2>&1\n' "$MIN" > /etc/cron.d/sz-agent
  echo "自动复检：每 6 小时（/etc/cron.d/sz-agent）"
elif command -v crontab >/dev/null 2>&1; then
  ( crontab -l 2>/dev/null | grep -v 'sz-agent.sh' || true
    printf '%s */6 * * * /usr/local/bin/sz-agent.sh >/dev/null 2>&1\n' "$MIN" ) | crontab -
  echo "自动复检：每 6 小时（root crontab）"
else
  echo "⚠️ 这台没有 cron：agent 已装好、即时检测照常，但自动复检未生效（装好 cron 后重跑本安装命令即可）"
fi

echo "已安装，立即检测一次……"
/usr/local/bin/sz-agent.sh
echo "✅ 完成"
