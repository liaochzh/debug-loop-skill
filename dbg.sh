#!/bin/bash
# dbg.sh — 人用短入口（agent 直接用绝对路径调 scripts/ 下脚本即可，无需经过本文件）
#
# 用法: dbg <platform> <script> [args...]
# 示例: dbg android logs 200 WebRTC
#       dbg macos run
#
# 安装 alias（加到 ~/.zshrc）:
#   alias dbg='bash ~/.config/opencode/skills/debug-loop/dbg.sh'
#
# 注意：必须在 Flutter 项目根执行（依赖 $PWD/.debug.env）

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="${1:-}"
SCRIPT_NAME="${2:-}"

if [ -z "$PLATFORM" ] || [ -z "$SCRIPT_NAME" ]; then
  echo "用法: dbg <platform> <script> [args...]"
  echo "  platform: android | ios | macos | windows"
  echo "  script:   该平台目录下的脚本名（如 run / logs / shot / settle / findtap）"
  echo "环境自检: bash $(dirname "${BASH_SOURCE[0]}")/scripts/doctor.sh"
  exit 1
fi

shift 2
exec bash "$SKILL_DIR/scripts/$PLATFORM/$SCRIPT_NAME" "$@"
