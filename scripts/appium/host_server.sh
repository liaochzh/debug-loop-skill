#!/bin/bash
# host_server.sh — 宿主侧 Appium 服务一键管理（ensure / status / stop）
#
# ⚠️ **必须在宿主执行，不得经 safe_run.sh 沙箱入口。**
#   Seatbelt profile 由子进程**继承且终身不可脱** ⇒ 沙箱内 nohup 起的 appium 即使 /status 报 ready，
#   后续 spawn xcodebuild / devicectl / 访问 mach services 做 WDA 时全被拒 ⇒ 得到**残废服务**，
#   比直接失败更坏（调用方会以为就绪，然后在创建会话处空等/误判）。
#   沙箱只放行「连」localhost:4723（safe_run.sh 的 network-outbound），不放行起服务所需能力。
#   故 iOS 真机 / macOS mac2 每轮验证前，由**主 agent 在宿主**跑本脚本；子代理只复用，不启动。
#
# 用法: bash host_server.sh [ensure|status|stop] [--project-root <dir>] [--port N] [--timeout S]
#   ensure（默认）幂等：已就绪直接复用（不重复起）；未就绪则后台启动并轮询 /status 至 ready
#   status        只报告不启动（0=在线 / 1=未在线）
#   stop          **只杀本脚本自己起的 pid**（读 pid 文件 + 校验命令行含 appium），
#                 不误杀手工起的服务；无 pid 文件时什么都不做
# 退出码: 0=就绪/成功  1=启动失败或超时（status 未在线亦为 1）  2=用法错（含沙箱内调用）  3=未安装 appium CLI
# 产物: <项目根>/build/debug/appium-host.log 与 appium-host.pid
#   （**刻意与沙箱内 _common.sh 的 appium.log 分开**：一眼看出服务是谁起的）
# 依赖: appium 3.x CLI（仅 ensure 需要）、curl
set -uo pipefail

CMD="ensure"
ROOT="$PWD"
PORT="${APPIUM_PORT:-4723}"
TIMEOUT=60

while [ $# -gt 0 ]; do
  case "$1" in
    ensure|status|stop) CMD="$1"; shift ;;
    --project-root) [ $# -ge 2 ] || { echo "❌ --project-root 缺参数值" >&2; exit 2; }; ROOT="$2"; shift 2 ;;
    --port)         [ $# -ge 2 ] || { echo "❌ --port 缺参数值" >&2; exit 2; }; PORT="$2"; shift 2 ;;
    --timeout)      [ $# -ge 2 ] || { echo "❌ --timeout 缺参数值" >&2; exit 2; }; TIMEOUT="$2"; shift 2 ;;
    -h|--help)      awk 'NR<3 {next} /^[^#[:space:]]/ {exit} {sub(/^# ?/, ""); print}' "$0"; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done

# ⚠️ 沙箱自检（**防线不能只靠纪律**）：子代理可以跑 `safe_run.sh -- bash …/host_server.sh ensure`，
#   safe_run 会放行执行（脚本可读、写 build/ 在白名单内）⇒ 在沙箱内起出**残废服务**且 /status 报 ready，
#   正是本方案要杜绝的事。故入口脚本自己必须拒绝在沙箱内运行（2026-11-16 review 问题 1）。
if [ -n "${SAFE_RUN_PROFILE:-}" ]; then
  echo "❌ host_server.sh 必须在**宿主**执行，不得经 safe_run 沙箱入口。" >&2
  echo "   沙箱内起的 Appium 会继承 Seatbelt profile 且终身不可脱 ⇒ 残废服务（/status 假就绪）。" >&2
  echo "   请由主 agent 在宿主直接跑：bash $0 ${CMD} --project-root ${ROOT} --port ${PORT}" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_ready.sh"

case "$PORT" in ''|*[!0-9]*) echo "❌ --port 必须是数字: $PORT" >&2; exit 2 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) echo "❌ --timeout 必须是数字（秒）: $TIMEOUT" >&2; exit 2 ;; esac
if [ "$TIMEOUT" -lt 1 ]; then
  echo "❌ --timeout 至少 1 秒（0 会让轮询体不执行、刚启动就误报超时）: $TIMEOUT" >&2; exit 2
fi
if [ ! -d "$ROOT" ]; then
  echo "❌ 项目根不存在或不是目录: $ROOT" >&2; exit 2
fi
ROOT="$(cd "$ROOT" && pwd -P)"

LOG_DIR="$ROOT/build/debug"
mkdir -p "$LOG_DIR" 2>/dev/null || { echo "❌ 无法创建日志目录: $LOG_DIR" >&2; exit 1; }
LOG="$LOG_DIR/appium-host.log"
PIDFILE="$LOG_DIR/appium-host.pid"
SERVER="http://127.0.0.1:$PORT"

# 就绪判据复用 _ready.sh（必须 `"ready": true`；只匹配 `"ready"` 子串会把 ready:false 判成就绪）
online() { appium_status_ready "$SERVER"; }

