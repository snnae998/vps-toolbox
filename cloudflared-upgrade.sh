#!/bin/bash
# cloudflared 全场景通用平滑升级脚本 v3.4
#
# 覆盖：Docker Run / Docker Compose / Systemd（二进制与包）/ OpenRC（二进制与包）/ 纯二进制
#
# v3.4 深度强化（基于 v3.3）：
#   - 并发锁保护：支持 flock / mkdir 原子锁，防止 cron 与人工并发执行踩踏。
#   - 无 jq 也能做 SHA-256 校验：内置 python3 / POSIX awk JSON 解析回退，最小化系统同样校验官方 digest。
#   - Docker 完整保真：
#       * 保留端口绑定的 HostIP（防 127.0.0.1 意外暴露到 0.0.0.0）；
#       * 兼容 host / none / container:<id> 网络模式；
#       * 识别 com.docker.compose.project.config_files，compose 分支先 pull 再 up -d。
#   - Systemd / OpenRC 深度兼容：
#       * 正确剥离 ExecStart 所有 systemd 前缀（- + ! !! @ ~ :）；
#       * 继承 WorkingDirectory=，避免相对路径 config.yml / cert.pem 找不到；
#       * 支持 OpenRC 软链多实例（/etc/init.d/cloudflared.<name>）；
#       * 多服务/多容器不再盲猜第一个，支持 --service / --container 显式指定。
#   - 磁盘安全：每次备份后自动清理历史旧备份，仅保留最近 3 份 .bak-*。
#
# v3.4 修复（2026-11-26，审计算出的 6 处）：
#   - setpriv 的 --regid 只认数字 GID（传名字报 failed to parse），先用
#     id -u/-g 转成数字再传（v3.3 就有的回归，v3.2 用 su 时没这问题）；
#   - python3 兜底去掉 f-string（表达式里写 \" 在各版本 Python 上都是
#     SyntaxError，改字符串拼接）；awk 兜底加单 asset 校验，块横跨多个
#     asset 时返回空、不给错的 digest；
#   - 补上审计文案提到但漏实现的 --skip-version-check；
#   - 纯二进制那条路替换前也备份并清理；--service 指定了但 systemctl
#     看不到 unit 时，从文件兜底 SERVICE_NAME，保证正式服务会被重启。
#
# 测试钩子（仅供测试）：CLOUDFLARED_TEST_SERVICE_DIR 指定 service 文件所在目录，
# CLOUDFLARED_TEST_INITD 指定 OpenRC init 脚本路径。正常使用无需设置。
set -euo pipefail

TEMP_PID=""
TEMP_CONTAINER=""
TMP_BIN=""
TMP_LOG=""
STAGED_BIN=""
LOCK_DIR="/tmp/cloudflared-upgrade.lock"
LOCK_HELD=0

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] [WARN] $*" >&2; }

