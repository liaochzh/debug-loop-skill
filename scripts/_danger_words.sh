#!/bin/bash
# _danger_words.sh — 危险词表单一来源（被 tap_verify.sh 与 flow_save.sh source）
#
# 为什么拆出来（2026-11-17 立项，r2 复审条目 13）：
#   点击回执与流程固化都要判「这是不是危险操作」，两边各抄一份必然漂移；
#   但**两个场景的词表语义不同**，不能合并成一张表：
#     · 基线表（DANGER_WORDS_BASE）：tap_verify 的**点击目标**名匹配（中文按钮/标签），
#       内容与 tap_verify.sh 原有字面量**逐字一致** —— 抽表是行为保持重构，不加词。
#     · 命令扩展表（DANGER_WORDS_CMD）：flow_save 的**步骤命令串**匹配
#       （clean / uninstall / pm clear 等破坏项目状态或设备状态的动作），
#       只对流程步骤生效，**不进 tap_verify**（避免给点击门禁引入英文 clear 误伤）。
#
# 匹配口径（两张表一致）：普通子串包含，ASCII 转小写后比较；`pm clear` 这类带空格的
#   词按整串包含匹配（调用方传整条命令串即可）。
#
# 用法：
#   source <此文件>
#   is_danger_base "<点击关键词或节点文本>"   # 0=命中基线词
#   is_danger_cmd  "<完整步骤命令串>"         # 0=命中命令扩展词

# 基线表：旧 tap_verify.sh 第 93 行字面量，**逐字保留**（含前导空格）。
#   ⚠️ 改这里等于改 tap_verify 的点击门禁行为 —— 需要 test_interact.sh 回归。
DANGER_WORDS_BASE=" 删除 移除 解绑 注销 退出 支付 付款 提交 下单 购买 卸载 清空 重置 确认 确定 发送 绑定 开通 转账 退款 挂失 delete remove logout unbind pay submit confirm send"

# 命令扩展表：只用于 flow_save 的步骤命令串（小写包含匹配）。
#   clean / uninstall 会把构建产物或设备上的 App 状态清掉；pm clear 清 App 数据；
#   gradlew clean / flutter clean 同上（clean 已覆盖）。保留英文与中文两种写法。
DANGER_WORDS_CMD="clean uninstall 清除 卸载 pm clear adb shell pm clear"

_danger_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# 基线匹配：与 tap_verify.sh 原 is_danger 同语义（原串直接包含 + 小写包含两条都判）
is_danger_base() {
  local t lower w
  t=" $(printf '%s' "$1" | tr '\n' ' ') "
  lower="$(_danger_lower "$1")"
  for w in $DANGER_WORDS_BASE; do
    case "$t" in *"$w"*) return 0 ;; esac
    case " $lower " in *"$w"*) return 0 ;; esac
  done
  return 1
}

# 命令串匹配：只判命令扩展词（不判基线词 —— 基线词是点击目标名，命令串里出现
#   "confirm" 之类不代表危险动作，交给 tap_verify 在点击时判）。
is_danger_cmd() {
  local lower w
  lower="$(_danger_lower "$1")"
  for w in $DANGER_WORDS_CMD; do
    case " $lower " in *"$w"*) return 0 ;; esac
  done
  return 1
}
