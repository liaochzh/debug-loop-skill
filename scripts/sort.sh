#!/bin/bash
# sort.sh — 去重/排序载体（autoDebug 无 sort/uniq 白名单时的替代）
# 用法:
#   sort.sh [选项] [文件]
#   echo ... | sort.sh [选项]
# 选项:
#   -u          去重（uniq）
#   -r          逆序
#   -n          数值排序
#   -k <列>     按第 N 列排序（默认整行；列从 1 起）
#   -o <文件>   写入文件（写入 LOG_DIR 内；不给则 stdout）
# 退出码: 0=成功 / 1=失败
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/_env.sh" ]; then
  source "$SCRIPT_DIR/_env.sh"
  if [ -f ".debug.env" ]; then
    if ! parse_debug_env ".debug.env"; then
      echo "❌ .debug.env 解析失败（sort.sh）" >&2
      exit 1
    fi
    if ! validate_debug_env; then
      echo "❌ .debug.env 校验失败（sort.sh）" >&2
      exit 1
    fi
  fi
fi
# LOG_DIR 缺省（与 _common.sh 一致）
LOG_DIR="${LOG_DIR:-build/debug}"

UNIQ=0
REVERSE=0
NUMERIC=0
KEYCOL=""
OUTFILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -u) UNIQ=1; shift ;;
    -r) REVERSE=1; shift ;;
    -n) NUMERIC=1; shift ;;
    -k) KEYCOL="${2:-}"; shift 2 ;;
    -o) OUTFILE="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -*) echo "❌ 未知选项: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

# 输入来源：文件参数或 stdin
INPUT=""
if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
  INPUT="$1"
  if [ ! -f "$INPUT" ]; then
    echo "❌ 文件不存在: $INPUT" >&2
    exit 1
  fi
fi

# 构造 sort 参数（用字符串，避免空数组在 set -u 下未绑定）
SORT_ARGS=""
[ "$REVERSE" -eq 1 ] && SORT_ARGS="$SORT_ARGS -r"
[ "$NUMERIC" -eq 1 ] && SORT_ARGS="$SORT_ARGS -n"
if [ -n "$KEYCOL" ]; then
  SORT_ARGS="$SORT_ARGS -k $KEYCOL"
fi
[ "$UNIQ" -eq 1 ] && SORT_ARGS="$SORT_ARGS -u"

# 执行
if [ -n "$INPUT" ]; then
  # shellcheck disable=SC2086
  RESULT=$(sort $SORT_ARGS "$INPUT")
else
  # shellcheck disable=SC2086
  RESULT=$(sort $SORT_ARGS)
fi

# 输出
if [ -n "$OUTFILE" ]; then
  # 安全：输出文件必须落在 LOG_DIR 内（比照 §5-H2 自校验；拒绝对外形态/.. 组件）
  case "$OUTFILE" in
    /*) echo "❌ -o 路径必须是 LOG_DIR 内的相对路径（当前: ${OUTFILE}）" >&2; exit 1 ;;
  esac
  # 拒 .. 组件
  case "/$OUTFILE/" in
    */../*) echo "❌ -o 路径不得含 .. 组件（当前: ${OUTFILE}）" >&2; exit 1 ;;
  esac
  OUTFILE="$LOG_DIR/$OUTFILE"
  mkdir -p "$(dirname "$OUTFILE")"
  printf '%s\n' "$RESULT" > "$OUTFILE"
  echo "✅ 已写入: $OUTFILE"
else
  printf '%s\n' "$RESULT"
fi