# pid 文件里的进程是否**确实是我们起的 appium**（防 pid 复用后误杀无关进程）
#   · `-ww` 防 macOS ps 截断长命令行（深 nvm/brew 路径下 appium 可能落在截断外 ⇒ 自己的服务被误判成他人的）
#   · 匹配收紧到「路径组件或独立词 appium」：`tail appium-host.log` 这类**不含**独立 appium 词，不会被误杀
our_pid_alive() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -ww -p "$pid" -o command= 2>/dev/null \
    | grep -qE '(^|[[:space:]/])appium([[:space:]]|$|/)' || return 1
  return 0
}

case "$CMD" in
  status)
    if online; then
      echo "✅ Appium 在线: $SERVER"
      if [ -f "$PIDFILE" ] && our_pid_alive "$(cat "$PIDFILE" 2>/dev/null)"; then
        echo "   由本脚本启动（pid $(cat "$PIDFILE")，日志 ${LOG}）"
      else
        echo "   非本脚本启动（无 pid 文件）⇒ stop 不会动它"
      fi
      exit 0
    fi
    echo "ℹ️  Appium 未在线: $SERVER"
    echo "   起服务（宿主执行）: bash $0 ensure --project-root $ROOT --port $PORT"
    exit 1
    ;;

  stop)
    if [ ! -f "$PIDFILE" ]; then
      echo "ℹ️  无 pid 文件 ⇒ 没有本脚本起的服务，不做任何事（不误杀手工起的服务）"
      if online; then
        echo "   ⚠️ 但端口 ${PORT} 有服务在线：可能是 build/ 被 clean 清掉了 pid 记录，或非本脚本启动。"
        echo "      本脚本不会动它；如需停止请人工确认：lsof -i :${PORT}"
      fi
      exit 0
    fi
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    if ! our_pid_alive "$pid"; then
      echo "ℹ️  pid ${pid:-<空>} 已不是本脚本起的 appium（已退出或 pid 复用）⇒ 只清 pid 文件"
      rm -f "$PIDFILE"
      exit 0
    fi
    kill "$pid" 2>/dev/null
    for _ in $(seq 1 10); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "❌ pid $pid 未在 10s 内退出（未强杀，请人工确认）" >&2
      exit 1
    fi
    rm -f "$PIDFILE"
    echo "✅ 已停止本脚本起的 Appium（pid ${pid}）"
    exit 0
    ;;

  ensure)
    if online; then
      echo "✅ Appium 已就绪，复用: ${SERVER}（不重复启动）"
      exit 0
    fi
    # 收养「本脚本上次启动、仍在启动中」的服务：否则本次会起第二个进程撞 EADDRINUSE 而死，
    #   随后的 rm pid 文件还会把旧服务的记录删掉 ⇒ 旧进程成**永久孤儿**、stop 再也找不到它。
    if [ -f "$PIDFILE" ] && our_pid_alive "$(cat "$PIDFILE" 2>/dev/null)"; then
      oldpid="$(cat "$PIDFILE")"
      echo "ℹ️  已有本脚本启动的 Appium（pid ${oldpid}）尚未就绪 ⇒ 等待它就绪，不重复启动"
      for _ in $(seq 1 "$TIMEOUT"); do
        if online; then
          echo "✅ Appium 就绪: ${SERVER}（pid ${oldpid}，日志 ${LOG}）"
          exit 0
        fi
        if ! kill -0 "$oldpid" 2>/dev/null; then
          echo "❌ 既有 Appium 进程已退出（pid ${oldpid}），日志尾部：" >&2
          # 重定向顺序：先 >&2（stdout→原 stderr）再 2>/dev/null；写反会把两流都送进 /dev/null 静默吞日志
          tail -15 "$LOG" >&2 2>/dev/null || true
          rm -f "$PIDFILE"
          exit 1
        fi
        sleep 1
      done
      echo "❌ 既有 Appium（pid ${oldpid}）在 ${TIMEOUT}s 内仍未就绪；进程与 pid 记录保留，请查日志 ${LOG}" >&2
      exit 1
    fi
    if ! command -v appium >/dev/null 2>&1; then
      echo "❌ 未安装 Appium CLI — 请执行: npm install -g appium@3 && appium driver install mac2 && appium driver install xcuitest" >&2
      exit 3
    fi
    echo "🚀 宿主启动 Appium（:${PORT}，日志: ${LOG}）..."
    nohup appium --port "$PORT" > "$LOG" 2>&1 &
    newpid=$!
    disown 2>/dev/null || true
    echo "$newpid" > "$PIDFILE"
    for _ in $(seq 1 "$TIMEOUT"); do
      if online; then
        echo "✅ Appium 就绪: ${SERVER}（pid ${newpid}，日志 ${LOG}）"
        exit 0
      fi
      if ! kill -0 "$newpid" 2>/dev/null; then
        echo "❌ Appium 进程已退出（pid ${newpid}），日志尾部：" >&2
        tail -15 "$LOG" >&2 2>/dev/null || true
        rm -f "$PIDFILE"
        exit 1
      fi
      sleep 1
    done
    echo "❌ Appium 启动超时（${TIMEOUT}s），日志尾部：" >&2
    tail -15 "$LOG" >&2 2>/dev/null || true
    echo "   进程仍在跑（pid ${newpid}）；如确认失败请: bash $0 stop --project-root $ROOT" >&2
    exit 1
    ;;
esac