#!/bin/bash
# _env.sh — .debug.env 安全解析与字段校验（公共层；被 android/_common.sh、bg.sh 复用）
#
# 为什么不用 `source .debug.env`：
#   .debug.env 是**项目内文本**，`source` 等于**执行**它 ⇒ 任何能写该文件的一方，
#   都能在「bash <S>/scripts/*」这条放行通道内执行任意命令（脚本执行不经过 shell 权限求值）。
#   ⇒ 本文件改为：解析（不 eval / 不展开变量 / 不执行子 shell）+ 值分档校验。
#
# 行为约定：
#   - 行形态**宽容归一化**：`export ` 前缀 / 行尾 ` #` 注释 / CRLF / 末行缺换行 ⇒ 归一化后正常解析
#   - 未知键、未知形态 ⇒ **warn + 忽略**（不执行、不退出），保持向前兼容
#   - 值按档校验：标识符档严格正则；路径档禁控制字符 / 反引号 / `$(`
#   - **只对「已出现且非空」的键校验**；键缺失 ≠ 键非法（缺失由消费方给缺省）
#   - 违规 ⇒ 打印「键名 + 行号 + 原因」并 exit 1（调用方在 errexit 上下文 ⇒ 明确失败）
#
# 兼容：bash 3.2（macOS 自带）—— 禁 declare -A / 禁 nameref / 禁「管道喂 while read」（赋值须在当前作用域）
#
# 用法：
#   source <此文件>
#   parse_debug_env <文件>   # 解析（返回值 0；文件不存在返回 1）
#   validate_debug_env        # 值校验（违规即 exit 1）
#   export_debug_env          # 导出「本次实际解析到的键」（bg.sh 需要子进程继承）

# 解析上下文：ENV_LINES = "KEY:行号;" 列表；ENV_PRESENT = 本次实际赋值的键（空格分隔）
ENV_LINES=""
ENV_PRESENT=""

env_warn() { echo "⚠️  .debug.env: $*" >&2; }
env_fail() { echo "❌ .debug.env: $*" >&2; exit 1; }

# 消毒：截断 + 转义控制字符（防终端转义注入；S4/N3）
_env_sanitize() {
  local v="$1" out="" i ch
  v="${v:0:40}"
  for ((i=0; i<${#v}; i++)); do
    ch="${v:$i:1}"
    if [[ "$ch" < $' ' ]] || [[ "$ch" == $'\x7f' ]]; then
      printf -v ch '\\x%02x' "'$ch"
    fi
    out="${out}${ch}"
  done
  printf '%s' "$out"
}

# 去首尾空白（bash 3.2 兼容写法）
_env_trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# 取某键的行号（重复键取**末次**出现的行号，与赋值语义一致；S5）
env_line_of() {
  local key="$1" e oldifs="$IFS" last=""
  IFS=';'
  for e in $ENV_LINES; do
    case "$e" in
      "$key":*) last="${e#*:}" ;;
    esac
  done
  IFS="$oldifs"
  printf '%s' "$last"
}

# 解析 .debug.env → 在当前作用域赋值（不 eval / 不展开变量 / 不执行子 shell）
parse_debug_env() {
  local file="${1:-}" line key val lineno=0
  ENV_LINES=""
  ENV_PRESENT=""
  if [ -z "$file" ]; then
    env_warn "未指定文件路径"
    return 1
  fi
  if [ ! -f "$file" ]; then
    env_warn "文件不存在: $file"
    return 1
  fi

  # `|| [ -n "$line" ]` 兜底末行无换行的情况（否则会**静默丢最后一个键**）
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # 剥离 UTF-8 BOM（只在首行首字节；BOM 会使首键匹配失败 ⇒ 整行被丢）
    if [ "$lineno" -eq 1 ]; then
      line="${line#$'\xef\xbb\xbf'}"
    fi
    line="${line%$'\r'}"                                   # CRLF（逐行剥离，不管道）
    line="$(_env_trim "$line")"
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac                  # 注释行

    case "$line" in
      export[[:space:]]*) line="${line#export}"; line="$(_env_trim "$line")" ;;
    esac

    case "$line" in
      *=*) ;;
      *) env_warn "第 $lineno 行不是 KEY=VALUE 形式（已忽略）"; continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"

    case "$key" in
      *[!A-Z0-9_]*) env_warn "第 $lineno 行键名含非法字符（已忽略）"; continue ;;
      "") env_warn "第 $lineno 行键名为空（已忽略）"; continue ;;
    esac

    case "$val" in
      \"*)
        # 先找闭合引号（引号后的部分视为行尾注释并丢弃），再取引号内内容
        rest="${val#\"}"
        case "$rest" in
          *\"*) val="${rest%%\"*}" ;;
          *) env_warn "第 $lineno 行引号未闭合（已忽略）"; continue ;;
        esac
        val="$(_env_trim "$val")"
        ;;
      \'*)
        rest="${val#\'}"
        case "$rest" in
          *\'*) val="${rest%%\'*}" ;;
          *) env_warn "第 $lineno 行引号未闭合（已忽略）"; continue ;;
        esac
        val="$(_env_trim "$val")"
        ;;
      *)
        case "$val" in
          *" #"*) val="${val%% #*}" ;;                     # 行尾注释（仅空格+井号起）
        esac
        val="$(_env_trim "$val")"
        ;;
    esac

    case "$key" in
      ANDROID_APP_ID)     ANDROID_APP_ID="$val" ;;
      ANDROID_ACTIVITY)   ANDROID_ACTIVITY="$val" ;;
      ANDROID_FLAVOR)     ANDROID_FLAVOR="$val" ;;
      ANDROID_APK_PATH)   ANDROID_APK_PATH="$val" ;;
      IOS_BUNDLE_ID)      IOS_BUNDLE_ID="$val" ;;
      IOS_SCHEME)         IOS_SCHEME="$val" ;;
      IOS_APP_PATH)       IOS_APP_PATH="$val" ;;
      IOS_TEAM_ID)        IOS_TEAM_ID="$val" ;;
      IOS_DEVICE_APP)     IOS_DEVICE_APP="$val" ;;
      IOS_APP_NAME)       IOS_APP_NAME="$val" ;;       # App 进程名（syslog 行过滤；缺省从产物 CFBundleExecutable 推导）
      IOS_WDA_BUNDLE_ID)  IOS_WDA_BUNDLE_ID="$val" ;;  # 真机 WDA runner bundle id（须本团队可签名，如 <AppId>.wda）
      IOS_ATTACH_ONLY)    IOS_ATTACH_ONLY="$val" ;;     # 1=Appium 只 attach 已运行 App（禁 forceAppLaunch/noReset 重启）
      MACOS_APP_NAME)     MACOS_APP_NAME="$val" ;;
      MACOS_APP_BUNDLE)   MACOS_APP_BUNDLE="$val" ;;
      WINDOWS_APP_NAME)   WINDOWS_APP_NAME="$val" ;;
      WINDOWS_EXE_PATH)   WINDOWS_EXE_PATH="$val" ;;
      LOG_DIR)            LOG_DIR="$val" ;;
      BG_MAX_WAIT)        BG_MAX_WAIT="$val" ;;        # bg.sh 长任务等待上限（秒）
      VISION_LOG_LEVEL)   VISION_LOG_LEVEL="$val" ;;   # vision_read.py 日志级别
      VISION_API_KEY)     VISION_API_KEY="$val" ;;     # vision_read.py 百炼 API Key（可选；缺省回退 env var）
      *) env_warn "第 $lineno 行未知键（已忽略）: $key"; continue ;;
    esac
    ENV_LINES="$ENV_LINES$key:$lineno;"
    ENV_PRESENT="$ENV_PRESENT $key"
  done < "$file"

  return 0
}

