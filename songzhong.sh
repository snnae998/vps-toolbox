#!/bin/bash
# 一键检测送中：查 YouTube 对本机出口 IP 的地区判定（与 xykt IPQuality 同一口径）
# 用法：bash songzhong.sh        或        bash <(curl -sL <脚本地址>)

COOKIE='YSC=BiCUU3-5Gdk; CONSENT=YES+cb.20220301-11-p0.en+FX+700; GPS=1; VISITOR_INFO1_LIVE=4VwPMkB7W5A; PREF=tz=Asia.Shanghai; _gcl_au=1.1.1809531354.1646633279'
URL='https://www.youtube.com/premium'

check_stack() {
    local stack="$1" label="$2" ip="$3"
    local body region
    body=$(curl -"$stack" -sSL --max-time 10 -H "Accept-Language: en" -b "$COOKIE" "$URL" 2>/dev/null)
    if [ -z "$body" ]; then
        echo "$label 出口 $ip ：无法打开 YouTube 页面（不通或超时），无法判定"
        return
    fi
    if printf '%s' "$body" | grep -q 'www.google.cn'; then
        echo "$label 出口 $ip ：🚨 送中（YouTube 判定为中国 CN）"
    else
        region=$(printf '%s' "$body" | grep -o '"contentRegion":"[A-Z]*"' | head -1 | cut -d'"' -f4)
        echo "$label 出口 $ip ：✅ 未送中（YouTube 判定地区：${region:-未知}）"
    fi
}

echo "正在检测 YouTube 对本机出口的地区判定……"

IP4=$(curl -4 -s --max-time 5 https://ipinfo.io/ip 2>/dev/null)
if [ -n "$IP4" ]; then
    check_stack 4 "IPv4" "$IP4"
else
    echo "IPv4：无 IPv4 出口，跳过"
fi

IP6=$(curl -6 -s --max-time 5 https://ipinfo.io/ip 2>/dev/null)
if [ -n "$IP6" ]; then
    check_stack 6 "IPv6" "$IP6"
else
    echo "IPv6：无 IPv6 出口，跳过"
fi
