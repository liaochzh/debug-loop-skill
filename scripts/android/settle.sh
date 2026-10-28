#!/bin/bash
# settle.sh — 等待 UI 静止（语义树优先；语义不可用时降级整屏像素）
#
# 用法: ./settle.sh [--mode auto|ui|screen] [--timeout 25] [--interval 0.4] [--keep]
#   --mode  auto（默认）语义树可用则比 UI 树，不可用时自动降级整屏像素
#           ui         只比 UI 树；语义树无内容 / dump 连续失败 ⇒ rc=3（判定不可信）
#           screen     只比整屏像素（适合 Flutter 未开语义树、WebView、游戏）
#   --timeout  整体时长上限（秒，默认 25；auto 降级后**从降级时刻重新计**）
#   --interval 采样间隔（秒，小数可用，默认 0.4；必须 > 0）
#   --keep     成功时也保留两帧（默认：失败保留、成功清理）
#
# 退出码: 0 = 已静止（输出必带「判据=ui|screen」）
#         1 = 超时未静止（⚠️ 文案 + 替代手段，不是异常）
#         2 = 用法错误
#         3 = 判定不可信（**仅 --mode ui**：语义树无内容 / dump 持续失败）
#         ⚠️ 本脚本的 3 ≠ bg.sh 的 3（LOST）——这里指「无可用判据」，不是进程丢失。
#
# 判据为什么不是字节数（2026-10-27 评审结论）：Flutter 未开 semantics 时骨架 dump
#   仍可达 1–3 KB，字节阈值会双向失准。⇒ 主判据 = `ui_has_semantics`（text/desc 节点数），
#   字节数只作**完整性下限**；整屏像素另有一个有效性下限，防止 0 字节截图被当成「静止」。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

MODE="auto"
TIMEOUT=25
INTERVAL=0.4
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)     [ $# -ge 2 ] || { echo "❌ --mode 需要取值" >&2; exit 2; };     MODE="$2"; shift 2 ;;
    --timeout)  [ $# -ge 2 ] || { echo "❌ --timeout 需要取值" >&2; exit 2; };  TIMEOUT="$2"; shift 2 ;;
    --interval) [ $# -ge 2 ] || { echo "❌ --interval 需要取值" >&2; exit 2; }; INTERVAL="$2"; shift 2 ;;
    --keep)     KEEP=1; shift ;;
    -h|--help)  echo "用法: ./settle.sh [--mode auto|ui|screen] [--timeout 25] [--interval 0.4] [--keep]"; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done
case "$MODE" in auto|ui|screen) ;; *) echo "❌ --mode 只支持 auto|ui|screen（收到: ${MODE}）" >&2; exit 2 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) echo "❌ --timeout 必须是正整数（收到: ${TIMEOUT}）" >&2; exit 2 ;; esac
case "$INTERVAL" in ''|*[!0-9.]*) echo "❌ --interval 必须是数字（收到: ${INTERVAL}）" >&2; exit 2 ;; esac
case "$INTERVAL" in *.*.*) echo "❌ --interval 格式非法（收到: ${INTERVAL}）" >&2; exit 2 ;; esac
# 无 1-9 数字 ⇒ 值为 0（含 "0" / "0." / ".0" / "." ）⇒ 忙等或 sleep 用法错误，一律拒绝
case "$INTERVAL" in *[1-9]*) ;; *) echo "❌ --interval 必须大于 0（防忙等）" >&2; exit 2 ;; esac

DEVICE=$(require_device)

# 单次 UI 采样：设备侧固定 /sdcard/ui_settle.xml（**不得**回用 /sdcard/ui.xml —— 会与 ui.sh 互踩）
# stdout: "ok <字节数>" | "fail 0"（fail 与「成功但无内容」是两种状态，不得混为一谈）
_ui_sample() {  # <宿主机目标文件>
  local dest="$1" n
  if perl -e "alarm ${SETTLE_FRAME_ALARM}; exec @ARGV" adb -s "$DEVICE" shell uiautomator dump /sdcard/ui_settle.xml >/dev/null 2>&1; then
    if adb -s "$DEVICE" pull /sdcard/ui_settle.xml "$dest" >/dev/null 2>&1; then
      n=$(wc -c < "$dest" | tr -dc '0-9' || true)
      printf 'ok %s\n' "${n:-0}"
      return 0
    fi
  fi
  printf 'fail 0\n'
}

# 单次整屏采样：必须 `screencap -p`（漏 -p 会得到 W×H×4 原始 RGBA，帧无法用 Read 查看）
_screen_sample() {  # <宿主机目标文件>
  local dest="$1" n
  if adb -s "$DEVICE" exec-out screencap -p > "$dest" 2>/dev/null; then
    n=$(wc -c < "$dest" | tr -dc '0-9' || true)
    printf 'ok %s\n' "${n:-0}"
    return 0
  fi
  printf 'fail 0\n'
}

