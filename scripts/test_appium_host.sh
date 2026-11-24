#!/bin/bash
# test_appium_host.sh — appium/host_server.sh 与 _common.sh 沙箱快失败的离线回归
#
# 不需真机、不需真 appium：假 /status HTTP 服务模拟 就绪 / ready:false / 延迟就绪，
# PATH 剥离 appium 模拟「未安装 CLI」，stub appium 模拟 冷启动 / 慢启动 / 启动即崩溃。
# 覆盖：rc 契约、幂等复用、不误杀、沙箱守卫、沙箱内不启动、收养启动中 pid（成功/死亡/超时三态）、
#       pid 产生/消费闭环、ready:false 负控、启动中进程退出分支。
#
# 用法: bash test_appium_host.sh [-v] [-f 关键字]
# 退出码: 0=全部通过 / 1=有用例失败 / 2=用法错
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/appium/host_server.sh"
COMMON="$SCRIPT_DIR/appium/_common.sh"

VERBOSE=0; FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    -v) VERBOSE=1; shift ;;
    -f) [ $# -ge 2 ] || { echo "❌ -f 需带关键字" >&2; exit 2; }; FILTER="$2"; shift 2 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0; FAILED_CASES=()
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbgappium.XXXXXX")"
FAKE_PID=""
cleanup() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  # 兜底：清理失败用例可能遗留的 stub appium（防孤儿；stub 的 TERM trap 会连带杀其 python 子进程）
  pkill -f "$TMPROOT/stub/appium" 2>/dev/null
  rm -rf "$TMPROOT"
}
trap cleanup EXIT INT TERM

ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); printf '  ❌ %s（%s）\n' "$1" "$2"; }
expect_rc() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then ok "$name"; else bad "$name" "rc=${got}，期望 ${want}"; fi
}
expect_contains() {
  if printf '%s' "$2" | grep -q "$3"; then ok "$1"; else bad "$1" "输出未含 '$3'"; fi
}
run_case() { case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac; }

if [ ! -f "$TARGET" ]; then echo "❌ 缺少被测脚本: $TARGET" >&2; exit 2; fi

# 选一个空闲端口（bind 0 让内核分配，随后关闭再交给假服务）
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
ROOT="$TMPROOT/proj"; mkdir -p "$ROOT"