cleanup() {
  if [ -n "$TEMP_PID" ] && kill -0 "$TEMP_PID" 2>/dev/null; then
    kill -15 "$TEMP_PID" 2>/dev/null || true
  fi
  if [ -n "$TEMP_CONTAINER" ]; then
    docker rm -f "$TEMP_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [ -n "$TMP_BIN" ] && [ -e "$TMP_BIN" ]; then
    rm -f "$TMP_BIN"
  fi
  if [ -n "$STAGED_BIN" ] && [ -e "$STAGED_BIN" ]; then
    rm -f "$STAGED_BIN"
  fi
  if [ -n "$TMP_LOG" ] && [ -e "$TMP_LOG" ]; then
    rm -f "$TMP_LOG"
  fi
  if [ "$LOCK_HELD" = "1" ] && [ -d "$LOCK_DIR" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

MODE=auto
DRY_RUN=0
SKIP_VERSION_CHECK=0
TARGET_SERVICE=""
TARGET_CONTAINER=""
GH_MIRROR="${GH_MIRROR:-https://ghfast.top}"
KEEP_BACKUPS=3

usage() {
  cat <<'EOF'
Usage: sudo ./cloudflared-upgrade.sh [options]

Options:
  --mode auto|docker|systemd   Deployment mode (default: auto; stops on ambiguity)
  --service <name>             Explicit systemd/OpenRC service name (e.g. cloudflared@web)
  --container <name|id>        Explicit Docker container name or ID
  --mirror <url>               Fallback GitHub mirror prefix (default: https://ghfast.top, "" to disable)
  --skip-version-check         Skip the "already latest" early exit (force reinstall/upgrade)
  --dry-run                    Print planned actions without changing anything
  -h, --help                   Show this help message
EOF
}

while (($#)); do
  case "$1" in
    --mode)      (($# >= 2)) || { echo "--mode 需要一个值。" >&2; exit 1; }; MODE=$2; shift 2 ;;
    --service)   (($# >= 2)) || { echo "--service 需要一个值。" >&2; exit 1; }; TARGET_SERVICE=$2; shift 2 ;;
    --container) (($# >= 2)) || { echo "--container 需要一个值。" >&2; exit 1; }; TARGET_CONTAINER=$2; shift 2 ;;
    --mirror)    (($# >= 2)) || { echo "--mirror 需要一个值。" >&2; exit 1; }; GH_MIRROR=$2; shift 2 ;;
    --skip-version-check) SKIP_VERSION_CHECK=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done
case "$MODE" in
  auto|docker|systemd) ;;
  *) echo "不支持的模式：$MODE" >&2; exit 1 ;;
esac

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 权限或 sudo 运行此脚本。"
  exit 1
fi

acquire_lock() {
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "检测到另一个 cloudflared 升级进程正在运行（锁目录：$LOCK_DIR）。" >&2
    echo "如确认无残留进程，可执行 rmdir $LOCK_DIR 后重试。" >&2
    exit 1
  fi
  LOCK_HELD=1
}
acquire_lock

log "=========================================="
log "    Cloudflared 全场景平滑升级 v3.4"
if [ "$DRY_RUN" = "1" ]; then
  log "    [dry-run 演练模式，不做任何改动]"
fi
log "=========================================="

split_words() {
  local -n _out="$1"; shift
  _out=()
  local el word
  local _noglob=0
  case "$-" in *f*) _noglob=1 ;; esac
  set -f
  for el in "$@"; do
    # shellcheck disable=SC2086
    for word in $el; do _out+=("$word"); done
  done
  [ "$_noglob" = "0" ] && set +f
}

parse_cmd_args() {
  local raw="$1"
  local -n _arr="$2"
  _arr=()
  local i=0 len=${#raw} ch quote="" cur="" has_token=0

  while [ "$i" -lt "$len" ]; do
    ch="${raw:$i:1}"
    if [ -n "$quote" ]; then
      if [ "$ch" = "$quote" ]; then
        quote=""
      elif [ "$quote" = '"' ] && [ "$ch" = '\' ] && [ $((i + 1)) -lt "$len" ]; then
        i=$((i + 1))
        cur+="${raw:$i:1}"
      else
        cur+="$ch"
      fi
      has_token=1
    else
      case "$ch" in
        "'"|'"')
          quote="$ch"
          has_token=1
          ;;
        '\')
          if [ $((i + 1)) -lt "$len" ]; then
            i=$((i + 1))
            cur+="${raw:$i:1}"
            has_token=1
          fi
          ;;
        [[:space:]])
          if [ "$has_token" -eq 1 ]; then
            _arr+=("$cur")
            cur=""
            has_token=0
          fi
          ;;
        *)
          cur+="$ch"
          has_token=1
          ;;
      esac
    fi
    i=$((i + 1))
  done

  if [ -n "$quote" ]; then
    return 1
  fi
  if [ "$has_token" -eq 1 ]; then
    _arr+=("$cur")
  fi
  return 0
}

wait_for_registration() {
  local logfile="$1" timeout="$2" pid="${3:-}" i=0
  while [ "$i" -lt "$timeout" ]; do
    if [ -f "$logfile" ] && grep -q "Registered tunnel connection" "$logfile" 2>/dev/null; then
      return 0
    fi
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

atomic_replace_bin() {
  local src="$1" dst="$2" keep="${3:-}"
  local dst_dir
  dst_dir="$(dirname "$dst")"
  STAGED_BIN="${dst_dir}/.cloudflared.stage.$$"
  cp -f "$src" "$STAGED_BIN"
  chmod 755 "$STAGED_BIN"
  mv -f "$STAGED_BIN" "$dst"
  STAGED_BIN=""
  if [ -z "$keep" ]; then
    rm -f "$src"
  fi
}

prune_old_backups() {
  local bin_path="$1"
  local idx=0 f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    idx=$((idx + 1))
    if [ "$idx" -gt "$KEEP_BACKUPS" ]; then
      rm -f "$f" 2>/dev/null || true
    fi
  done < <(ls -1t "${bin_path}.bak-"* 2>/dev/null || true)
}

start_temp_process() {
  local bin_path="$1"
  local run_user="$2"
  local work_dir="$3"
  local logfile="$4"
  shift 4
  local args=("$@")

  (
    if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
      cd "$work_dir" || exit 1
    fi
    if [ -n "$run_user" ] && id "$run_user" >/dev/null 2>&1; then
      # setpriv 的 --regid 只认数字 GID（传名字会报 failed to parse），
      # 先用 id 转成数字再传；--init-groups 会按 UID 查用户组。
      if command -v setpriv >/dev/null 2>&1; then
        local run_uid run_gid
        run_uid=$(id -u "$run_user" 2>/dev/null || true)
        run_gid=$(id -g "$run_user" 2>/dev/null || true)
        if [ -n "$run_uid" ] && [ -n "$run_gid" ]; then
          exec setpriv --reuid="$run_uid" --regid="$run_gid" --init-groups "$bin_path" "${args[@]}"
        fi
      fi
      if command -v runuser >/dev/null 2>&1; then
        exec runuser -u "$run_user" -- "$bin_path" "${args[@]}"
      elif command -v su >/dev/null 2>&1; then
        local quoted_cmd
        quoted_cmd="$(printf '%q ' "$bin_path" "${args[@]}")"
        exec su -s /bin/sh "$run_user" -c "$quoted_cmd"
      fi
    fi
    exec "$bin_path" "${args[@]}"
  ) > "$logfile" 2>&1 &
}

# 从 GitHub Release API JSON 中提取指定 asset 的 digest 与 browser_download_url
# 支持 jq -> python3 -> POSIX awk 三级降级，不强依赖 jq
parse_github_release_asset() {
  local json="$1" asset="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg a "$asset" '
      .assets[] | select(.name == $a) |
      (.digest // "") + "\t" + (.browser_download_url // "")
    ' | head -n 1
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import json, sys
asset = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get("assets", []):
    if item.get("name") == asset:
        # 不用 f-string：f-string 表达式里写 \" 在各版本 Python 上都会报
        # SyntaxError（unexpected character after line continuation character）。
        print((item.get("digest") or "") + "\t" + (item.get("browser_download_url") or ""))
        break
' "$asset" 2>/dev/null
    return 0
  fi

  # 纯 awk 兜底：按 "name": 解析每个 asset 对象块
  printf '%s' "$json" | tr '\n' ' ' | sed 's/{"url":/\n{"url":/g' | awk -v target="\"name\": *\"$asset\"" '
    $0 ~ target {
      # 块里只能有一个 "name": 字段；多于一个说明切分失败（块横跨多个 asset，
      # 比如字段顺序变了），宁可返回空也不给错的 digest。
      if (gsub(/"name":/, "&") != 1) next
      digest = ""
      url = ""
      if (match($0, /"digest": *"sha256:[a-fA-F0-9]{64}"/)) {
        digest = substr($0, RSTART, RLENGTH)
        sub(/^"digest": *"/, "", digest)
        sub(/"$/, "", digest)
      }
      if (match($0, /"browser_download_url": *"https:\/\/[^"]+"/)) {
        url = substr($0, RSTART, RLENGTH)
        sub(/^"browser_download_url": *"/, "", url)
        sub(/"$/, "", url)
      }
      if (url != "") {
        print digest "\t" url
        exit
      }
    }
  '
}

# ============================================================
# 模式一：Docker 容器部署
# ============================================================
DOCKER_IDS=""
if { [ "$MODE" = "auto" ] || [ "$MODE" = "docker" ]; } && [ -z "$TARGET_SERVICE" ] && command -v docker >/dev/null 2>&1; then
  if [ -n "$TARGET_CONTAINER" ]; then
    DOCKER_IDS=$(docker inspect --format '{{.Id}}' "$TARGET_CONTAINER" 2>/dev/null || true)
    if [ -z "$DOCKER_IDS" ]; then
      log "未找到指定的 Docker 容器：$TARGET_CONTAINER"
      exit 1
    fi
  else
    DOCKER_IDS=$( { docker ps -q --filter "ancestor=cloudflare/cloudflared" 2>/dev/null; docker ps -q --filter "name=cloudflared" 2>/dev/null; } | sort -u )
  fi
fi

SYSTEMD_ACTIVE=false
if [ -z "$TARGET_CONTAINER" ] && command -v systemctl >/dev/null 2>&1; then
  if systemctl list-units --type=service --state=active --no-legend 2>/dev/null | awk '{print $1}' | grep -qE '^cloudflared([-@.].*)?\.service$'; then
    SYSTEMD_ACTIVE=true
  fi
fi

if [ "$MODE" = "auto" ] && [ -z "$TARGET_CONTAINER" ] && [ -z "$TARGET_SERVICE" ] && [ -n "$DOCKER_IDS" ] && [ "$SYSTEMD_ACTIVE" = true ]; then
  log "同时检测到 Docker 容器与 systemd 服务在跑，无法判断升级哪一个。"
  log "请用 --mode docker 或 --mode systemd（或 --container / --service）显式指定后重试。"
  exit 1
fi

CONTAINER_ID=""
if [ -n "$DOCKER_IDS" ]; then
  DOCKER_COUNT=$(printf '%s\n' "$DOCKER_IDS" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$DOCKER_COUNT" != "1" ]; then
    log "检测到 $DOCKER_COUNT 个 cloudflared 容器，不猜升级哪一个："
    while IFS= read -r id; do
      [ -n "$id" ] && docker inspect "$id" --format '{{.ID}} {{.Name}}' 2>/dev/null || true
    done <<< "$DOCKER_IDS"
    log "请使用 --container <名称或ID> 指定后重试。"
    exit 1
  fi
  CONTAINER_ID=$(printf '%s\n' "$DOCKER_IDS" | head -n 1)
fi

if [ -n "$CONTAINER_ID" ]; then
  CONTAINER_NAME=$(docker inspect "$CONTAINER_ID" --format '{{.Name}}' | sed 's/^\///')
  IMAGE_NAME=$(docker inspect "$CONTAINER_ID" --format '{{.Config.Image}}')

  IMAGE_BASE="${IMAGE_NAME%%@*}"
  if [[ "${IMAGE_BASE##*/}" == *:* ]]; then
    REPO="${IMAGE_BASE%:*}"
  else
    REPO="$IMAGE_BASE"
  fi
  TARGET_IMAGE="${REPO}:latest"

  log "检测到部署方式：Docker 容器（名称：$CONTAINER_NAME，ID：${CONTAINER_ID:0:12}）"

  CMD_ARR=()
  while IFS= read -r line; do CMD_ARR+=("$line"); done < <(docker inspect "$CONTAINER_ID" --format '{{range .Config.Cmd}}{{println .}}{{end}}')
  EP_ARR=()
  while IFS= read -r line; do EP_ARR+=("$line"); done < <(docker inspect "$CONTAINER_ID" --format '{{range .Config.Entrypoint}}{{println .}}{{end}}')
  split_words EP_ARR "${EP_ARR[@]}"
  EP_STR=""
  if [ "${#EP_ARR[@]}" -gt 0 ]; then
    EP_STR="$(printf '%s ' "${EP_ARR[@]}")"
    EP_STR="${EP_STR% }"
  fi
  EP_ENTRYPOINT=()
  if [ -n "$EP_STR" ] && [ "$EP_STR" != "cloudflared --no-autoupdate" ]; then
    EP_ENTRYPOINT=(--entrypoint "${EP_ARR[0]}")
    CMD_ARR=("${EP_ARR[@]:1}" "${CMD_ARR[@]}")
  fi
  split_words CMD_ARR "${CMD_ARR[@]}"
  if [ "${CMD_ARR[0]:-}" = "cloudflared" ]; then
    CMD_ARR=("${CMD_ARR[@]:1}")
  fi

  ENV_ARGS=()
  while IFS= read -r line; do
    [ -n "$line" ] && ENV_ARGS+=("-e" "$line")
  done < <(docker inspect "$CONTAINER_ID" --format '{{range .Config.Env}}{{println .}}{{end}}')

  VOL_ARGS=()
  while IFS='|' read -r mtype msrc mdst mrw; do
    mtype="$(echo "$mtype" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    msrc="$(echo "$msrc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    mdst="$(echo "$mdst" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    mrw="$(echo "$mrw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$mtype" ] && continue
    case "$mtype" in
      bind|volume) [ "$mrw" = "false" ] && VOL_ARGS+=("-v" "${msrc}:${mdst}:ro") || VOL_ARGS+=("-v" "${msrc}:${mdst}") ;;
      tmpfs) VOL_ARGS+=(--tmpfs "$mdst") ;;
      *) log "跳过未知挂载类型：$mtype $mdst" ;;
    esac
  done < <(docker inspect "$CONTAINER_ID" --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW}}{{end}}')

  # 完整保留 HostIp（如 127.0.0.1），避免本地端口意外暴露到公网 0.0.0.0
  PORT_ARGS=()
  while IFS='|' read -r cport hip hport; do
    cport="$(echo "$cport" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    hip="$(echo "$hip" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    hport="$(echo "$hport" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$cport" ] && continue
    if [ -n "$hport" ]; then
      if [ -n "$hip" ] && [ "$hip" != "0.0.0.0" ] && [ "$hip" != "::" ]; then
        [[ "$hip" == *:* ]] && hip="[$hip]"
        PORT_ARGS+=("-p" "${hip}:${hport}:${cport}")
      else
        PORT_ARGS+=("-p" "${hport}:${cport}")
      fi
    else
      PORT_ARGS+=("-p" "$cport")
    fi
  done < <(docker inspect "$CONTAINER_ID" --format '{{range $cport, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println $cport "|" .HostIp "|" .HostPort}}{{end}}{{end}}')

  RESTART_POLICY=$(docker inspect "$CONTAINER_ID" --format '{{.HostConfig.RestartPolicy.Name}}')
  RESTART_MAX=$(docker inspect "$CONTAINER_ID" --format '{{.HostConfig.RestartPolicy.MaximumRetryCount}}')
  RESTART_ARG="no"
  if [ -n "$RESTART_POLICY" ] && [ "$RESTART_POLICY" != "no" ]; then
    if [ "$RESTART_POLICY" = "on-failure" ] && [ -n "$RESTART_MAX" ] && [ "$RESTART_MAX" != "0" ]; then
      RESTART_ARG="on-failure:${RESTART_MAX}"
    else
      RESTART_ARG="$RESTART_POLICY"
    fi
  fi

  NETWORK_MODE=$(docker inspect "$CONTAINER_ID" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)
  NETWORKS=$(docker inspect "$CONTAINER_ID" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')
  PRIMARY_NET=""
  OTHER_NETS=""
  if [[ "$NETWORK_MODE" == host || "$NETWORK_MODE" == none || "$NETWORK_MODE" == container:* ]]; then
    PRIMARY_NET="$NETWORK_MODE"
    # host / none / container: 模式下不能传 -p
    PORT_ARGS=()
  else
    PRIMARY_NET=$(echo "$NETWORKS" | awk '{print $1}')
    OTHER_NETS=$(echo "$NETWORKS" | awk '{for (i=2; i<=NF; i++) if ($i != $1) printf "%s ", $i}')
  fi

  COMPOSE_DIR=$(docker inspect "$CONTAINER_ID" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
  COMPOSE_SERVICE=$(docker inspect "$CONTAINER_ID" --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null || true)
  COMPOSE_FILES=$(docker inspect "$CONTAINER_ID" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null || true)
  [ "$COMPOSE_DIR" = "<no value>" ] && COMPOSE_DIR=""
  [ "$COMPOSE_SERVICE" = "<no value>" ] && COMPOSE_SERVICE=""
  [ "$COMPOSE_FILES" = "<no value>" ] && COMPOSE_FILES=""

  IS_COMPOSE=false
  if [ -n "$COMPOSE_DIR" ] && [ -d "$COMPOSE_DIR" ] && [ -n "$COMPOSE_SERVICE" ]; then
    IS_COMPOSE=true
  fi

  if [ "${#CMD_ARR[@]}" -eq 0 ]; then
    log "旧容器没有启动参数，无法安全重建。请检查容器配置后重试。"
    exit 1
  fi

  CURRENT_VER=$(docker exec "$CONTAINER_ID" cloudflared --version 2>/dev/null | awk '{print $3}' || true)
  log "当前运行版本：${CURRENT_VER:-未知}"
  log "已捕获配置：启动参数 ${#CMD_ARR[@]} 个，挂载 $(( ${#VOL_ARGS[@]} / 2 )) 个，端口 $(( ${#PORT_ARGS[@]} / 2 )) 个，网络：${PRIMARY_NET:-默认}，重启策略：$RESTART_ARG"

  COMPOSE_FILE_ARGS=()
  if [ -n "$COMPOSE_FILES" ]; then
    IFS=',' read -ra _cfiles <<< "$COMPOSE_FILES"
    for cf in "${_cfiles[@]}"; do
      [ -f "$cf" ] && COMPOSE_FILE_ARGS+=("-f" "$cf")
    done
  fi

  if [ "$DRY_RUN" = "1" ]; then
    if [ "$IS_COMPOSE" = true ]; then
      log "[dry-run] 将执行：cd $COMPOSE_DIR && docker compose ${COMPOSE_FILE_ARGS[*]} pull $COMPOSE_SERVICE && docker compose ${COMPOSE_FILE_ARGS[*]} up -d --no-deps $COMPOSE_SERVICE"
      log "[dry-run] 注意：Compose 重建会先停旧容器再起新容器，隧道会中断几秒，且无法自动回滚。"
    else
      log "[dry-run] 将执行：拉取 $TARGET_IMAGE，启动并行容器（--restart no），注册隧道后 stop/rm 旧容器、rename 新容器并恢复重启策略（$RESTART_ARG）。"
      printf '+ docker run -d --name cloudflared-new-staging --restart no'
      for a in "${ENV_ARGS[@]}" "${VOL_ARGS[@]}" "${PORT_ARGS[@]}"; do printf ' %q' "$a"; done
      [ -n "$PRIMARY_NET" ] && printf ' --network %q' "$PRIMARY_NET"
      for a in "${EP_ENTRYPOINT[@]}"; do printf ' %q' "$a"; done
      printf ' %s' "$TARGET_IMAGE"
      prev=""
      for a in "${CMD_ARR[@]}"; do
        case "$a" in
          --token=*) printf ' %s' "--token=***" ;;
          *) if [ "$prev" = "--token" ]; then printf ' %s' "***"; else printf ' %q' "$a"; fi ;;
        esac
        prev="$a"
      done
      printf '\n'
    fi
    log "[dry-run] 演练结束，未做任何改动。"
    exit 0
  fi

  # ---- 分支 A：Docker Compose 管理 ----
  if [ "$IS_COMPOSE" = true ]; then
    log "检测到 Docker Compose 项目（$COMPOSE_DIR，服务：$COMPOSE_SERVICE），原生拉取并重建。"
    log "注意：Compose 重建会先停旧容器再起新容器，隧道会中断几秒；且 compose 不保留旧容器，无法自动回滚。"
    OLD_IMAGE_REF=$(docker inspect "$CONTAINER_ID" --format '{{.Image}}' 2>/dev/null || true)
    cd "$COMPOSE_DIR" || { log "无法进入 Compose 目录：$COMPOSE_DIR"; exit 1; }
    if docker compose version >/dev/null 2>&1; then
      docker compose "${COMPOSE_FILE_ARGS[@]}" pull "$COMPOSE_SERVICE"
      docker compose "${COMPOSE_FILE_ARGS[@]}" up -d --no-deps "$COMPOSE_SERVICE"
    elif command -v docker-compose >/dev/null 2>&1; then
      docker-compose "${COMPOSE_FILE_ARGS[@]}" pull "$COMPOSE_SERVICE"
      docker-compose "${COMPOSE_FILE_ARGS[@]}" up -d --no-deps "$COMPOSE_SERVICE"
    else
      log "未找到 docker compose / docker-compose，停止。"
      exit 1
    fi
    sleep 3
    NEW_ID=$(docker ps -q --filter "label=com.docker.compose.service=$COMPOSE_SERVICE" --filter "label=com.docker.compose.project.working_dir=$COMPOSE_DIR" 2>/dev/null | head -n 1 || true)
    [ -z "$NEW_ID" ] && NEW_ID=$(docker ps -q --filter "name=$COMPOSE_SERVICE" 2>/dev/null | head -n 1 || true)
    if [ -z "$NEW_ID" ]; then
      log "Compose 重建后找不到容器，升级失败。旧镜像：${OLD_IMAGE_REF:-未知}，请手动检查。"
      exit 1
    fi
    TMP_LOG="/tmp/cloudflared-compose-$$.log"
    HEALTHY=0
    for _ in $(seq 1 90); do
      docker logs "$NEW_ID" > "$TMP_LOG" 2>&1 || true
      if grep -q "Registered tunnel connection" "$TMP_LOG" 2>/dev/null; then HEALTHY=1; break; fi
      if [ "$(docker inspect "$NEW_ID" --format '{{.State.Status}}' 2>/dev/null)" != "running" ]; then break; fi
      sleep 1
    done
    rm -f "$TMP_LOG"; TMP_LOG=""
    FINAL_VER=$(docker exec "$NEW_ID" cloudflared --version 2>/dev/null | awk '{print $3}' || true)
    if [ "$HEALTHY" = "1" ]; then
      log "=========================================="
      log "Compose 平滑升级完成：${CURRENT_VER:-未知} -> ${FINAL_VER:-未知}"
      log "=========================================="
      exit 0
    else
      log "新容器未注册隧道连接，升级失败。旧镜像：${OLD_IMAGE_REF:-未知}，请手动回滚（将 compose 文件镜像 tag 改回旧版后 up -d）。"
      exit 1
    fi
  fi

  # ---- 分支 B：Docker Run（并行容器 + 健康门 + 回滚）----
  log "拉取最新镜像（$TARGET_IMAGE）..."
  docker pull "$TARGET_IMAGE" >/dev/null

  NEW_VER=$(docker run --rm "$TARGET_IMAGE" --version 2>/dev/null | awk '{print $3}' || true)
  if [ -z "$NEW_VER" ]; then
    log "无法读取最新镜像版本，停止。"
    exit 1
  fi
  log "最新镜像版本：$NEW_VER"
  if [ "$SKIP_VERSION_CHECK" = "0" ] && [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" = "$NEW_VER" ]; then
    log "已是最新版本（$CURRENT_VER），无需升级。"
    exit 0
  fi

  NEW_CONTAINER="cloudflared-new-$$"
  docker rm -f "$NEW_CONTAINER" >/dev/null 2>&1 || true

  NET_ARGS=()
  [ -n "$PRIMARY_NET" ] && NET_ARGS=(--network "$PRIMARY_NET")

  log "启动新容器 $NEW_CONTAINER（与旧容器并行，过渡期 --restart no）..."
  docker run -d --name "$NEW_CONTAINER" --restart no \
    "${ENV_ARGS[@]}" "${VOL_ARGS[@]}" "${PORT_ARGS[@]}" \
    "${NET_ARGS[@]}" \
    "${EP_ENTRYPOINT[@]}" \
    "$TARGET_IMAGE" "${CMD_ARR[@]}" >/dev/null
  TEMP_CONTAINER="$NEW_CONTAINER"

  for net in $OTHER_NETS; do
    [ -n "$net" ] && docker network connect "$net" "$NEW_CONTAINER" >/dev/null 2>&1 || true
  done

  log "等待新容器注册隧道连接（最长 90 秒）..."
  HEALTHY=0
  EXITED=0
  for _ in $(seq 1 90); do
    if docker logs "$NEW_CONTAINER" 2>&1 | grep -q "Registered tunnel connection"; then
      HEALTHY=1
      break
    fi
    if [ "$(docker inspect "$NEW_CONTAINER" --format '{{.State.Status}}' 2>/dev/null)" != "running" ]; then
      EXITED=1
      break
    fi
    sleep 1
  done

  if [ "$HEALTHY" != "1" ]; then
    if [ "$EXITED" = "1" ]; then
      log "新容器已退出（启动失败），保留旧容器，回滚。"
    else
      log "新容器未在 90 秒内注册隧道连接，保留旧容器，回滚。"
    fi
    docker logs "$NEW_CONTAINER" --tail 30 2>&1 || true
    docker rm -f "$NEW_CONTAINER" >/dev/null 2>&1 || true
    TEMP_CONTAINER=""
    exit 1
  fi

  log "新容器已注册隧道，切换流量..."
  docker stop "$CONTAINER_ID" >/dev/null
  docker rm "$CONTAINER_ID" >/dev/null
  docker rename "$NEW_CONTAINER" "$CONTAINER_NAME" >/dev/null
  if [ "$RESTART_ARG" != "no" ]; then
    docker update --restart="$RESTART_ARG" "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  TEMP_CONTAINER=""

  FINAL_VER=$(docker exec "$CONTAINER_NAME" cloudflared --version 2>/dev/null | awk '{print $3}' || true)
  log "=========================================="
  log "Docker 平滑升级完成：${CURRENT_VER:-未知} -> ${FINAL_VER:-$NEW_VER}（零中断）"
  log "=========================================="
  exit 0
fi

# ============================================================
# 模式二：宿主机原生部署（Systemd / OpenRC / 纯二进制）
# ============================================================
SERVICE_FILE=""
SERVICE_SEARCH_DIRS="/etc/systemd/system /lib/systemd/system /usr/lib/systemd/system"
if [ -n "${CLOUDFLARED_TEST_SERVICE_DIR:-}" ]; then
  SERVICE_SEARCH_DIRS="$CLOUDFLARED_TEST_SERVICE_DIR $SERVICE_SEARCH_DIRS"
fi

USE_SYSTEMD=false
SERVICE_NAME=""
if [ -n "$TARGET_SERVICE" ]; then
  # 用户显式指定服务名（支持带或不带 .service 后缀，支持模板实例 cloudflared@foo）
  CLEAN_SVC="${TARGET_SERVICE%.service}"
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "${CLEAN_SVC}.service" >/dev/null 2>&1 || systemctl status "${CLEAN_SVC}.service" >/dev/null 2>&1; then
    USE_SYSTEMD=true
    SERVICE_NAME="$CLEAN_SVC"
  fi
  for d in $SERVICE_SEARCH_DIRS; do
    if [ -f "$d/${CLEAN_SVC}.service" ]; then
      SERVICE_FILE="$d/${CLEAN_SVC}.service"
      break
    elif [[ "$CLEAN_SVC" == *@* ]] && [ -f "$d/${CLEAN_SVC%%@*}@.service" ]; then
      SERVICE_FILE="$d/${CLEAN_SVC%%@*}@.service"
      break
    fi
  done
  # 文件找到了但 systemctl 看不到它（例如放在测试目录或非标准路径）时，
  # 也按 systemd 服务处理，否则正式服务不会被重启。
  if [ -n "$SERVICE_FILE" ] && [ -z "$SERVICE_NAME" ]; then
    USE_SYSTEMD=true
    SERVICE_NAME="$CLEAN_SVC"
  fi
else
  # 自动探测：若存在多个不同的 service 文件，拒绝猜测
  FOUND_SERVICES=()
  for d in $SERVICE_SEARCH_DIRS; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      bname="$(basename "$f")"
      # 跳过模板文件本身（带 @.service 的非实例文件），优先匹配已实例化或普通 unit
      [[ "$bname" == *@.service ]] && continue
      already=0
      for existing in "${FOUND_SERVICES[@]:-}"; do
        [ "$(basename "$existing")" = "$bname" ] && already=1 && break
      done
      [ "$already" -eq 0 ] && FOUND_SERVICES+=("$f")
    done < <(find "$d" -maxdepth 1 -name 'cloudflared*.service' 2>/dev/null | sort || true)
  done

  if [ "${#FOUND_SERVICES[@]}" -gt 1 ]; then
    log "检测到多个 cloudflared systemd 服务文件，不猜升级哪一个："
    for f in "${FOUND_SERVICES[@]}"; do log "  - $(basename "$f") ($f)"; done
    log "请使用 --service <服务名> 显式指定后重试。"
    exit 1
  elif [ "${#FOUND_SERVICES[@]}" -eq 1 ]; then
    SERVICE_FILE="${FOUND_SERVICES[0]}"
  fi

  if [ -n "$SERVICE_FILE" ] && command -v systemctl >/dev/null 2>&1; then
    USE_SYSTEMD=true
    SERVICE_NAME=$(basename "$SERVICE_FILE" .service)
  fi
fi

OPENRC_SERVICE=""
OPENRC_SERVICE_NAME="cloudflared"
if [ -n "${CLOUDFLARED_TEST_INITD:-}" ]; then
  if [ -f "$CLOUDFLARED_TEST_INITD" ] && command -v rc-service >/dev/null 2>&1; then
    OPENRC_SERVICE="$CLOUDFLARED_TEST_INITD"
    OPENRC_SERVICE_NAME="$(basename "$OPENRC_SERVICE")"
  fi
elif [ "$USE_SYSTEMD" = false ] && command -v rc-service >/dev/null 2>&1; then
  if [ -n "$TARGET_SERVICE" ]; then
    if [ -f "/etc/init.d/$TARGET_SERVICE" ]; then
      OPENRC_SERVICE="/etc/init.d/$TARGET_SERVICE"
      OPENRC_SERVICE_NAME="$TARGET_SERVICE"
    fi
  else
    OPENRC_CANDS=()
    for f in /etc/init.d/cloudflared*; do
      [ -f "$f" ] && OPENRC_CANDS+=("$f")
    done
    if [ "${#OPENRC_CANDS[@]}" -gt 1 ]; then
      log "检测到多个 OpenRC cloudflared 服务，不猜升级哪一个："
      for f in "${OPENRC_CANDS[@]}"; do log "  - $(basename "$f")"; done
      log "请使用 --service <服务名> 显式指定后重试。"
      exit 1
    elif [ "${#OPENRC_CANDS[@]}" -eq 1 ]; then
      OPENRC_SERVICE="${OPENRC_CANDS[0]}"
      OPENRC_SERVICE_NAME="$(basename "$OPENRC_SERVICE")"
    fi
  fi
fi

if [ -n "$TARGET_SERVICE" ] && [ "$USE_SYSTEMD" = false ] && [ -z "$OPENRC_SERVICE" ]; then
  log "未找到指定的服务：$TARGET_SERVICE"
  exit 1
fi

BIN_PATH=$(command -v cloudflared 2>/dev/null || true)
if [ -z "$BIN_PATH" ]; then
  for p in /usr/local/bin/cloudflared /usr/bin/cloudflared; do
    [ -x "$p" ] && BIN_PATH="$p" && break
  done
fi

USE_OPENRC=false
if [ "$USE_SYSTEMD" = false ] && [ -n "$OPENRC_SERVICE" ]; then
  USE_OPENRC=true
fi

read_unit_text() {
  if [ "$USE_SYSTEMD" = true ]; then
    systemctl cat "$SERVICE_NAME" 2>/dev/null || { [ -n "$SERVICE_FILE" ] && cat "$SERVICE_FILE"; }
  elif [ -n "$SERVICE_FILE" ]; then
    cat "$SERVICE_FILE"
  else
    echo ""
  fi
}

openrc_value() {
  grep -E "^$1=" "$OPENRC_SERVICE" 2>/dev/null | head -n 1 | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

load_systemd_env() {
  local unit_text="$1" line rest token key val
  while IFS= read -r line; do
    case "$line" in
      EnvironmentFile=*)
        rest="${line#EnvironmentFile=}"
        rest="${rest#-}"
        rest="${rest%\"}"; rest="${rest#\"}"
        rest="${rest%\'}"; rest="${rest#\'}"
        if [ -n "$rest" ] && [ -f "$rest" ]; then
          while IFS= read -r eline || [ -n "$eline" ]; do
            eline="${eline#"${eline%%[![:space:]]*}"}"
            [ -z "$eline" ] && continue
            case "$eline" in \#*) continue ;; esac
            eline="${eline#export }"
            if [[ "$eline" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
              key="${eline%%=*}"
              val="${eline#*=}"
              val="${val%\"}"; val="${val#\"}"
              val="${val%\'}"; val="${val#\'}"
              export "$key=$val"
            fi
          done < "$rest"
        fi
        ;;
      Environment=*)
        rest="${line#Environment=}"
        local env_tokens=()
        if parse_cmd_args "$rest" env_tokens; then
          for token in "${env_tokens[@]}"; do
            if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
              key="${token%%=*}"
              val="${token#*=}"
              export "$key=$val"
            fi
          done
        fi
        ;;
    esac
  done <<< "$unit_text"
}

svc_stop() {
  if [ "$USE_SYSTEMD" = true ]; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  elif [ "$USE_OPENRC" = true ]; then
    rc-service "$OPENRC_SERVICE_NAME" stop 2>/dev/null || true
  fi
}

svc_start() {
  if [ "$USE_SYSTEMD" = true ]; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl start "$SERVICE_NAME" 2>/dev/null || true
  elif [ "$USE_OPENRC" = true ]; then
    rc-service "$OPENRC_SERVICE_NAME" start 2>/dev/null || true
  fi
}

svc_is_active() {
  if [ "$USE_SYSTEMD" = true ]; then
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null
  elif [ "$USE_OPENRC" = true ]; then
    rc-service "$OPENRC_SERVICE_NAME" status >/dev/null 2>&1
  else
    return 1
  fi
}

if { [ "$MODE" = "auto" ] || [ "$MODE" = "systemd" ]; } && { [ -n "$SERVICE_FILE" ] || [ "$USE_SYSTEMD" = true ] || [ -n "$OPENRC_SERVICE" ] || [ -n "$BIN_PATH" ]; }; then
  if [ "$USE_SYSTEMD" = true ]; then
    log "检测到部署方式：宿主机 Systemd 服务（$SERVICE_NAME）"
  elif [ "$USE_OPENRC" = true ]; then
    log "检测到部署方式：宿主机 OpenRC 服务（$OPENRC_SERVICE_NAME）"
  else
    log "检测到部署方式：宿主机原生二进制（无服务文件）"
  fi

  if { [ "$USE_SYSTEMD" = true ] || [ "$USE_OPENRC" = true ]; } && ! svc_is_active; then
    log "服务未处于活动状态，拒绝升级。请先启动服务，或确认部署状态后重试。"
    exit 1
  fi

  UNIT_TEXT=$(read_unit_text)
  EXEC_LINE=$(printf '%s\n' "$UNIT_TEXT" | awk '/\\$/ { printf "%s", substr($0, 1, length($0)-1); next } { print }' | grep -E '^ExecStart=' | head -n 1 || true)
  EXEC_BIN=""
  TUNNEL_ARGS=""
  if [ -n "$EXEC_LINE" ]; then
    EXEC_VALUE="${EXEC_LINE#ExecStart=}"
    # 剥离 systemd 支持的 ExecStart 前缀修饰符（- + ! !! @ ~ :）
    while [[ "$EXEC_VALUE" =~ ^[-+!@~:] ]]; do
      EXEC_VALUE="${EXEC_VALUE:1}"
    done
    EXEC_VALUE="${EXEC_VALUE#"${EXEC_VALUE%%[![:space:]]*}"}"
    EXEC_BIN="${EXEC_VALUE%% *}"
    TUNNEL_ARGS="${EXEC_VALUE#* }"
    [ "$TUNNEL_ARGS" = "$EXEC_VALUE" ] && TUNNEL_ARGS=""
  fi
  OPENRC_BIN=""
  OPENRC_ARGS=""
  OPENRC_USER=""
  if [ -n "$OPENRC_SERVICE" ]; then
    OPENRC_BIN=$(openrc_value command || true)
    OPENRC_ARGS=$(openrc_value command_args || true)
    OPENRC_USER=$(openrc_value command_user || true)
    OPENRC_USER="${OPENRC_USER%%:*}"
  fi
  if [ -n "$EXEC_BIN" ]; then
    case "$EXEC_BIN" in
      */*) BIN_PATH="$EXEC_BIN" ;;
      *) BIN_PATH=$(command -v "$EXEC_BIN" 2>/dev/null || echo "/usr/local/bin/$EXEC_BIN") ;;
    esac
  elif [ -n "$OPENRC_BIN" ]; then
    case "$OPENRC_BIN" in
      */*) BIN_PATH="$OPENRC_BIN" ;;
      *) BIN_PATH=$(command -v "$OPENRC_BIN" 2>/dev/null || echo "/usr/local/bin/$OPENRC_BIN") ;;
    esac
  fi
  [ -z "$BIN_PATH" ] && BIN_PATH="/usr/local/bin/cloudflared"
  if [ -z "$TUNNEL_ARGS" ] && [ -n "$OPENRC_SERVICE" ] && [ -z "$SERVICE_FILE" ]; then
    TUNNEL_ARGS="$OPENRC_ARGS"
  fi

  CURRENT_VER=$("$BIN_PATH" --version 2>/dev/null | awk '{print $3}' || true)
  log "当前二进制路径：$BIN_PATH（版本：${CURRENT_VER:-未知}）"

  # ---- 分支 C：包管理器安装（APT/DPKG、YUM/DNF/RPM、APK）----
  PKG_MANAGED=false
  PKG_NAME=""
  PKG_TYPE=""
  if command -v dpkg >/dev/null 2>&1 && dpkg -S "$BIN_PATH" >/dev/null 2>&1; then
    PKG_MANAGED=true
    PKG_TYPE="dpkg"
    PKG_NAME=$(dpkg -S "$BIN_PATH" 2>/dev/null | cut -d: -f1 | head -n 1)
  elif command -v rpm >/dev/null 2>&1 && rpm -qf "$BIN_PATH" >/dev/null 2>&1; then
    PKG_MANAGED=true
    PKG_TYPE="rpm"
    PKG_NAME=$(rpm -qf "$BIN_PATH" 2>/dev/null | head -n 1)
  elif command -v apk >/dev/null 2>&1 && apk info -W "$BIN_PATH" >/dev/null 2>&1; then
    PKG_MANAGED=true
    PKG_TYPE="apk"
    PKG_NAME=$(apk info -W "$BIN_PATH" 2>/dev/null | awk '{print $NF}' | head -n 1)
    PKG_NAME="${PKG_NAME%%-[0-9]*}"
  fi

  if [ "$PKG_MANAGED" = true ] && [ -n "$PKG_NAME" ]; then
    log "检测到通过包管理器安装（$PKG_NAME），使用包管理器升级。"
    if [ "$DRY_RUN" = "1" ]; then
      if [ "$PKG_TYPE" = "dpkg" ] && command -v apt-get >/dev/null 2>&1; then
        log "[dry-run] 将执行：apt-get update && apt-get install --only-upgrade -y $PKG_NAME，然后重启服务（隧道会中断几秒）。"
      elif [ "$PKG_TYPE" = "rpm" ] && command -v dnf >/dev/null 2>&1; then
        log "[dry-run] 将执行：dnf upgrade -y $PKG_NAME，然后重启服务（隧道会中断几秒）。"
      elif [ "$PKG_TYPE" = "rpm" ] && command -v yum >/dev/null 2>&1; then
        log "[dry-run] 将执行：yum update -y $PKG_NAME，然后重启服务（隧道会中断几秒）。"
      elif [ "$PKG_TYPE" = "apk" ]; then
        log "[dry-run] 将执行：apk update && apk upgrade $PKG_NAME，然后重启服务（隧道会中断几秒）。"
      fi
      log "[dry-run] 演练结束，未做任何改动。"
      exit 0
    fi
    if [ "$PKG_TYPE" = "dpkg" ] && command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install --only-upgrade -y "$PKG_NAME"
    elif [ "$PKG_TYPE" = "rpm" ] && command -v dnf >/dev/null 2>&1; then
      dnf upgrade -y "$PKG_NAME"
    elif [ "$PKG_TYPE" = "rpm" ] && command -v yum >/dev/null 2>&1; then
      yum update -y "$PKG_NAME"
    elif [ "$PKG_TYPE" = "apk" ]; then
      apk update -q
      apk upgrade "$PKG_NAME"
    else
      log "找不到匹配的包管理器命令，停止。"
      exit 1
    fi
    NEW_VER=$("$BIN_PATH" --version 2>/dev/null | awk '{print $3}' || true)
    if [ "$SKIP_VERSION_CHECK" = "0" ] && [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" = "$NEW_VER" ]; then
      log "已是最新版本（$CURRENT_VER），无需重启。"
      exit 0
    fi
    log "包管理器升级完成，重启服务（隧道会中断几秒）..."
    svc_start
    sleep 3
    if svc_is_active; then
      log "=========================================="
      log "包管理器升级完成：${CURRENT_VER:-未知} -> ${NEW_VER:-未知}"
      log "=========================================="
      exit 0
    else
      log "服务重启后未处于活动状态，升级失败。升级前版本：${CURRENT_VER:-未知}。"
      log "可尝试降级回旧版，或检查服务日志。"
      exit 1
    fi
  fi

  # ---- 分支 D：纯二进制安装 ----
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64)   BIN_ARCH="amd64" ;;
    aarch64|arm64)  BIN_ARCH="arm64" ;;
    armv7l|armv6l)  BIN_ARCH="arm" ;;
    i386|i686)      BIN_ARCH="386" ;;
    *) log "不支持的系统架构：$ARCH"; exit 1 ;;
  esac

  TMP_BIN="/tmp/cloudflared-new-$$"
  ASSET="cloudflared-linux-${BIN_ARCH}"
  DIGEST=""
  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/${ASSET}"

  if API_JSON=$(curl -fsSL --retry 3 --connect-timeout 15 -H 'Accept: application/vnd.github+json' https://api.github.com/repos/cloudflare/cloudflared/releases/latest 2>/dev/null); then
    PARSED_ASSET=$(parse_github_release_asset "$API_JSON" "$ASSET" || true)
    API_DIGEST="${PARSED_ASSET%%$'\t'*}"
    API_URL="${PARSED_ASSET#*$'\t'}"
    if [[ "$API_DIGEST" =~ ^sha256:[a-fA-F0-9]{64}$ ]] && [[ "$API_URL" == https://github.com/cloudflare/cloudflared/releases/download/* ]]; then
      DIGEST="$API_DIGEST"
      URL="$API_URL"
      log "已获取官方 digest：$DIGEST"
    else
      warn "未能从 GitHub API 解析到有效 digest，将降级为版本检查。"
    fi
  else
    warn "GitHub API 请求失败（可能限流或网络受限），尝试直接下载并做版本检查。"
  fi

  DOWNLOAD_URLS=("$URL")
  if [ -n "$GH_MIRROR" ]; then
    DOWNLOAD_URLS+=("${GH_MIRROR%/}/$URL")
  fi

  DOWNLOAD_OK=false
  for dl_url in "${DOWNLOAD_URLS[@]}"; do
    log "尝试下载：$dl_url"
    rm -f "$TMP_BIN"
    if curl -fsSL --retry 2 --connect-timeout 15 -o "$TMP_BIN" "$dl_url" && [ -s "$TMP_BIN" ]; then
      if [ -n "$DIGEST" ]; then
        ACTUAL="sha256:$(sha256sum "$TMP_BIN" | awk '{print $1}')"
        if [ "$ACTUAL" = "$DIGEST" ]; then
          log "digest 校验通过（$dl_url）。"
          DOWNLOAD_OK=true
          break
        else
          log "来源 $dl_url 的 digest 不符（实际 $ACTUAL），尝试下一个源。"
          continue
        fi
      else
        DOWNLOAD_OK=true
        break
      fi
    else
      log "来源 $dl_url 下载失败，尝试下一个源。"
    fi
  done
  if [ "$DOWNLOAD_OK" != "true" ]; then
    log "所有下载源均失败或校验不通过，已终止操作。"
    exit 1
  fi
  chmod 755 "$TMP_BIN"

  NEW_VER=$("$TMP_BIN" --version 2>/dev/null | awk '{print $3}' || true)
  if [ -z "$NEW_VER" ]; then
    log "下载的二进制无法执行（版本读取失败），已终止操作。"
    exit 1
  fi
  log "最新官方版本：$NEW_VER"
  if [ "$SKIP_VERSION_CHECK" = "0" ] && [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" = "$NEW_VER" ]; then
    log "已是最新版本，无需替换。"
    exit 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    if { [ -n "$SERVICE_FILE" ] || [ "$USE_SYSTEMD" = true ] || [ -n "$OPENRC_SERVICE" ]; } && [ -n "$TUNNEL_ARGS" ]; then
      log "[dry-run] 将执行：用新二进制启动临时进程验证注册，然后原子替换 $BIN_PATH 并重启服务（旧二进制备份到 ${BIN_PATH}.bak-<时间戳>，保留最近 ${KEEP_BACKUPS} 份）。"
    elif [ -n "$OPENRC_SERVICE" ]; then
      log "[dry-run] 将执行：plain restart 原子替换 $BIN_PATH 并重启 OpenRC 服务（隧道会中断几秒；旧二进制备份到 ${BIN_PATH}.bak-<时间戳>）。"
    else
      log "[dry-run] 将执行：原子替换 $BIN_PATH 为新二进制（无服务文件，不重启任何服务）。"
    fi
    log "[dry-run] 演练结束，未做任何改动。"
    exit 0
  fi

  if [ -n "$SERVICE_FILE" ] || [ "$USE_SYSTEMD" = true ] || [ -n "$OPENRC_SERVICE" ]; then
    if [ -z "$TUNNEL_ARGS" ]; then
      if [ -n "$OPENRC_SERVICE" ] && [ -z "$SERVICE_FILE" ]; then
        log "OpenRC init 脚本未解析到启动参数，改用 plain restart（隧道会中断几秒）。"
        BACKUP_PATH="${BIN_PATH}.bak-$(date +%Y%m%d%H%M%S)"
        cp -a "$BIN_PATH" "$BACKUP_PATH"
        prune_old_backups "$BIN_PATH"
        svc_stop
        atomic_replace_bin "$TMP_BIN" "$BIN_PATH"
        TMP_BIN=""
        svc_start
        sleep 3
        if svc_is_active; then
          log "=========================================="
          log "OpenRC plain restart 升级完成：${CURRENT_VER:-未知} -> $NEW_VER（中断几秒）"
          log "旧二进制备份：$BACKUP_PATH"
          log "=========================================="
          exit 0
        else
          log "OpenRC 服务启动失败，正在回滚旧二进制..."
          atomic_replace_bin "$BACKUP_PATH" "$BIN_PATH" keep
          svc_start
          sleep 3
          if svc_is_active; then
            log "已回滚到旧版本（${CURRENT_VER:-未知}），服务恢复。"
          else
            log "回滚后服务仍未活动，请手动检查。旧二进制备份：$BACKUP_PATH"
          fi
          exit 1
        fi
      else
        log "无法从服务文件解析启动参数，停止（避免裸 tunnel 启动失败）。"
        exit 1
      fi
    fi

    PARSED_TUNNEL_ARGS=()
    if ! parse_cmd_args "$TUNNEL_ARGS" PARSED_TUNNEL_ARGS || [ "${#PARSED_TUNNEL_ARGS[@]}" -eq 0 ]; then
      log "启动参数语法无法安全解析，停止。"
      exit 1
    fi

    load_systemd_env "$UNIT_TEXT"
    RUN_USER=$(printf '%s\n' "$UNIT_TEXT" | grep -E '^User=' | head -n 1 | cut -d'=' -f2- | tr -d ' ' || true)
    if [ -z "$RUN_USER" ] && [ -n "${OPENRC_USER:-}" ]; then
      RUN_USER="$OPENRC_USER"
    fi
    WORK_DIR=$(printf '%s\n' "$UNIT_TEXT" | grep -E '^WorkingDirectory=' | head -n 1 | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' || true)

    TMP_LOG="/tmp/cloudflared-tmp-$$.log"
    log "启动临时过渡进程建立边缘连接..."
    start_temp_process "$TMP_BIN" "$RUN_USER" "$WORK_DIR" "$TMP_LOG" "${PARSED_TUNNEL_ARGS[@]}"
    TEMP_PID=$!

    if ! wait_for_registration "$TMP_LOG" 30 "$TEMP_PID"; then
      log "临时进程 30 秒内未注册隧道连接，保留旧服务，停止。"
      kill -15 "$TEMP_PID" 2>/dev/null || true
      TEMP_PID=""
      cat "$TMP_LOG" 2>/dev/null | tail -20 || true
      exit 1
    fi

    log "临时进程已注册隧道，原子替换二进制并重启正式服务..."
    BACKUP_PATH="${BIN_PATH}.bak-$(date +%Y%m%d%H%M%S)"
    cp -a "$BIN_PATH" "$BACKUP_PATH"
    prune_old_backups "$BIN_PATH"
    svc_stop
    atomic_replace_bin "$TMP_BIN" "$BIN_PATH"
    TMP_BIN=""
    svc_start
    sleep 3
    if svc_is_active; then
      kill -15 "$TEMP_PID" 2>/dev/null || true
      TEMP_PID=""
      log "=========================================="
      log "原生二进制平滑升级完成：${CURRENT_VER:-未知} -> $NEW_VER（零中断）"
      log "旧二进制备份：$BACKUP_PATH"
      log "=========================================="
      exit 0
    else
      log "正式服务启动失败，正在回滚旧二进制..."
      atomic_replace_bin "$BACKUP_PATH" "$BIN_PATH" keep
      svc_start
      sleep 3
      if svc_is_active; then
        log "已回滚到旧版本（${CURRENT_VER:-未知}），服务恢复。"
      else
        log "回滚后服务仍未活动，请手动检查。旧二进制备份：$BACKUP_PATH"
      fi
      kill -15 "$TEMP_PID" 2>/dev/null || true
      TEMP_PID=""
      exit 1
    fi
  else
    BACKUP_PATH="${BIN_PATH}.bak-$(date +%Y%m%d%H%M%S)"
    cp -a "$BIN_PATH" "$BACKUP_PATH"
    prune_old_backups "$BIN_PATH"
    atomic_replace_bin "$TMP_BIN" "$BIN_PATH"
    TMP_BIN=""
    log "未找到服务文件，仅更新了二进制文件（$BIN_PATH），未重启任何服务。"
    log "旧二进制备份：$BACKUP_PATH"
    log "=========================================="
    log "二进制升级完成：${CURRENT_VER:-未知} -> $NEW_VER"
    log "=========================================="
    exit 0
  fi
fi

# ============================================================
# 未检测到 cloudflared
# ============================================================
if [ "$MODE" = "docker" ]; then
  log "未检测到运行中的 cloudflared Docker 容器。"
elif [ "$MODE" = "systemd" ]; then
  log "未检测到 cloudflared 系统服务或二进制文件。"
else
  log "未检测到运行中的 cloudflared 容器、系统服务或二进制文件。"
fi
exit 1