# 失败/超时时打印保留的采样帧（证据分层：结论要能指到具体文件）
_keep_frames() {
  local f
  for f in "$LOG_DIR/.settle_1.xml" "$LOG_DIR/.settle_2.xml" "$LOG_DIR/.settle_1.png" "$LOG_DIR/.settle_2.png"; do
    if [ -f "$f" ]; then
      echo "📎 采样帧保留: ${f} ($(wc -c < "$f" | tr -dc '0-9') B)"
    fi
  done
}

OVERALL_START=$(date +%s)
SAMPLES=0
SWITCHED=0
PNG_OK=0     # screen 阶段有效帧数（>0 才说明「判据可用」）
PNG_BAD=0    # screen 阶段失败/无效帧数

_done() {  # <判据> <字节数>
  local crit="$1" bytes="$2" elapsed
  elapsed=$(( $(date +%s) - OVERALL_START ))
  echo "✅ UI 已静止（判据=${crit}，两帧 ${bytes} B，耗时 ${elapsed}s，采样 ${SAMPLES} 次）"
  if [ "$KEEP" -eq 0 ]; then
    rm -f "$LOG_DIR"/.settle_*.xml "$LOG_DIR"/.settle_*.png
  fi
  exit 0
}

PHASE="$MODE"
if [ "$PHASE" = "auto" ]; then PHASE="ui"; fi
PHASE_START=$(date +%s)
PREV=""
FAILS=0

while :; do
  NOW=$(date +%s)
  REMAIN=$((TIMEOUT - (NOW - PHASE_START)))
  if [ "$REMAIN" -le 0 ]; then break; fi

  SAMPLES=$((SAMPLES + 1))
  SLOT=$((SAMPLES % 2))
  if [ "$SLOT" -eq 0 ]; then SLOT=2; fi

  if [ "$PHASE" = "ui" ]; then
    CUR="$LOG_DIR/.settle_${SLOT}.xml"
    OUT=$(_ui_sample "$CUR")
    STATUS="${OUT%% *}"
    BYTES="${OUT##* }"
    if [ -n "$BYTES" ]; then : ; else BYTES=0; fi

    if [ "$STATUS" = "fail" ]; then
      FAILS=$((FAILS + 1))
      echo "⚠️  uiautomator dump 失败（第 ${FAILS} 次）"
      # ⚠️ 必须清空 PREV：本轮没拿到新帧，若保留上一帧的路径，而下一次成功采样恰好轮到**同一槽位文件**
      #    （SLOT 按 SAMPLES 奇偶轮转，失败的迭代也递增 SAMPLES）⇒ `cmp` 变成同路径自比 ⇒ 恒等 ⇒
      #    单帧即判「已静止」（2026-10-27 review 命中：动画页偶发单次 dump 失败时复发假阳性）。
      PREV=""
      # 预算感知：剩余不足一帧上限（dump 自带 alarm）或连续 2 次失败 ⇒ 降级/判不可信
      if [ "$FAILS" -ge 2 ] || [ "$REMAIN" -lt "$SETTLE_FRAME_ALARM" ]; then
        if [ "$MODE" = "ui" ]; then
          if [ "$FAILS" -ge 2 ]; then
            echo "❌ 判定不可信：dump 持续失败（--mode ui 下无可降级路径）"
          else
            echo "❌ 判定不可信：dump 失败且剩余预算不足，未能重试（可加大 --timeout）"
          fi
          _keep_frames
          exit 3
        fi
        echo "ℹ️ uiautomator dump 连续失败/预算耗尽，降级整屏像素（这是 dump 失败，不是页面为空）"
        PHASE="screen"
        PHASE_START=$(date +%s)
        PREV=""
        FAILS=0
        SWITCHED=1
        continue
      fi
      sleep "$INTERVAL"
      continue
    fi

    # 先判「dump 完整性」再判「有没有语义」：截断/半截拉取也会让节点数为 0，
    # 若顺序反过来会把「dump 不完整」误报成「页面无语义」，把排查引到 Maestro/Vision。
    # ⚠️ 但不能只 sleep+continue：dump 恒不完整时也必须像 fail 一样有「重试上限 + 出口」，
    #    否则 auto 模式会空烧整个 timeout 且永不调用像素判据（2026-10-27 复审 N-1）。
    # ⚠️ FAILS 的归零点必须在「拿到完整且有语义的帧」之后，不能在完整性检查之前重置，
    #    否则每次都被清零 ⇒ 连续计数永远是 1。
    if [ "$BYTES" -lt "$MIN_DUMP_BYTES" ]; then
      FAILS=$((FAILS + 1))
      echo "⚠️  dump 不完整（${BYTES} B < ${MIN_DUMP_BYTES} B，第 ${FAILS} 次），本轮不判静止"
      PREV=""
      if [ "$FAILS" -ge 2 ] || [ "$REMAIN" -lt "$SETTLE_FRAME_ALARM" ]; then
        if [ "$MODE" = "ui" ]; then
          if [ "$FAILS" -ge 2 ]; then
            echo "❌ 判定不可信：dump 持续不完整（--mode ui 下无可降级路径）"
          else
            echo "❌ 判定不可信：dump 不完整且剩余预算不足，未能重试（可加大 --timeout）"
          fi
          _keep_frames
          exit 3
        fi
        echo "ℹ️ uiautomator dump 持续不完整/预算耗尽，降级整屏像素（这是 dump 不可用，不是页面为空）"
        PHASE="screen"
        PHASE_START=$(date +%s)
        PREV=""
        FAILS=0
        SWITCHED=1
        continue
      fi
      sleep "$INTERVAL"
      continue
    fi

    NODES=$(ui_has_semantics "$CUR")
    if [ -z "$NODES" ]; then NODES=0; fi
    if [ "$NODES" -eq 0 ]; then
      if [ "$MODE" = "ui" ]; then
        echo "❌ 判定不可信：语义树无内容（0 个 text/desc 节点）"
        _keep_frames
        exit 3
      fi
      echo "ℹ️ 语义树无内容（0 个 text/desc 节点），改用整屏像素比对（每帧约 1s，必要时 --timeout ≥ 15）"
      PHASE="screen"
      PHASE_START=$(date +%s)
      PREV=""
      FAILS=0
      SWITCHED=1
      continue
    fi

    # 走到这里：dump 完整且语义树有内容 ⇒ 本帧是「有效采样」，失败计数归零
    FAILS=0
    if [ -n "$PREV" ] && cmp -s "$PREV" "$CUR"; then
      _done "ui" "$BYTES"
    fi
    PREV="$CUR"
    sleep "$INTERVAL"
    continue
  fi

  # ---------- screen 阶段 ----------
  CUR="$LOG_DIR/.settle_${SLOT}.png"
  OUT=$(_screen_sample "$CUR")
  STATUS="${OUT%% *}"
  BYTES="${OUT##* }"
  if [ -n "$BYTES" ]; then : ; else BYTES=0; fi

  # 三态同样要分开：命令本身失败（screencap 不可用）≠ 截到了但内容无效（0 字节/截断）
  if [ "$STATUS" = "fail" ]; then
    PNG_BAD=$((PNG_BAD + 1))
    echo "⚠️  screencap 命令失败（第 ${PNG_BAD} 次），本轮不判静止"
    PREV=""
    sleep "$INTERVAL"
    continue
  fi

  if [ "$BYTES" -lt "$SETTLE_MIN_PNG_BYTES" ]; then
    PNG_BAD=$((PNG_BAD + 1))
    echo "⚠️  截图无效（${BYTES} B < ${SETTLE_MIN_PNG_BYTES} B），本轮不判静止"
    PREV=""
    sleep "$INTERVAL"
    continue
  fi

  PNG_OK=$((PNG_OK + 1))
  if [ -n "$PREV" ] && cmp -s "$PREV" "$CUR"; then
    _done "screen" "$BYTES"
  fi
  PREV="$CUR"
  sleep "$INTERVAL"
