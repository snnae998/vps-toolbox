#!/bin/bash
# ============================================================
# VPS 一键工具箱
# 1. 一键初始化你的VPS（全自动/单项可选）
# 2. 一键加固你的VPS（SSH安全，交互菜单）
# 3. 存储守护（每周自动清理）
# 4. 单、多线程测速（TaierSpeedtest）
# 5. TcpQuality（TCP 线路质量测试）
# 6. NodeQuality（节点综合质量测试）
# 7. 一键Snell（安装 Snell 代理）
# 8. X-UI（安装 X-UI 面板）
# ============================================================

# --- 初始化子功能 ---
init_tools() {
  echo "[装基础工具]..."
  apt update -y && apt install -y curl wget unzip
  echo "✅ 完成"
}

init_ipv4() {
  echo "[IPv4优先]..."
  grep -q '^precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
  echo "✅ 完成"
}

init_ipv6() {
  echo "[IPv6检查修复]..."
  S=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null); A=$(ip -6 addr show scope global | grep -c inet6); R=$(ip -6 route show default | grep -c default)
  if [ "$S" = "1" ]; then
    echo "✅ IPv6 已禁用，无需处理"
  elif [ "$A" -gt 0 ] && [ "$R" -gt 0 ]; then
    if ping -6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1; then
      echo "✅ IPv6 正常，无需处理"
    else
      echo "❌ IPv6 配了但不通，正在禁用..."
      sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
      grep -q "disable_ipv6" /etc/sysctl.conf || echo -e "\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
      echo "✅ IPv6 已禁用"
    fi
  else
    echo "❌ IPv6 开着但没配好，正在禁用..."
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
    grep -q "disable_ipv6" /etc/sysctl.conf || echo -e "\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
    echo "✅ IPv6 已禁用"
  fi
}

init_time() {
  echo "[时间同步修复]..."
  if timedatectl 2>/dev/null | grep -q "System clock synchronized: yes"; then
    echo "✅ 时间同步正常，无需处理"
  else
    echo "❌ 时间未同步，正在修复..."
    apt update && apt install -y systemd-timesyncd
    timedatectl set-ntp true
    sleep 10
    echo "--- 修复后状态 ---"
    date; timedatectl | grep -E "System clock|NTP"
  fi
}

init_bbr() {
  echo "[开启BBR]..."
  if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
    echo "✅ BBR 已开启，无需处理"
  else
    echo "❌ BBR 未开启，正在开启..."
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo "--- 开启后状态 ---"
    sysctl net.ipv4.tcp_congestion_control
  fi
}

init_timezone() {
  echo "[改时区]..."
  timedatectl set-timezone Asia/Shanghai
  date
  echo "✅ 完成"
}

init_update() {
  echo "[系统更新]..."
  apt update && apt upgrade -y
  echo "✅ 完成"
}

init_all() {
  init_tools; init_ipv4; init_ipv6; init_time; init_bbr; init_timezone; init_update
  echo "==================== 初始化全部完成 ===================="
}

# --- 初始化子菜单 ---
init_menu() {
  while true; do
    clear
    echo "================ 一键初始化你的VPS ================"
    echo "1. 装基础工具"
    echo "2. IPv4优先"
    echo "3. IPv6检查修复"
    echo "4. 时间同步修复"
    echo "5. 开启BBR"
    echo "6. 改时区"
    echo "7. 系统更新"
    echo "8. 全部运行"
    echo "0. 返回主菜单"
    echo "======================================================"
    read -rp "请选择 [0-8]: " c
    case "$c" in
      1) init_tools ;;
      2) init_ipv4 ;;
      3) init_ipv6 ;;
      4) init_time ;;
      5) init_bbr ;;
      6) init_timezone ;;
      7) init_update ;;
      8) init_all ;;
      0) return ;;
      *) echo "无效选项！"; sleep 1 ;;
    esac
    echo ""
    read -rp "按回车继续..." _
  done
}

# --- 存储守护 ---
storage_guard() {
  CLEAN_PATH="/root/vps99clean.sh"
  if [ -f "$CLEAN_PATH" ] && crontab -l 2>/dev/null | grep -q "$CLEAN_PATH"; then
    echo "存储守护已部署，每周一 06:06 自动清理。"
    read -rp "是否重新部署？[y/N]: " r
    [ "$r" != "y" ] && [ "$r" != "Y" ] && return
  fi
  if ! command -v crontab >/dev/null 2>&1; then
    echo "❌ 未找到 crontab，请先安装 cron（apt install cron）"
    return
  fi
  cat > "$CLEAN_PATH" <<'CLEANEOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
if command -v apt >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt autoremove --purge -y >/dev/null 2>&1
  apt clean -y >/dev/null 2>&1
  apt autoclean -y >/dev/null 2>&1
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --rotate >/dev/null 2>&1
    journalctl --vacuum-time=7d >/dev/null 2>&1
    journalctl --vacuum-size=100M >/dev/null 2>&1
  fi
fi
if command -v docker >/dev/null 2>&1; then
  docker image prune -a -f >/dev/null 2>&1
  find /var/lib/docker/containers/ -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null
fi
CLEANEOF
  chmod +x "$CLEAN_PATH"
  if (crontab -l 2>/dev/null | grep -v "$CLEAN_PATH"; printf '6 6 * * 1 %s > /dev/null 2>&1\n' "$CLEAN_PATH") | crontab - 2>/dev/null; then
    if crontab -l 2>/dev/null | grep -q "$CLEAN_PATH"; then
      echo "✅ 存储守护已部署（每周一 06:06）"
    else
      echo "❌ 写入 crontab 后校验失败"
    fi
  else
    echo "❌ 写入 crontab 失败"
  fi
}

# --- 主菜单 ---
while true; do
  clear
  echo "================================="
  echo "  VPS 一键工具箱"
  echo "================================="
  echo "1. 一键初始化你的VPS"
  echo "2. 一键加固你的VPS"
  echo "3. 存储守护（每周自动清理）"
  echo "4. 单、多线程测速"
  echo "5. TcpQuality"
  echo "6. NodeQuality"
  echo "7. 一键Snell"
  echo "8. X-UI"
  echo "0. 退出"
  echo "================================="
  read -rp "请选择 [0-8]: " choice
  case "$choice" in
    1) init_menu ;;
    2) bash <(curl -fsSL https://raw.githubusercontent.com/snnae998/key.sh/main/key.sh) ;;
    3) storage_guard ;;
    4) bash <(curl -fsSL https://raw.githubusercontent.com/MiaM1ku/taierspeedtest/main/run.sh) ;;
    5) bash <(curl -fsSL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) ;;
    6) bash <(curl -sL https://run.NodeQuality.com) ;;
    7) wget -O snell.sh --no-check-certificate https://git.io/Snell.sh && chmod +x snell.sh && ./snell.sh ;;
    8) bash <(curl -Ls https://raw.githubusercontent.com/FranzKafkaYu/x-ui/master/install.sh) ;;
    0) echo "退出。"; exit 0 ;;
    *) echo "无效选项，请重新选择！"; sleep 1 ;;
  esac
  echo ""
  read -rp "按回车返回主菜单..." _
done
