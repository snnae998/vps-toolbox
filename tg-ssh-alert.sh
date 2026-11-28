#!/bin/bash
# ============================================================
# TG SSH 登录提醒 —— Telegram 实时监控 VPS 有没有人登录
# 机制：PAM pam_exec 钩子，SSH 登录成功后立即发 TG 消息
#   服务器、登录用户、来源 IP、时间，一次登录一条
# 安全红线：
#   - PAM 行是 optional，通知脚本任何情况下都 exit 0，绝不能挡住登录
#   - 通知走 setsid 脱离 + 10 秒超时，TG 挂了也不拖慢登录
#   - Token 只存本机 /etc/tg-ssh-alert.conf（600，root 可读），不进仓库
# 用法（工具箱菜单 11，或单独跑）：
#   bash <(curl -sL https://raw.githubusercontent.com/snnae998/vps-toolbox/main/tg-ssh-alert.sh)
# ============================================================
set -u

CONF="/etc/tg-ssh-alert.conf"
NOTIFIER="/usr/local/bin/ssh-login-alert.sh"
PAM_FILE="/etc/pam.d/sshd"
PAM_LINE="session    optional     pam_exec.so $NOTIFIER"

# --- 通知脚本（安装时写入 $NOTIFIER）---
install_notifier() {
  cat > "$NOTIFIER" <<'NOTIFIER_EOF'
#!/bin/bash
# ssh-login-alert: Telegram SSH 登录提醒（由 PAM pam_exec 调用）
# 红线：任何情况下都必须 exit 0，绝不能挡住登录。
CONF="/etc/tg-ssh-alert.conf"
[ -f "$CONF" ] || exit 0
# 只处理 SSH 会话的 open_session（本地登录、cron 等不触发）
[ "${PAM_TYPE:-}" = "open_session" ] || exit 0
[ -n "${PAM_RHOST:-}" ] || exit 0
# shellcheck disable=SC1090
. "$CONF" 2>/dev/null || exit 0
[ -n "${BOT_TOKEN:-}" ] && [ -n "${CHAT_ID:-}" ] || exit 0
HOST="$(hostname 2>/dev/null || echo unknown)"
USER="${PAM_USER:-unknown}"
FROM="${PAM_RHOST:-unknown}"
TIME="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)"
MSG="🔐 SSH 登录提醒
服务器：${HOST}
用户：${USER}
来源 IP：${FROM}
时间：${TIME}"
# 脱离 PAM 会话异步发送，超时 10 秒；失败静默，绝不影响登录
setsid curl -s --max-time 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "text=${MSG}" >/dev/null 2>&1 &
exit 0
NOTIFIER_EOF
  chmod 755 "$NOTIFIER"
  chown root:root "$NOTIFIER"
}

# --- 发一条测试消息（返回 0/1）---
send_test() {
  local token="$1" chat="$2"
  local host
  host="$(hostname 2>/dev/null || echo unknown)"
  local msg="✅ SSH 登录提醒已装好
服务器：${host}
以后每次有人 SSH 登录，你都会收到一条提醒。"
  curl -s --max-time 10 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat}" \
    --data-urlencode "text=${msg}" >/dev/null 2>&1
}

is_installed() {
  [ -f "$NOTIFIER" ] && [ -f "$CONF" ] && grep -qsF "$NOTIFIER" "$PAM_FILE" 2>/dev/null
}

do_install() {
  echo "需要两个东西（都没有的话先去 Telegram 弄一个机器人）："
  echo "  1. 机器人 Token：Telegram 里找 @BotFather，发 /newbot 按提示建好"
  echo "  2. 你的用户 ID：找 @userinfobot 或 @my_id_bot，发 /start 就能看到"
  echo ""
  local token chat
  read -rp "机器人 Token（粘贴后回车，不会回显）： " -s token
  echo ""
  read -rp "你的 Telegram 用户 ID： " chat
  token="${token//[[:space:]]/}"
  chat="${chat//[[:space:]]/}"
  if [ -z "$token" ] || [ -z "$chat" ]; then
    echo "❌ Token 或用户 ID 为空，没装。"
    return 1
  fi
  # 先发一条测试消息，通了再写配置（Token 错了立刻就能发现）
  echo "正在发测试消息..."
  if ! send_test "$token" "$chat"; then
    echo "❌ 测试消息没发出去，请检查 Token / 用户 ID / 网络（Token 错了最常见）。"
    echo "   没装任何东西，可以重来。"
    return 1
  fi
  echo "✅ 测试消息发出去了，请去 Telegram 确认收到。"
  printf "BOT_TOKEN='%s'\nCHAT_ID='%s'\n" "$token" "$chat" > "$CONF"
  chmod 600 "$CONF"
  chown root:root "$CONF"
  install_notifier
  if ! grep -qsF "$NOTIFIER" "$PAM_FILE" 2>/dev/null; then
    printf '%s\n' "$PAM_LINE" >> "$PAM_FILE"
  fi
  echo ""
  echo "✅ 装好了。以后每次有人 SSH 登录，你都会收到提醒。"
  echo "   配置：$CONF（仅 root 可读）"
  echo "   通知脚本：$NOTIFIER"
  echo "   PAM 钩子：$PAM_FILE（optional，失败不影响登录）"
  echo "   注意：scp / sftp 传文件也会触发一条（那也是 SSH 登录）。"
  return 0
}

do_uninstall() {
  if [ -f "$PAM_FILE" ]; then
    sed -i "\|$NOTIFIER|d" "$PAM_FILE"
  fi
  rm -f "$NOTIFIER" "$CONF"
  echo "✅ 已卸载（PAM 钩子、通知脚本、配置都删了）。"
}

# --- 主流程 ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请用 root 跑这个脚本。"
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "❌ 没找到 curl，先装一下：apt install -y curl"
  exit 1
fi

echo "================================="
echo "  TG SSH 登录提醒"
echo "================================="
if is_installed; then
  echo "状态：已安装"
  echo "1. 发一条测试消息"
  echo "2. 重新配置（换 Token / 用户 ID）"
  echo "3. 卸载"
  echo "0. 返回"
  read -rp "请选择 [0-3]: " c
  case "$c" in
    1)
      # shellcheck disable=SC1090
      . "$CONF"
      if send_test "$BOT_TOKEN" "$CHAT_ID"; then
        echo "✅ 测试消息发出去了。"
      else
        echo "❌ 没发出去，请检查 Token / 网络。"
      fi
      ;;
    2) do_install ;;
    3) do_uninstall ;;
    0) echo "返回。" ;;
    "") ;;  # 空输入：手机端易误触回车，直接重显，不报错
    *) echo "无效选项。" ;;
  esac
else
  echo "状态：未安装"
  echo "装好之后，每次有人 SSH 登录你的 VPS，Telegram 就会收到一条提醒"
  echo "（服务器、登录用户、来源 IP、时间）。"
  echo ""
  read -rp "现在安装吗？(Y/N): " yn
  case "$yn" in
    [Yy]*) do_install ;;
    *) echo "已取消，什么都没改。" ;;
  esac
fi
