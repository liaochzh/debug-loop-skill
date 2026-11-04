#!/bin/bash
# _ios_device.sh — iOS 真机枚举（**单一来源**，供 doctor.sh 与 appium/_common.sh 共用）
#
# 枚举顺序：`xctrace`（旧）→ `devicectl --json-output`（Xcode 15+，沙箱内可用）→
#           `devicectl list devices` 表格（`--json-output` 不支持时的兜底）→ `idevice_id`（仅 UDID）。
#
# 为什么单独成文件：
#   - `doctor.sh` 的承诺是「缺 .debug.env 也能跑完并报告」，而 `appium/_common.sh` 会
#     `mkdir -p build/debug` 并在缺 .debug.env 时 `exit 1` ⇒ **诊断脚本不能 source 它**。
#   - 但真机 UDID 的识别规则（xctrace 的 Devices 段里 Mac 自己排最前、iPhone 行是
#     「两组括号」）若各写一份必然漂移 —— 故抽到这里，两边都 source。
#
# 约定：本文件**只定义函数**（不打印、不 mkdir、不 exit、不解析 .debug.env），可被安全 source。

# devicectl 的结构化枚举：输出 `<设备名>\t<硬件 UDID>`（只取 reality=physical 的真机）。
# 依赖 Apple 的机器可读 schema：`result.devices[].hardwareProperties.{udid,reality}` +
#   `deviceProperties.name`（`xcrun devicectl list devices --json-output <file>`）。
# 失败（老版本不支持该参数 / python3 缺失 / 无真机）⇒ 返回 1，由调用方继续回退。
_devicectl_json_list() {
  command -v python3 >/dev/null 2>&1 || return 1
  local tmp rc
  tmp=$(mktemp "${TMPDIR:-/tmp}/devicectl_devices.XXXXXX") || return 1
  if ! xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; return 1
  fi
  python3 - "$tmp" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
rows = []
for dev in (data.get("result") or {}).get("devices") or []:
    hw = dev.get("hardwareProperties") or {}
    if hw.get("reality") != "physical":
        continue
    udid = hw.get("udid") or ""
    if not udid:
        continue
    name = (dev.get("deviceProperties") or {}).get("name") or "iPhone"
    rows.append(f"{name}\t{udid}")
if not rows:
    sys.exit(1)
print("\n".join(rows))
PY
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

# 列出已连接的 iOS 真机。
# 输出（每行）：`<设备名>\t<硬件 UDID>`；无设备 ⇒ 返回 1 且不打印。
#
# 只取 `== Devices ==` 段（模拟器在 `== Simulators ==` 段，另行用 simctl 判）；
# 该段第一行是 Mac 自己，且只有一层括号 `Name (UUID)` ⇒ 用「两组括号」把它排除。
list_ios_devices() {
  local out=""
  # 主路径：xctrace（旧机制，兼容老 Xcode）；xcrun 缺失时跳过（后面还有 idevice_id 回退）
  if command -v xcrun >/dev/null 2>&1; then
    out=$(xcrun xctrace list devices 2>/dev/null \
      | awk '/^== Devices ==/{f=1;next} /^== Simulators ==/{f=0} f' \
      | grep -E '\([0-9][^)]*\)[[:space:]]*\([0-9A-Fa-f-]{25,}\)' \
      | perl -ne 'if (/^(.*?)\s*\([0-9][^)]*\)\s*\(([0-9A-Fa-f-]{25,})\)\s*$/) { print "$1\t$2\n" }' \
      || true)
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
    # 兜底 1：CoreDevice（Xcode 15+）。沙箱内 xctrace 会报 `No devices available for the recording`
    #   （它依赖的 DVT 通道不可用），而 devicectl 走 CoreDeviceService，实测可用。
    #   ⚠️ 结构化输出优先：表格列宽/新增列都属于「不保证稳定」的呈现层，
    #      按 `(UDID)`/`physical` 正则啃表格会在 Xcode 升级后静默失配（⇒ 整条回退失效）。
    out=$(_devicectl_json_list || true)
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
    # 兜底 2：老版本 devicectl 不支持 `--json-output` 时退回表格解析。
    out=$(xcrun devicectl list devices 2>/dev/null \
      | perl -ne 'if (/^\s*(.+?)\s+([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]+)+)\s*\(UDID\).*\bphysical\b/) { print "$1\t$2\n" }' \
      || true)
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  fi
  # 最后兜底：libimobiledevice（只有 UDID，没有设备名）
  command -v idevice_id >/dev/null 2>&1 || return 1
  out=$(idevice_id -l 2>/dev/null | grep -E '^[0-9A-Fa-f-]{25,}$' | while read -r u; do
    n=$(ideviceinfo -u "$u" -k DeviceName 2>/dev/null || true)
    printf '%s\t%s\n' "${n:-iPhone}" "$u"
  done)
  [ -n "$out" ] || return 1   # 契约：无设备 ⇒ 返回 1（调用方按空输出判「未检测到」）
  printf '%s\n' "$out"
  return 0
}

# 首台 iOS 真机 UDID（保持 appium 侧既有语义：无设备 ⇒ 空输出 + rc=0，由调用方判空）
resolve_ios_device() {
  list_ios_devices 2>/dev/null | head -1 | awk -F'\t' '{print $2}' | grep -E '^[0-9A-Fa-f-]{25,}$' || true
}
