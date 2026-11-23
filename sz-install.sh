#!/bin/bash
# sz-install: 一键安装送中检测上报（在每台要监控的 VPS 上以 root 运行）
# 用法：bash sz-install.sh <收集器地址> <上报令牌> <面板节点名>
# 例： curl -sL <地址>/sz-install.sh | bash -s -- https://sz.example.com TOKEN 节点名
set -e

COLLECTOR=$1
TOKEN=$2
NAME=$3
RAW_BASE=${SZ_RAW_BASE:-https://raw.githubusercontent.com/snnae998/vps-toolbox/main}

if [ -z "$COLLECTOR" ] || [ -z "$TOKEN" ] || [ -z "$NAME" ]; then
    echo "用法：bash sz-install.sh <收集器地址> <上报令牌> <面板节点名>" >&2
    exit 1
fi

curl -sL "$RAW_BASE/sz-agent.sh" -o /usr/local/bin/sz-agent.sh
chmod +x /usr/local/bin/sz-agent.sh

cat > /etc/sz-agent.conf <<EOF
SZ_COLLECTOR=$COLLECTOR
SZ_TOKEN=$TOKEN
SZ_NAME=$NAME
EOF
chmod 600 /etc/sz-agent.conf

# 每 6 小时跑一次；分钟位按节点名散列错峰，避免全舰队同一分钟齐发
MIN=$(( $(printf '%s' "$NAME" | cksum | cut -d' ' -f1) % 60 ))
printf '%s */6 * * * root /usr/local/bin/sz-agent.sh >/dev/null 2>&1\n' "$MIN" > /etc/cron.d/sz-agent

echo "已安装，立即检测一次……"
/usr/local/bin/sz-agent.sh
echo "✅ 完成：每 6 小时自动检测并上报（/etc/cron.d/sz-agent）"
