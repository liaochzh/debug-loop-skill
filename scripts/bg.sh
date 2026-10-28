#!/bin/bash
# bg.sh — 长任务后台执行包装器（通用，适用于任意 debug-loop 脚本）
#
# 为什么需要它：
#   shell 工具默认前台超时 120s，而 flutter build（Android 常 >120s / iOS 常 >300s）
#   与 Maestro 冷启动（60~180s）会超过该上限被强杀。用本包装器「启动即返回」，
#   再轮询状态，即可彻底绕开前台超时限制，且不会因被杀而丢失已落盘输出。
#
# 用法:
#   bg.sh start <脚本相对路径> [脚本参数...]   # 启动，立即返回 job_id（<1s）
#   bg.sh status <job_id>                      # 查询：RUNNING / DONE / FAILED / LOST
#   bg.sh logs <job_id> [-n 行数]              # 拉取输出（默认 50 行）
#   bg.sh wait <job_id> [--timeout 秒]         # 短轮询（默认 100s；返回 10=还在跑，再调一次）
#   bg.sh list                                 # 列出最近 job
#
# 示例:
#   bg.sh start android/build.sh --debug
#   bg.sh wait <job_id> --timeout 100     # 短轮询；返回 10 = 还在跑，再调一次
#   bg.sh status <job_id>
#
# 退出码契约: 0=成功 / 1=任务失败 / 2=用法错误(参数非法·job 不存在) / 3=被强杀(LOST) / 10=仍在执行
# 约定: 从项目根执行（需 .debug.env；缺省时仅用默认 LOG_DIR）；job 元数据写入 build/debug/jobs/
set -euo pipefail

PROJ_ROOT="$PWD"
# 与各平台 _common.sh 保持一致：安全解析 .debug.env（**不 source** —— 那等于执行项目内文本）
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_SELF_DIR/_env.sh" ]; then
  # shellcheck source=/dev/null
  source "$_SELF_DIR/_env.sh"
  if [ -f ".debug.env" ]; then
    parse_debug_env ".debug.env" || exit 1
    validate_debug_env
    export_debug_env        # 保持原 `set -a` 效果：子进程继承这些变量
  fi
elif [ -f ".debug.env" ]; then
  # 解析器缺失 ⇒ 无法安全加载 .debug.env ⇒ 失败关闭（绝不退回 source）
  echo "❌ 缺少 scripts/_env.sh（.debug.env 安全解析器）—— 无法安全加载 .debug.env" >&2
  exit 1
fi
LOG_DIR="${LOG_DIR:-build/debug}"
JOB_DIR="$LOG_DIR/jobs"

# 打印头部注释作为帮助文本。按内容边界（首个非注释行）截取，
# 不依赖行号，避免头部增删注释后泄漏代码行（如 set -euo pipefail）。
usage() {
  awk 'NR<3 {next} /^[^#[:space:]]/ {exit} {sub(/^# ?/, ""); print}' "$0"
}

# 数值参数守卫：非纯数字直接退出 2，避免 sleep/[ 报错后被 set -e 误判为任务失败
require_uint() {
  case "$2" in
    ''|*[!0-9]*) echo "❌ $1 需为非负整数（收到: ${2}）" >&2; exit 2 ;;
  esac
}

# 正整数守卫：用于 --interval，0 会使 waited 恒不增长导致死循环
require_positive() {
  require_uint "$1" "$2"
  [ "$2" -ge 1 ] || { echo "❌ $1 需 ≥ 1（收到: ${2}）" >&2; exit 2; }
}