# 假 /status 服务：返回 appium 风格报文。argv[2]=延迟秒数：启动后 DELAY 秒内报 ready:false，之后 ready:true
#   （delay=0 恒 true；delay=3600 在测试窗口内恒 false ⇒ H8 负控）
cat > "$TMPROOT/fake_status.py" <<'PY'
import http.server, json, sys, time
START = time.time()
DELAY = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ready = (time.time() - START) >= DELAY
        body = json.dumps({"value": {"ready": ready, "message": "fake"}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

start_fake() {
  local delay="${1:-0}"
  python3 "$TMPROOT/fake_status.py" "$PORT" "$delay" >/dev/null 2>&1 &
  FAKE_PID=$!
  local i
  for i in $(seq 1 30); do
    # 只探「服务有响应」（出现 ready 字段）。探针非判据：ready:true 与否由被测代码的 _ready.sh 判据判定，勿混淆
    curl -s -m 2 "http://127.0.0.1:$PORT/status" 2>/dev/null | grep -q '"ready"' && return 0
    sleep 0.2
  done
  return 1
}
stop_fake() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; FAKE_PID=""; sleep 0.5; }

# 等端口下线（stop 后允许短暂残留）
wait_offline() {
  local i
  for i in $(seq 1 10); do
    curl -s -m 1 "http://127.0.0.1:$PORT/status" >/dev/null 2>&1 || return 0
    sleep 0.3
  done
  return 1
}

# 沙箱侧 _common.sh 单元验证的最小前置（H6/H8 共用；不依赖用例执行顺序）
SANDBOX_PROJ="$TMPROOT/sbx"; mkdir -p "$SANDBOX_PROJ"
printf 'name: fake\n' > "$SANDBOX_PROJ/pubspec.yaml"
printf 'ANDROID_PACKAGE=com.example.fake\nIOS_BUNDLE_ID=com.example.fake\nAPP_NAME=Fake\n' > "$SANDBOX_PROJ/.debug.env"

# stub appium（H9 冷启动 / H10 收养）：解析 --port，起假 /status 服务并常驻。
#   **不能 exec python**：exec 会替换进程映像，命令行失去 appium 字样 ⇒ our_pid_alive 误判、stop 杀不到。
#   STUB_DELAY 控制启动后多少秒才报 ready:true（之前报 ready:false）。
mkdir -p "$TMPROOT/stub" "$TMPROOT/stub-crash"
cat > "$TMPROOT/stub/appium" <<'STUB'
#!/bin/bash
PORT=4723
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
python3 "__FAKE_PY__" "$PORT" "${STUB_DELAY:-0}" &
CHILD=$!
trap 'kill $CHILD 2>/dev/null; exit 0' TERM INT
# STUB_DIE：存活 N 秒后自行崩溃（H13：收养期间进程死亡）
if [ -n "${STUB_DIE:-}" ]; then
  sleep "$STUB_DIE"
  echo "stub appium: 模拟就绪前崩溃" >&2
  kill $CHILD 2>/dev/null
  exit 1
fi
wait $CHILD
STUB
sed -i '' "s|__FAKE_PY__|$TMPROOT/fake_status.py|" "$TMPROOT/stub/appium"
chmod +x "$TMPROOT/stub/appium"
# 崩溃 stub（H12）：启动即退出，模拟「轮询期间进程退出」
cat > "$TMPROOT/stub-crash/appium" <<'STUB'
#!/bin/bash
echo "stub appium: 模拟启动失败" >&2
sleep 0.3
exit 1
STUB
chmod +x "$TMPROOT/stub-crash/appium"

echo "== appium/host_server.sh 离线回归 =="

# ---------- H1 用法错 ----------
if run_case "H1-用法错"; then
  OUT="$(bash "$TARGET" --bogus 2>&1)"; expect_rc "H1 未知参数 rc=2" 2 "$?"
  OUT="$(bash "$TARGET" --port abc 2>&1)"; expect_rc "H1 --port 非数字 rc=2" 2 "$?"
  OUT="$(bash "$TARGET" --project-root "$TMPROOT/no-such-dir" 2>&1)"; expect_rc "H1 项目根不存在 rc=2" 2 "$?"
  OUT="$(bash "$TARGET" --port 2>&1)"; expect_rc "H1 --port 缺值 rc=2" 2 "$?"
  echo ""
fi

# ---------- H2 未在线 ----------
if run_case "H2-未在线"; then
  stop_fake
  OUT="$(bash "$TARGET" status --project-root "$ROOT" --port "$PORT" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "H2 status 未在线 rc=1" 1 "$RC"
  expect_contains "H2 status 给出宿主启动指引" "$OUT" "host_server.sh ensure"
  echo ""
fi

# ---------- H3 未安装 CLI ----------
if run_case "H3-未装CLI"; then
  stop_fake
  # 用系统目录作 PATH：appium 装在 npm 全局（homebrew/nvm），不在 /usr/bin:/bin
  if PATH="/usr/bin:/bin" command -v appium >/dev/null 2>&1; then
    echo "  ⏭  跳过 H3：/usr/bin:/bin 里竟有 appium，无法模拟未安装"
  else
    OUT="$(PATH="/usr/bin:/bin" bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 3 2>&1)"; RC=$?
    [ "$VERBOSE" = "1" ] && echo "$OUT"
    expect_rc "H3 未装 appium CLI rc=3" 3 "$RC"
    expect_contains "H3 给出安装指引" "$OUT" "npm install -g appium"
    if [ -f "$ROOT/build/debug/appium-host.pid" ]; then
      bad "H3 未装 CLI 不应留 pid 文件" "pid 文件存在"
    else
      ok "H3 未装 CLI 不留 pid 文件"
    fi
  fi
  echo ""
fi

# ---------- H4 已就绪：幂等复用 + 不误杀 ----------
if run_case "H4-幂等与不误杀"; then
  if ! start_fake; then
    bad "H4 假服务起不来" "端口 $PORT"
  else
    OUT="$(bash "$TARGET" status --project-root "$ROOT" --port "$PORT" 2>&1)"; RC=$?
    [ "$VERBOSE" = "1" ] && echo "$OUT"
    expect_rc "H4 status 在线 rc=0" 0 "$RC"
    expect_contains "H4 标明非本脚本启动" "$OUT" "非本脚本启动"

    OUT="$(bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 5 2>&1)"; RC=$?
    [ "$VERBOSE" = "1" ] && echo "$OUT"
    expect_rc "H4 ensure 已就绪时复用 rc=0" 0 "$RC"
    expect_contains "H4 明确复用不重复启动" "$OUT" "复用"
    if [ -f "$ROOT/build/debug/appium-host.pid" ]; then
      bad "H4 复用他人服务不应写 pid 文件" "pid 文件存在"
    else
      ok "H4 复用他人服务不写 pid 文件"
    fi

    OUT="$(bash "$TARGET" stop --project-root "$ROOT" --port "$PORT" 2>&1)"; RC=$?
    [ "$VERBOSE" = "1" ] && echo "$OUT"
    expect_rc "H4 无 pid 文件时 stop rc=0" 0 "$RC"
    expect_contains "H4 stop 失忆且端口在线时给 lsof 提示" "$OUT" "lsof"
    if curl -s -m 2 "http://127.0.0.1:$PORT/status" 2>/dev/null | grep -q '"ready"'; then
      ok "H4 stop 未误杀他人起的服务（假服务仍在线）"
    else
      bad "H4 stop 误杀了他人服务" "假服务已下线"
    fi
  fi
  echo ""
fi

# ---------- H5 stop 的 pid 安全校验 ----------
if run_case "H5-stop安全"; then
  stop_fake
  mkdir -p "$ROOT/build/debug"
  # 伪造 pid 文件指向一个**非 appium** 的存活进程 ⇒ 必须拒杀（防 pid 复用误杀）
  sleep 30 & VICTIM=$!
  echo "$VICTIM" > "$ROOT/build/debug/appium-host.pid"
  OUT="$(bash "$TARGET" stop --project-root "$ROOT" --port "$PORT" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "H5 pid 非 appium 时 stop rc=0（只清文件）" 0 "$RC"
  if kill -0 "$VICTIM" 2>/dev/null; then
    ok "H5 未误杀非 appium 进程（命令行校验生效）"
  else
    bad "H5 误杀了非 appium 进程" "victim $VICTIM 已死"
  fi
  kill "$VICTIM" 2>/dev/null
  if [ -f "$ROOT/build/debug/appium-host.pid" ]; then
    bad "H5 应清掉 pid 文件" "仍存在"
  else
    ok "H5 已清 pid 文件"
  fi
  # pid 文件指向已死 pid
  echo "999999" > "$ROOT/build/debug/appium-host.pid"
  OUT="$(bash "$TARGET" stop --project-root "$ROOT" --port "$PORT" 2>&1)"; RC=$?
  expect_rc "H5 pid 已死时 stop rc=0" 0 "$RC"
  echo ""
fi

# ---------- H6 沙箱内 ensure_appium_server 快失败 ----------
if run_case "H6-沙箱快失败"; then
  stop_fake
  # source _common.sh 的最小前置见文件头 SANDBOX_PROJ（与 H8 共用）
  OUT="$( cd "$SANDBOX_PROJ" && SAFE_RUN_PROFILE=ios APPIUM_PORT="$PORT" bash -c "
      source '$COMMON' >/dev/null 2>&1
      ensure_appium_server
      echo RC=\$?
    " 2>&1 )"
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_contains "H6 沙箱内未就绪返回 rc=3" "$OUT" "RC=3"
  expect_contains "H6 给出宿主 host_server.sh 指引" "$OUT" "host_server.sh ensure"
  expect_contains "H6 说明残废服务原因" "$OUT" "Seatbelt"
  if printf '%s' "$OUT" | grep -q "🚀 启动 Appium"; then
    bad "H6 沙箱内不应尝试启动服务" "出现了启动日志"
  else
    ok "H6 沙箱内未尝试启动服务（不起残废服务）"
  fi
  # 对照：宿主环境（无 SAFE_RUN_PROFILE）且服务已就绪 ⇒ 应复用返回 0
  if start_fake; then
    OUT="$( cd "$SANDBOX_PROJ" && APPIUM_PORT="$PORT" bash -c "
        source '$COMMON' >/dev/null 2>&1
        ensure_appium_server
        echo RC=\$?
      " 2>&1 )"
    expect_contains "H6 服务已就绪时复用 rc=0（沙箱内外一致）" "$OUT" "RC=0"
  else
    bad "H6 宿主对照假服务起不来" "端口 $PORT"
  fi
  echo ""
fi

# ---------- H7 host_server 自身沙箱守卫（review 问题 1：防线不能只靠纪律） ----------
if run_case "H7-沙箱守卫"; then
  stop_fake
  rm -f "$ROOT/build/debug/appium-host.pid"
  OUT="$(SAFE_RUN_PROFILE=ui bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 3 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "H7 沙箱内 ensure rc=2" 2 "$RC"
  expect_contains "H7 说明必须在宿主执行" "$OUT" "宿主"
  expect_contains "H7 说明残废服务风险" "$OUT" "Seatbelt"
  OUT="$(SAFE_RUN_PROFILE=build bash "$TARGET" status --project-root "$ROOT" --port "$PORT" 2>&1)"; RC=$?
  expect_rc "H7 沙箱内 status 亦 rc=2（守卫先于子命令分发）" 2 "$RC"
  if [ -f "$ROOT/build/debug/appium-host.pid" ]; then
    bad "H7 沙箱内不应写 pid 文件" "pid 文件存在"
  else
    ok "H7 沙箱内未写 pid 文件（未起任何服务）"
  fi
  echo ""
fi

# ---------- H8 ready:false 负控（review 问题 2：子串判据会把半死服务判成就绪） ----------
if run_case "H8-ready-false负控"; then
  stop_fake
  rm -f "$ROOT/build/debug/appium-host.pid"
  if ! start_fake 3600; then
    bad "H8 ready:false 假服务起不来" "端口 $PORT"
  else
    OUT="$(bash "$TARGET" status --project-root "$ROOT" --port "$PORT" 2>&1)"; RC=$?
    [ "$VERBOSE" = "1" ] && echo "$OUT"
    expect_rc "H8 ready:false 时 status 判未在线 rc=1" 1 "$RC"
    # ensure 负控：PATH 剥离 appium ⇒ 若误判就绪会返回 0「复用」；正确判未就绪 ⇒ rc=3 缺 CLI
    if PATH="/usr/bin:/bin" command -v appium >/dev/null 2>&1; then
      echo "  ⏭  跳过 H8 ensure 负控：/usr/bin:/bin 里竟有 appium"
    else
      OUT="$(PATH="/usr/bin:/bin" bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 3 2>&1)"; RC=$?
      expect_rc "H8 ready:false 时 ensure 不判就绪（rc=3 而非 0）" 3 "$RC"
    fi
    # 沙箱侧 ensure_appium_server：ready:false ⇒ 不得复用（RC=3）
    OUT="$( cd "$SANDBOX_PROJ" && SAFE_RUN_PROFILE=ios APPIUM_PORT="$PORT" bash -c "
        source '$COMMON' >/dev/null 2>&1
        ensure_appium_server
        echo RC=\$?
      " 2>&1 )"
    expect_contains "H8 沙箱内 ready:false 不判就绪 RC=3" "$OUT" "RC=3"
    # 直接验判据函数（无启动副作用）：ready:false ⇒ 非 0
    OUT="$( cd "$SANDBOX_PROJ" && APPIUM_PORT="$PORT" bash -c "
        source '$COMMON' >/dev/null 2>&1
        appium_online
        echo RC=\$?
      " 2>&1 )"
    expect_contains "H8 appium_online 对 ready:false 判未就绪 RC=1" "$OUT" "RC=1"
  fi
  stop_fake
  echo ""
fi

# ---------- H9 冷启动闭环：ensure 启动 → 写 pid → status 归属 → stop 杀掉且下线 ----------
if run_case "H9-冷启动闭环"; then
  stop_fake
  rm -f "$ROOT/build/debug/appium-host.pid"
  OUT="$(PATH="$TMPROOT/stub:$PATH" bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 15 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "H9 冷启动 ensure rc=0" 0 "$RC"
  expect_contains "H9 报告就绪" "$OUT" "Appium 就绪"
  if [ -f "$ROOT/build/debug/appium-host.pid" ]; then
    ok "H9 启动后写 pid 文件"
  else
    bad "H9 启动后应写 pid 文件" "不存在"
  fi
  P9="$(cat "$ROOT/build/debug/appium-host.pid" 2>/dev/null)"
  if [ -n "$P9" ] && kill -0 "$P9" 2>/dev/null; then
    ok "H9 pid 指向存活进程"
  else
    bad "H9 pid 应指向存活进程" "pid=${P9:-<空>}"
  fi
  OUT="$(bash "$TARGET" status --project-root "$ROOT" --port "$PORT" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "H9 status 在线 rc=0" 0 "$RC"
  expect_contains "H9 status 显示由本脚本启动" "$OUT" "由本脚本启动"
  OUT="$(bash "$TARGET" stop --project-root "$ROOT" --port "$PORT" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "H9 stop 杀自己的服务 rc=0" 0 "$RC"
  expect_contains "H9 stop 报告已停止" "$OUT" "已停止"
  if [ -f "$ROOT/build/debug/appium-host.pid" ]; then
    bad "H9 stop 应清 pid 文件" "仍存在"
  else
    ok "H9 stop 已清 pid 文件"
  fi
  if wait_offline; then
    ok "H9 stop 后服务下线（闭环完成）"
  else
    bad "H9 stop 后服务应下线" "端口 $PORT 仍有响应"
  fi
  echo ""
fi

# ---------- H10 收养启动中的旧 pid（review 问题 3：防 EADDRINUSE + 误删 pid 造成孤儿） ----------
if run_case "H10-收养启动中pid"; then
  stop_fake
  rm -f "$ROOT/build/debug/appium-host.pid"
  # stub 延迟 4s 才 ready；首次 --timeout 1 必超时，且保留进程与 pid 记录
  OUT="$(STUB_DELAY=4 PATH="$TMPROOT/stub:$PATH" bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 1 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "H10 首次 ensure 超时 rc=1" 1 "$RC"
  expect_contains "H10 超时保留进程（不误杀）" "$OUT" "进程仍在跑"
  if [ -f "$ROOT/build/debug/appium-host.pid" ]; then
    ok "H10 超时保留 pid 记录"
  else
    bad "H10 超时应保留 pid 记录" "pid 文件被删"
  fi
  # 二次 ensure：必须收养老 pid 等它就绪，而不是起第二个进程
  OUT="$(STUB_DELAY=4 PATH="$TMPROOT/stub:$PATH" bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 15 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "H10 二次 ensure 收养并等到就绪 rc=0" 0 "$RC"
  expect_contains "H10 明确收养不重复启动" "$OUT" "不重复启动"
  N="$(pgrep -f "$TMPROOT/stub/appium" | wc -l | tr -d ' ')"
  if [ "$N" = "1" ]; then
    ok "H10 只有一个 appium 进程（未重复启动）"
  else
    bad "H10 应只有一个 appium 进程" "实际 $N 个"
  fi
  bash "$TARGET" stop --project-root "$ROOT" --port "$PORT" >/dev/null 2>&1
  wait_offline || bad "H10 清理：stop 后服务应下线" "端口 $PORT 仍有响应"
  echo ""
fi

# ---------- H11 --timeout 边界（review 问题 8：0 会让轮询体不执行、误报超时） ----------
if run_case "H11-timeout边界"; then
  OUT="$(bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 0 2>&1)"; RC=$?
  expect_rc "H11 --timeout 0 rc=2" 2 "$RC"
  expect_contains "H11 说明至少 1 秒" "$OUT" "至少 1 秒"
  OUT="$(bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout abc 2>&1)"; RC=$?
  expect_rc "H11 --timeout 非数字 rc=2" 2 "$RC"
  echo ""
fi

# ---------- H12 启动轮询期间进程退出（rc=1 + 清 pid + 给日志尾部） ----------
if run_case "H12-启动中进程退出"; then
  stop_fake
  rm -f "$ROOT/build/debug/appium-host.pid"
  OUT="$(PATH="$TMPROOT/stub-crash:$PATH" bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 5 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "H12 启动中进程退出 rc=1" 1 "$RC"
  expect_contains "H12 报告进程已退出" "$OUT" "进程已退出"
  expect_contains "H12 给出日志尾部便于定位" "$OUT" "模拟启动失败"
  if [ -f "$ROOT/build/debug/appium-host.pid" ]; then
    bad "H12 进程死后应清 pid 文件" "仍存在"
  else
    ok "H12 进程死后已清 pid 文件"
  fi
  echo ""
fi

# ---------- H13 收养期间进程死亡（r2-N1：rm pid 破坏性路径负控 + 收养分支 tail 重定向负控） ----------
if run_case "H13-收养中进程死亡"; then
  stop_fake
  rm -f "$ROOT/build/debug/appium-host.pid"
  # stub 恒不就绪（delay=3600）且 2s 后自毁；首次 --timeout 1 超时时进程仍活 ⇒ 保留 pid
  OUT="$(STUB_DELAY=3600 STUB_DIE=2 PATH="$TMPROOT/stub:$PATH" bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 1 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "H13 首次 ensure 超时 rc=1（进程尚活）" 1 "$RC"
  if [ -f "$ROOT/build/debug/appium-host.pid" ]; then
    ok "H13 进程死亡前保留 pid 记录"
  else
    bad "H13 进程死亡前应保留 pid" "pid 文件被删"
  fi
  # 二次 ensure 进入收养分支，轮询期间进程死亡 ⇒ rc=1 + 报告退出 + 清 pid + 日志尾部可见
  OUT="$(PATH="$TMPROOT/stub:$PATH" bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 10 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "H13 收养期间进程死亡 rc=1" 1 "$RC"
  expect_contains "H13 报告既有进程已退出" "$OUT" "既有 Appium 进程已退出"
  expect_contains "H13 收养分支日志尾部可见（tail 重定向负控）" "$OUT" "模拟就绪前崩溃"
  if [ -f "$ROOT/build/debug/appium-host.pid" ]; then
    bad "H13 进程死后应清 pid 文件" "仍存在"
  else
    ok "H13 进程死后已清 pid 文件"
  fi
  echo ""
fi

# ---------- H14 收养超时（r2-N1：进程活着但恒不就绪 ⇒ 保留进程与 pid 记录） ----------
if run_case "H14-收养超时"; then
  stop_fake
  rm -f "$ROOT/build/debug/appium-host.pid"
  OUT="$(STUB_DELAY=3600 PATH="$TMPROOT/stub:$PATH" bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 1 2>&1)"; RC=$?
  expect_rc "H14 首次 ensure 超时 rc=1" 1 "$RC"
  OUT="$(PATH="$TMPROOT/stub:$PATH" bash "$TARGET" ensure --project-root "$ROOT" --port "$PORT" --timeout 2 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "H14 收养超时 rc=1" 1 "$RC"
  expect_contains "H14 报告仍未就绪且保留记录" "$OUT" "仍未就绪"
  if [ -f "$ROOT/build/debug/appium-host.pid" ]; then
    ok "H14 收养超时保留 pid 记录"
  else
    bad "H14 收养超时应保留 pid 记录" "pid 文件被删"
  fi
  P14="$(cat "$ROOT/build/debug/appium-host.pid" 2>/dev/null)"
  if [ -n "$P14" ] && kill -0 "$P14" 2>/dev/null; then
    ok "H14 收养超时不误杀进程"
  else
    bad "H14 进程应仍存活" "pid=${P14:-<空>}"
  fi
  # 清理：stop 杀掉本脚本起的 stub
  OUT="$(bash "$TARGET" stop --project-root "$ROOT" --port "$PORT" 2>&1)"; RC=$?
  expect_rc "H14 清理 stop rc=0" 0 "$RC"
  wait_offline || bad "H14 清理：stop 后服务应下线" "端口 $PORT 仍有响应"
  echo ""
fi

echo "================================"
if [ "$FAIL" -eq 0 ]; then
  if [ "$PASS" -eq 0 ]; then echo "❌ 未执行任何用例（-f 关键字无命中）"; exit 2; fi
  echo "✅ 全部通过（${PASS} 项）"; exit 0
fi
echo "❌ 失败 ${FAIL} 项 / 通过 ${PASS} 项："
for f in "${FAILED_CASES[@]}"; do echo "   - ${f}"; done
exit 1