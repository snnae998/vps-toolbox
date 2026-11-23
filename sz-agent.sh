#!/bin/bash
# sz-agent: 在本机跑一键检测送中（与 xykt IPQuality 同一口径），把结果报给收集器。
# 配置在 /etc/sz-agent.conf：SZ_COLLECTOR（收集器地址）、SZ_TOKEN（上报令牌）、SZ_NAME（面板里的节点名）
# 手动运行一次：sz-agent.sh ；被 cron 每 6 小时调用时无输出。

CONF=/etc/sz-agent.conf
[ -f "$CONF" ] && . "$CONF"
COOKIE='YSC=BiCUU3-5Gdk; CONSENT=YES+cb.20220301-11-p0.en+FX+700; GPS=1; VISITOR_INFO1_LIVE=4VwPMkB7W5A; PREF=tz=Asia.Shanghai; _gcl_au=1.1.1809531354.1646633279'
URL='https://www.youtube.com/premium'

# 输出 "状态 地区"：状态 ok/cn/fail/none
# 探 IP 必须用双栈端点：ipinfo.io 没有 AAAA 记录，-6 永远拿不到地址（旧版踩坑）
check_stack() {
    local stack="$1" ip body region probe
    if [ "$stack" = 6 ]; then probe=https://api64.ipify.org; else probe=https://api4.ipify.org; fi
    ip=$(curl -"$stack" -s --max-time 5 "$probe" 2>/dev/null)
    [ -z "$ip" ] && { echo "none "; return; }
    body=$(curl -"$stack" -sSL --max-time 10 -H "Accept-Language: en" -b "$COOKIE" "$URL" 2>/dev/null)
    [ -z "$body" ] && { echo "fail "; return; }
    if printf '%s' "$body" | grep -q 'www.google.cn'; then
        echo "cn CN"
    else
        region=$(printf '%s' "$body" | grep -o '"contentRegion":"[A-Z]*"' | head -1 | cut -d'"' -f4)
        echo "ok ${region:-??}"
    fi
}

read -r V4 V4R <<< "$(check_stack 4)"
read -r V6 V6R <<< "$(check_stack 6)"
IP4=$(curl -4 -s --max-time 5 https://api4.ipify.org 2>/dev/null)
IP6=$(curl -6 -s --max-time 5 https://api64.ipify.org 2>/dev/null)
NAME=${SZ_NAME:-$(hostname)}

payload=$(printf '{"name":"%s","ip4":"%s","ip6":"%s","v4":"%s","v4_region":"%s","v6":"%s","v6_region":"%s"}' \
    "$NAME" "$IP4" "$IP6" "$V4" "$V4R" "$V6" "$V6R")

if [ -n "$SZ_COLLECTOR" ] && [ -n "$SZ_TOKEN" ]; then
    curl -s --max-time 15 -X POST "$SZ_COLLECTOR/report" \
        -H "Authorization: Bearer $SZ_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null 2>&1
fi

# 手动运行时给人看的输出（cron 里没人看也无妨）
if [ -t 1 ]; then
    echo "节点 $NAME"
    echo "IPv4 $IP4 ：$V4 $V4R"
    echo "IPv6 $IP6 ：$V6 $V6R"
fi
exit 0
