#!/bin/bash
# _ios_device.sh — iOS 真机枚举（**单一来源**，供 doctor.sh 与 appium/_common.sh 共用）
#
# 为什么单独成文件：
#   - `doctor.sh` 的承诺是「缺 .debug.env 也能跑完并报告」，而 `appium/_common.sh` 会
#     `mkdir -p build/debug` 并在缺 .debug.env 时 `exit 1` ⇒ **诊断脚本不能 source 它**。
#   - 但真机 UDID 的识别规则（xctrace 的 Devices 段里 Mac 自己排最前、iPhone 行是
#     「两组括号」）若各写一份必然漂移 —— 故抽到这里，两边都 source。
#
# 约定：本文件**只定义函数**（不打印、不 mkdir、不 exit、不解析 .debug.env），可被安全 source。

# 列出已连接的 iOS 真机。
# 输出（每行）：`<设备名>\t<硬件 UDID>`；无设备 ⇒ 返回 1 且不打印。
#
# 只取 `== Devices ==` 段（模拟器在 `== Simulators ==` 段，另行用 simctl 判）；
# 该段第一行是 Mac 自己，且只有一层括号 `Name (UUID)` ⇒ 用「两组括号」把它排除。
list_ios_devices() {
  command -v xcrun >/dev/null 2>&1 || return 1
  xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Devices ==/{f=1;next} /^== Simulators ==/{f=0} f' \
    | grep -E '\([0-9][^)]*\)[[:space:]]*\([0-9A-Fa-f-]{25,}\)' \
    | perl -ne 'if (/^(.*?)\s*\([0-9][^)]*\)\s*\(([0-9A-Fa-f-]{25,})\)\s*$/) { print "$1\t$2\n" }' \
    || true
}

# 首台 iOS 真机 UDID（保持 appium 侧既有语义：无设备 ⇒ 空输出 + rc=0，由调用方判空）
resolve_ios_device() {
  list_ios_devices 2>/dev/null | head -1 | awk -F'\t' '{print $2}' | grep -E '^[0-9A-Fa-f-]{25,}$' || true
}
