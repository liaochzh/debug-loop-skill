#!/bin/bash
# smart_lib.sh — macOS Vision 智能操作公共库（由 smart_tap.sh / smart_assert.sh source，不直接执行）
#
# 依赖: python3 + PIL（vision_read.py 已依赖）、cliclick 或 osascript、终端「屏幕录制」+「辅助功能」权限
# 调用方需先 source <macos>/_common.sh（提供 LOG_DIR / MACOS_APP_NAME）

VISION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VISION_SCRIPT="$VISION_DIR/vision_read.py"
SMART_MACOS_DIR="$(cd "$VISION_DIR/../macos" && pwd)"

# 可调参数（env 覆盖）
SMART_MIN_CONF="${SMART_MIN_CONF:-0.7}"                                    # 自动点击置信度下限
SMART_DANGER_RE="${SMART_DANGER_RE:-解绑|删除|注销|重置|付款|支付|退出登录|登出|卸载|清空|格式化|解约|取消订阅|转账|delete|remove|unbind|unlink|reset|payment|pay\\b|logout|log out|sign out|logoff|uninstall|format|erase|cancel subscription|transfer|purchase|deactivate}"  # 危险词（拒绝自动点击；中英双语）

# 桌面尺寸（point）：输出 "W H"，失败输出空
# 守卫（内移）：osascript 不可用/无「辅助功能」权限 ⇒ 管道非 0 属「非 0 但正常语义」，
#   不得触发 errexit（调用方 `smart_tap.sh` 需自行判断空值并降级）
sl_screen_points() {
  osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null \
    | tr -d ' ' | awk -F, 'NF>=4{print $3, $4}' || true
}

# 全屏截图，打印图片路径
# ⚠️ 失败时必须让 shot.sh 的提示**可达**：其「❌ 截图失败 + 屏幕录制权限引导」**打在 stdout**，
#    裸 `>/dev/null` 会连它一起吞掉；而本函数末句是 `echo` ⇒ 改前调用方 `IMG=$(sl_shot)`
#    **rc=0（静默"成功"）**，且 `screen.png` 仍是**上一次的陈旧截图** ⇒ 后续按旧坐标点击 /
#    智能断言假阳性（实测语义见 docs/plan/20261017-debugloop-guard-inventory.md §3.7）。
#    （2026-10-17 由第 1 轮异模型复审命中；对照同为「先转发子脚本」的 `sl_vision`：其 ❌ 打 stderr，故不受影响。）
sl_shot() {
  local out
  if ! out="$(bash "$SMART_MACOS_DIR/shot.sh" 2>&1)"; then
    printf '%s\n' "$out" >&2
    return 3
  fi
  # 兜底：shot.sh 成功路径**必有两行 stdout**（「📸 截图中…」+「✅ 截图完成: …」）⇒ 空输出属异常
  # （2026-10-17 第 2 轮异模型复审 P3-12 登记；不判空则调用方会拿陈旧/缺图路径继续跑）。
  if [ -z "$out" ]; then
    echo "❌ 截图失败：shot.sh 未输出任何内容（疑似未产出截图）" >&2
    return 3
  fi
  echo "$LOG_DIR/screen.png"
}

# 调 vision_read.py；成功打印 JSON 文件路径
# sl_vision <image> <task> <question> [region]
sl_vision() {
  local image="$1" task="$2" question="${3:-}" region="${4:-}"
  local out="$LOG_DIR/vision.json" err="$LOG_DIR/vision.err"
  local args=(--image "$image" --task "$task" --no-cache)
  [ -n "$question" ] && args+=(--question "$question")
  [ -n "$region" ] && args+=(--region "$region")
  if ! python3 "$VISION_SCRIPT" "${args[@]}" > "$out" 2>"$err"; then
    echo "❌ Vision 调用失败（详见 ${err}）" >&2
    [ -f "$err" ] && tail -5 "$err" >&2 || true
    return 3
  fi
  echo "$out"
}

# 从 vision JSON 选目标元素；成功打印 TSV: cx_px \t cy_px \t conf \t state \t text
# 要求关键词命中且 confidence >= min_conf，否则打印候选并返回 1
# sl_select <json> <keyword> <min_conf>
sl_select() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, json
path, kw, minconf = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    d = json.load(open(path, encoding="utf-8"))
except Exception as e:
    print(f"JSON 解析失败: {e}", file=sys.stderr); sys.exit(1)
els = d.get("elements") or []
state = (d.get("screen") or {}).get("state", "normal")
kw_l = kw.lower().strip()
matched = [e for e in els if kw_l and kw_l in (e.get("text", "") or "").lower()]
if not matched:
    print(f"未找到包含 {kw!r} 的元素（screen.state={state}）", file=sys.stderr)
    for e in els[:20]:
        print(f"  - {e.get('text','')!r} conf={e.get('confidence')} bbox={e.get('bbox')}", file=sys.stderr)
    sys.exit(1)
ok = [e for e in matched if float(e.get("confidence", 0)) >= minconf]
if not ok:
    print(f"命中元素置信度均低于阈值 {minconf}，拒绝自动操作：", file=sys.stderr)
    for e in matched:
        print(f"  - {e.get('text','')!r} conf={e.get('confidence')} bbox={e.get('bbox')}", file=sys.stderr)
    sys.exit(1)
e = sorted(ok, key=lambda x: -float(x.get("confidence", 0)))[0]
x1, y1, x2, y2 = e["bbox"]
print(f"{(x1+x2)//2}\t{(y1+y2)//2}\t{e.get('confidence')}\t{state}\t{e.get('text','')}")
PY
}

# 危险词判定：命中返回 0；正则错误时 fail-closed（视为危险，拒绝自动点击）
sl_is_dangerous() {
  local rc=0
  printf '%s' "${1:-}" | grep -Eqi "$SMART_DANGER_RE" || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "⚠️ 危险词正则错误（SMART_DANGER_RE），保守判定为危险" >&2
    return 0
  fi
  return "$rc"
}

# 打印 vision JSON 的 screen.state（解析失败或缺失时输出 normal）
sl_state() {
  python3 - "$1" <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("normal"); sys.exit(0)
print((d.get("screen") or {}).get("state", "normal"))
PY
}

# 关键词是否存在（elements[] 或 ocr_text[]），用于断言；命中打印匹配文本并返回 0
sl_exists() {
  python3 - "$1" "$2" <<'PY'
import sys, json
path, kw = sys.argv[1], sys.argv[2].lower().strip()
if not kw:
    sys.exit(1)
try:
    d = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(1)
for e in d.get("elements") or []:
    if kw in (e.get("text", "") or "").lower():
        print(e.get("text", "")); sys.exit(0)
for line in d.get("ocr_text") or []:
    if kw in (line or "").lower():
        print(line); sys.exit(0)
sys.exit(1)
PY
}

# 像素 -> 屏幕 point 换算（Retina 兼容）：sl_px_to_point <image> <x_px> <y_px> <screen_w_pt> <screen_h_pt>
sl_px_to_point() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import sys
from PIL import Image
img, x, y, sw, sh = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
if sw <= 0 or sh <= 0:
    print("无效的屏幕 point 尺寸", file=sys.stderr); sys.exit(1)
w, h = Image.open(img).size
print(f"{x * sw / w:.0f} {y * sh / h:.0f}")
PY
}

sl_click_point() { bash "$SMART_MACOS_DIR/click.sh" "$1" "$2"; }
sl_activate()    { [ -n "${1:-}" ] && bash "$SMART_MACOS_DIR/click.sh" --activate "$1" >/dev/null 2>&1 || true; }