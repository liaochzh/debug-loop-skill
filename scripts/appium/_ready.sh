#!/bin/bash
# _ready.sh — Appium `/status` 就绪判据的**单一来源**（host_server.sh 与 _common.sh 共用）
#
# 为什么单独一个文件：判据同一份知识原先写两处（host_server.sh 的 online / _common.sh 的
#   appium_online），改一处另一处必然跟着改（CleanCode G5-DRY）。本文件**无副作用**，
#   不依赖 pubspec.yaml / .debug.env，故宿主侧与沙箱侧都能安全 source。
#
# ⚠️ 判据必须是 `"ready": true`，**不能只匹配 `"ready"` 子串**：
#   Appium 在服务半死/驱动异常时会返回 `"ready": false`，只匹配子串会把它判成**就绪**，
#   恰好是最不该判就绪的时刻（2026-11-16 review 问题 2）。

# 允许 `"ready" : true` 这类带空格的合法 JSON 形态
APPIUM_READY_RE='"ready"[[:space:]]*:[[:space:]]*true'

# appium_status_ready <server-base-url> ⇒ 0=就绪 / 非0=未就绪
appium_status_ready() {
  curl -s -m 3 "${1%/}/status" 2>/dev/null | grep -qE "$APPIUM_READY_RE"
}