# 值校验：只对已出现且非空的键执行
# ⚠️ 变量一律用 {} 包裹：bash 在 UTF-8 locale 下会把全角字符并入变量名
#    （形如 {key} 紧跟全角括号 会被解析成含括号的变量名 ⇒ set -u 下报 unbound variable）
_env_check_identifier() {   # <key> <value>
  local key="$1" val="$2"
  case "$val" in
    *[!A-Za-z0-9_.:/-]*)
      env_fail "键 ${key}（第 $(env_line_of "${key}") 行）的值含非法字符（只允许 字母/数字/_/./-/:）：$(_env_sanitize "$(_env_sanitize "${val}")")" ;;
  esac
}

_env_check_path() {         # <key> <value>
  local key="$1" val="$2"
  case "$val" in
    '~'*) env_fail "键 ${key}（第 $(env_line_of "${key}") 行）的值不能以 ~ 开头（~ 不展开，请写绝对或相对路径）" ;;
    -* ) env_fail "键 ${key}（第 $(env_line_of "${key}") 行）的值不能以 - 开头" ;;
    *'`'*) env_fail "键 ${key}（第 $(env_line_of "${key}") 行）的值含反引号（禁止）" ;;
    *'$('*) env_fail "键 ${key}（第 $(env_line_of "${key}") 行）的值含命令替换（禁止）" ;;
    *[[:cntrl:]]*) env_fail "键 ${key}（第 $(env_line_of "${key}") 行）的值含控制字符（禁止）" ;;
  esac
  # 值含 $ ：warn（不拒），与方案 §4.7/§6.2 承诺对齐（$ 在路径中不展开，但非常见）
  case "$val" in
    *'$'*) env_warn "键 ${key} 的值含 \$，不展开（如需变量请写绝对路径）" ;;
  esac
}

