#!/bin/bash
# test.sh — 运行单元测试（平台无关，位于 scripts/debug/ 根）
# 用法: ./test.sh [测试文件路径]   默认全量
set -euo pipefail

TEST_PATH="${1:-}"

if [ -n "$TEST_PATH" ]; then
  echo "🧪 运行测试: $TEST_PATH"
  flutter test "$TEST_PATH"
else
  echo "🧪 运行全量单元测试..."
  flutter test
fi