done

ELAPSED=$(( $(date +%s) - OVERALL_START ))
# screen 阶段一帧都没取到 ⇒ 不是「页面在动」，而是「判据不可用」：不能报成「未静止」误导排查
if [ "$PHASE" = "screen" ] && [ "$PNG_OK" -eq 0 ] && [ "$PNG_BAD" -gt 0 ]; then
  echo "⚠️  整屏截图始终不可用（${PNG_BAD} 次全部失败/无效，耗时 ${ELAPSED}s）⇒ 无法判定静止"
  echo "💡 先 shot.sh 确认能否截图；设备不支持 screencap -p 时改用 maestro/assert.sh 轮询或 logwatch.sh <签名>"
  _keep_frames
  exit 1
fi
echo "⚠️  UI 在 ${TIMEOUT}s 内未静止（判据=${PHASE}，已采样 ${SAMPLES} 次，耗时 ${ELAPSED}s）"
if [ "$SWITCHED" -eq 1 ]; then
  echo "💡 该页语义树不可用且像素持续变化：改用 maestro/assert.sh 轮询 / shot.sh 连拍两张比对 / logwatch.sh <签名>"
else
  if [ "$MODE" = "screen" ]; then
    echo "💡 整屏像素含时钟/视频会永不静止：加大 --timeout，或改用 maestro/assert.sh 轮询"
  else
    echo "💡 页面可能仍在动画/加载：先 shot.sh 看真实画面，再决定是否加 --timeout"
  fi
fi
_keep_frames
exit 1