# LOG_DIR 附加校验：必须是项目内相对路径（脚本执行不判 external_directory ⇒ 必须自校验）
_env_check_log_dir() {
  local val="$1" rest comp oldifs="$IFS"
  case "$val" in
    /*) env_fail "键 LOG_DIR（第 $(env_line_of LOG_DIR) 行）必须是项目内相对路径（当前: $(_env_sanitize "$(_env_sanitize "${val}")")）" ;;
  esac
  rest="$val"
  IFS='/'
  for comp in $rest; do
    if [ "$comp" = ".." ]; then
      IFS="$oldifs"
      env_fail "键 LOG_DIR（第 $(env_line_of LOG_DIR) 行）不得含 .. 路径组件（当前: $(_env_sanitize "$(_env_sanitize "${val}")")）"
    fi
  done
  IFS="$oldifs"
}

validate_debug_env() {
  if [ -n "${ANDROID_APP_ID:-}" ]; then   _env_check_identifier ANDROID_APP_ID   "$ANDROID_APP_ID";   fi
  if [ -n "${ANDROID_ACTIVITY:-}" ]; then _env_check_identifier ANDROID_ACTIVITY "$ANDROID_ACTIVITY"; fi
  if [ -n "${ANDROID_FLAVOR:-}" ]; then   _env_check_identifier ANDROID_FLAVOR   "$ANDROID_FLAVOR";   fi
  if [ -n "${IOS_BUNDLE_ID:-}" ]; then    _env_check_identifier IOS_BUNDLE_ID    "$IOS_BUNDLE_ID";    fi
  if [ -n "${IOS_SCHEME:-}" ]; then       _env_check_identifier IOS_SCHEME       "$IOS_SCHEME";       fi
  if [ -n "${IOS_TEAM_ID:-}" ]; then      _env_check_identifier IOS_TEAM_ID      "$IOS_TEAM_ID";      fi
  if [ -n "${MACOS_APP_NAME:-}" ]; then   _env_check_path MACOS_APP_NAME   "$MACOS_APP_NAME";   fi  # I6: 允许空格产物名，走路径档
  if [ -n "${WINDOWS_APP_NAME:-}" ]; then _env_check_identifier WINDOWS_APP_NAME "$WINDOWS_APP_NAME"; fi
  if [ -n "${ANDROID_APK_PATH:-}" ]; then _env_check_path ANDROID_APK_PATH "$ANDROID_APK_PATH"; fi
  if [ -n "${IOS_APP_PATH:-}" ]; then     _env_check_path IOS_APP_PATH     "$IOS_APP_PATH";     fi
  if [ -n "${MACOS_APP_BUNDLE:-}" ]; then _env_check_path MACOS_APP_BUNDLE "$MACOS_APP_BUNDLE"; fi
  if [ -n "${IOS_DEVICE_APP:-}" ]; then   _env_check_path IOS_DEVICE_APP   "$IOS_DEVICE_APP";   fi
  if [ -n "${IOS_APP_NAME:-}" ]; then     _env_check_path IOS_APP_NAME     "$IOS_APP_NAME";     fi  # 可执行名可含空格，走路径档
  if [ -n "${IOS_WDA_BUNDLE_ID:-}" ]; then _env_check_identifier IOS_WDA_BUNDLE_ID "$IOS_WDA_BUNDLE_ID"; fi
  if [ -n "${IOS_ATTACH_ONLY:-}" ]; then
    case "$IOS_ATTACH_ONLY" in
      0|1) ;;
      *) env_fail "键 IOS_ATTACH_ONLY（第 $(env_line_of IOS_ATTACH_ONLY) 行）只能为 0 或 1（当前: $(_env_sanitize "${IOS_ATTACH_ONLY}")）" ;;
    esac
  fi
  if [ -n "${WINDOWS_EXE_PATH:-}" ]; then _env_check_path WINDOWS_EXE_PATH "$WINDOWS_EXE_PATH"; fi
  if [ -n "${LOG_DIR:-}" ]; then
    _env_check_path LOG_DIR "$LOG_DIR"
    _env_check_log_dir "$LOG_DIR"
  fi
  # 透传键（松校验）
  if [ -n "${BG_MAX_WAIT:-}" ]; then
    case "$BG_MAX_WAIT" in
      *[!0-9]*) env_fail "键 BG_MAX_WAIT（第 $(env_line_of BG_MAX_WAIT) 行）必须是正整数（当前: $(_env_sanitize "${BG_MAX_WAIT}")）" ;;
    esac
  fi
  if [ -n "${VISION_LOG_LEVEL:-}" ]; then
    case "$VISION_LOG_LEVEL" in
      *[!A-Za-z0-9]*) env_fail "键 VISION_LOG_LEVEL（第 $(env_line_of VISION_LOG_LEVEL) 行）只能含字母/数字（当前: $(_env_sanitize "${VISION_LOG_LEVEL}")）" ;;
    esac
  fi
  # VISION_API_KEY：密钥/令牌，允许字母/数字/下划线/连字符/点（常见 API Key 字符集）；禁止控制字符与 shell 元字符
  if [ -n "${VISION_API_KEY:-}" ]; then
    case "$VISION_API_KEY" in
      *[!A-Za-z0-9_.-]*) env_fail "键 VISION_API_KEY（第 $(env_line_of VISION_API_KEY) 行）含非法字符（只允许 字母/数字/_/./-）：$(_env_sanitize "${VISION_API_KEY}")" ;;
    esac
  fi
}

# 导出「本次实际解析到的键」（等价于原 `set -a; . file` 的导出效果，但不执行文件内容）
export_debug_env() {
  local k
  for k in $ENV_PRESENT; do
    export "$k"
  done
}