job_files() {
  JOB_ID="$1"
  case "$JOB_ID" in
    */*|*.*|"") echo "❌ 非法 job_id: ${JOB_ID}" >&2; exit 2 ;;
  esac
  J_LOG="$JOB_DIR/$JOB_ID.log"
  J_PID="$JOB_DIR/$JOB_ID.pid"
  J_EXIT="$JOB_DIR/$JOB_ID.exit"
  J_RUN="$JOB_DIR/$JOB_ID.run.sh"
  J_CMD="$JOB_DIR/$JOB_ID.cmd"
}

# 仅查询类子命令用：确保 job 确实存在
require_job() {
  job_files "$1"
  [ -f "$J_LOG" ] || { echo "❌ job 不存在: ${JOB_ID}（见 bg.sh list）" >&2; exit 2; }
}

pid_alive() {
  [ -f "$1" ] || return 1
  local p
  p=$(head -1 "$1" 2>/dev/null)
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null || return 1
  # PID 可能已被系统回收并分配给无关进程：校验命令行确为本 runner
  local run="${1%.pid}.run.sh"
  if [ -f "$run" ]; then
    ps -p "$p" -o args= 2>/dev/null | grep -qF "$run" || return 1
  fi
  return 0
}

# 读取 job 退出码（文件不存在或为空时输出空串）
# 参数：.exit 文件路径（与 pid_alive 风格一致，不做路径拼接）
read_exit_code() {
  [ -f "$1" ] || { echo ""; return 0; }
  head -1 "$1" 2>/dev/null | tr -d '[:space:]' || echo ""
}

job_state() {
  local id="$1"
  if [ -f "$JOB_DIR/$id.exit" ]; then
    [ "$(read_exit_code "$JOB_DIR/$id.exit")" = "0" ] && echo "DONE" || echo "FAILED"
  elif pid_alive "$JOB_DIR/$id.pid"; then
    echo "RUNNING"
  else
    echo "LOST"
  fi
}

# 解析待包装脚本的绝对路径：失败时向 stderr 报错并 exit 2
# 注意：本函数若在 $() 子 shell 中调用，exit 不会传播给调用方，
#      故 cmd_start 必须对其返回值做非空断言。
resolve_script() {
  local target="$1"
  local script_dir abs_script="" cand
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  case "$target" in
    /*) abs_script="$target" ;;
    *)
      for cand in "$script_dir/$target" "$script_dir/scripts/$target" "$PROJ_ROOT/$target"; do
        if [ -f "$cand" ]; then abs_script="$cand"; break; fi
      done
      ;;
  esac
  if [ -z "$abs_script" ] || [ ! -f "$abs_script" ]; then
    echo "❌ 找不到脚本: $target" >&2
    echo "   可包装示例: android/build.sh / ios/build.sh / maestro/tap.sh / macos/smart_tap.sh" >&2
    return 2
  fi
  echo "$abs_script"
}

# 生成 job_id、runner 脚本与命令摘要；job_id 由 stdout 返回
# 副作用：调用 job_files 设置全局 J_* 变量
write_runner() {
  local abs_script="$1"; shift
  local job_id a
  # job_id 加随机后缀，避免同秒 + PID 复用时二次 start 覆盖同名 job
  job_id="$(date +%Y%m%d-%H%M%S)-$$-$(printf '%04x' $((RANDOM % 65536)))"
  job_files "$job_id"

  {
    echo '#!/bin/bash'
    printf 'cd %q || exit 91\n' "$PROJ_ROOT"
    # runner 自报 PID：setsid/python3 分叉路径下 $! 是中间进程，不可作为存活判据
    printf 'echo $$ > %q\n' "$J_PID"
    printf 'bash %q' "$abs_script"
    for a in "$@"; do printf ' %q' "$a"; done
    echo
    echo 'ec=$?'
    printf 'echo "$ec" > %q\n' "$J_EXIT"
    echo 'exit "$ec"'
  } > "$J_RUN"
  chmod +x "$J_RUN"

  printf '%s' "$(basename "$abs_script")" > "$J_CMD"
  for a in "$@"; do printf ' %s' "$a" >> "$J_CMD"; done
  echo >> "$J_CMD"

  echo "$job_id"
}

cmd_start() {
  [ $# -ge 1 ] || { echo "❌ 用法: bg.sh start <脚本路径> [参数...]"; exit 2; }
  local target="$1"; shift

  # F2：子 shell 中 resolve_script 的 exit 2 不会传播，必须显式断言空值
  local abs_script
  abs_script=$(resolve_script "$target") || exit 2
  [ -n "$abs_script" ] || exit 2

  mkdir -p "$JOB_DIR"
  local job_id
  job_id=$(write_runner "$abs_script" "$@") || exit 2
  [ -n "$job_id" ] || exit 2
  # 必需：write_runner 在 $() 子 shell 内调用，其 job_files 赋值不会回传父 shell，
# 父侧的 J_RUN/J_LOG/J_PID/J_EXIT/J_CMD 全靠这一行，删掉会导致 set -u 未定义变量崩溃。
  job_files "$job_id"

  launch_detached || { echo "❌ job 未启动：$job_id" >&2; exit 1; }
  echo "🚀 已后台启动: job_id=$job_id"
  echo "   命令: $(cat "$J_CMD")"
  echo "   日志: $J_LOG"
  echo "   下一步: bg.sh wait ${job_id} --timeout 100   （返回 10 =还在跑，短轮询直到拿到 0/1/3）"
}

# 脱离会话启动 runner 并等待其写入真实 PID
# 真正脱离会话：父进程（含 opencode 超时清理）被杀时 runner 仍存活。
# macOS 不带 setsid，退化为 python3 的 os.setsid(); 再退化为 nohup（仅挡 SIGHUP）。
# 注意：不可依赖 $!（分叉路径下它是立即退出的中间进程），存活判据由 runner 自报的 $$ 提供。
launch_detached() {
  rm -f "$J_EXIT" "$J_PID"
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$J_RUN" > "$J_LOG" 2>&1 &
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys
os.setsid()
pid=os.fork()
if pid>0: os._exit(0)
fd=os.open(sys.argv[2], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o644)
os.dup2(fd,1); os.dup2(fd,2)
os.execvp("bash",["bash",sys.argv[1]])' "$J_RUN" "$J_LOG" 2>>"$J_LOG" &
  else
    nohup bash "$J_RUN" > "$J_LOG" 2>&1 &
  fi
  # 等 runner 写入真实 PID（最多 ~2s），避免轮询时读到空 .pid 误判 LOST
  local waited_pid=0
  while [ ! -s "$J_PID" ] && [ "$waited_pid" -lt 20 ]; do
    sleep 0.1
    waited_pid=$((waited_pid + 1))
  done
  # 启动失败（如 os.setsid 抛错）时不得谎报成功：runner 未起则无 PID 可写
  [ -s "$J_PID" ] || { echo "❌ 后台启动失败（未取到 PID），详见 $J_LOG" >&2; return 1; }
  return 0
}

cmd_status() {
  [ $# -ge 1 ] || { echo "❌ 用法: bg.sh status <job_id>"; exit 2; }
  require_job "$1"
  local st ec
  st=$(job_state "$JOB_ID")
  echo "$st"
  case "$st" in
    RUNNING) echo "⏳ 仍在执行；可 bg.sh logs $1 -n 50 观察进度" >&2 ;;
    DONE)    echo "✅ 执行成功（exit 0）" >&2 ;;
    FAILED)  ec=$(read_exit_code "$J_EXIT")
             echo "❌ 执行失败（exit ${ec:-?}）；bg.sh logs ${1} 查看原因" >&2 ;;
    LOST)    echo "⚠️  进程消失且无退出码，多是被外部强杀；看 bg.sh logs $1 末尾判断停在哪一步" >&2 ;;
  esac
  # 退出码契约：DONE=0 / FAILED=1 / LOST=3 / RUNNING=10（调用方可直接判成败）
  case "$st" in
    RUNNING) exit 10 ;;
    DONE)    exit 0 ;;
    FAILED)  exit 1 ;;
    *)       exit 3 ;;
  esac
}

cmd_logs() {
  local job_id="" n=50
  while [ $# -gt 0 ]; do
    case "$1" in
      -n) [ $# -ge 2 ] || { echo "❌ -n 缺参数值"; exit 2; }; require_uint "-n" "$2"; n="$2"; shift 2 ;;
      *) job_id="$1"; shift ;;
    esac
  done
  [ -n "$job_id" ] || { echo "❌ 用法: bg.sh logs <job_id> [-n 行数]"; exit 2; }
  require_job "$job_id"
  echo "=== job $job_id | 状态: $(job_state "$job_id") | 命令: $(cat "$J_CMD" 2>/dev/null) ==="
  tail -n "$n" "$J_LOG" 2>/dev/null || echo "(暂无输出)"
  echo ""
  echo "📁 完整日志: $J_LOG"
}

cmd_wait() {
  # 默认 100 而非 600：单次 wait 超过 120s 会被外层前台超时强杀，默认即应安全
  local job_id="" timeout=100 interval=5
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout)  [ $# -ge 2 ] || { echo "❌ --timeout 缺参数值"; exit 2; }; require_uint "--timeout" "$2"; timeout="$2"; shift 2 ;;
      --interval) [ $# -ge 2 ] || { echo "❌ --interval 缺参数值"; exit 2; }; require_positive "--interval" "$2"; interval="$2"; shift 2 ;;
      *) job_id="$1"; shift ;;
    esac
  done
  [ -n "$job_id" ] || { echo "❌ 用法: bg.sh wait <job_id> [--timeout 秒]"; exit 2; }
  require_job "$job_id"

  # 单次 wait 安全上限。外层 shell 前台超时为 120s，留约 10s 余量给收尾输出。
  # 可用 BG_MAX_WAIT 覆盖（供回归测试快速验证截断逻辑；生产勿改）。
  local max_wait="${BG_MAX_WAIT:-110}"
  if [ "$timeout" -gt "$max_wait" ]; then
    echo "⚠️  --timeout ${timeout} 超过单次 wait 安全上限（${max_wait}s），已截为 ${max_wait}；请短轮询累积等待。" >&2
    timeout="$max_wait"
  fi
  
  # 用墙钟而非累加 sleep 计算耗时：每轮 job_state 有 head/ps/grep 开销，累加会低估真实耗时
  local start_ts end_ts waited st ec
  start_ts=$(date +%s)
  end_ts=$(( start_ts + timeout ))
  waited=0
  while :; do
    st=$(job_state "$JOB_ID")
    if [ "$st" = "DONE" ] || [ "$st" = "FAILED" ]; then
      ec=$(read_exit_code "$J_EXIT")
      waited=$(( $(date +%s) - start_ts ))
      echo "=== job $job_id 结束（exit ${ec:-?}，耗时约 ${waited}s）==="
      tail -n 60 "$J_LOG" 2>/dev/null || true
      echo ""
      if [ "$st" = "DONE" ]; then echo "✅ 成功"; exit 0; else echo "❌ 失败（exit ${ec:-?}）"; exit 1; fi
    fi
    if [ "$st" = "LOST" ]; then
      waited=$(( $(date +%s) - start_ts ))
      echo "=== job $job_id 进程消失且无退出码（约 ${waited}s）==="
      tail -n 60 "$J_LOG" 2>/dev/null || true
      echo ""
      echo "⚠️  LOST：多是被外部强杀。看上方日志末尾判断停在哪一步后决定重试。"
      exit 3
    fi
    # 睡到剩余时间用完为止，但不超过单个 interval
    local now remaining nap
    now=$(date +%s)
    remaining=$(( end_ts - now ))
    [ "$remaining" -le 0 ] && break
    nap=$interval
    [ "$nap" -gt "$remaining" ] && nap=$remaining
    sleep "$nap"
  done

  waited=$(( $(date +%s) - start_ts ))
  echo "=== job $job_id 仍在执行（已等 ${waited}s）==="
  tail -n 30 "$J_LOG" 2>/dev/null || true
  echo ""
  echo "⏳ 未结束（已等 ${waited}s）。这不是失败——继续 bg.sh wait ${job_id} 短轮询直到拿到 0/1/3。"
  echo "   注意：单次 wait 受外层 120s 前台超时限制，故本命令已截到 ≤110s，请重复调用累积等待；"
  echo "   日志长时间无新增属正常（Gradle 构建可能 8 分钟只有一行输出），仅 status 返回 LOST 才算卡死。"
  exit 10
}

cmd_list() {
  if [ ! -d "$JOB_DIR" ]; then echo "(暂无 job)"; exit 0; fi
  local found=0 j id st
  echo "=== 最近 job（${JOB_DIR}）==="
  for j in $(ls -1t "$JOB_DIR"/*.log 2>/dev/null | head -10); do
    found=1
    id=$(basename "$j" .log)
    st=$(job_state "$id")
    printf '%-24s %-8s %s\n' "$id" "$st" "$(tr '\n' ' ' < "$JOB_DIR/$id.cmd" 2>/dev/null)"
  done
  [ "$found" -eq 1 ] || echo "(暂无 job)"
}

case "${1:-}" in
  start)  shift; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  logs)   shift; cmd_logs "$@" ;;
  wait)   shift; cmd_wait "$@" ;;
  list)   shift; cmd_list ;;
  ""|-h|--help|help) usage ;;
  *) echo "❌ 未知子命令: $1"; usage; exit 2 ;;
esac