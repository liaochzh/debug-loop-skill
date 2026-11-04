#!/usr/bin/env bash
# safe_run.sh — 在 macOS Seatbelt 沙箱内执行命令（debug-loop 的唯一 shell 入口）
#
# 用法：
#   safe_run.sh [--profile ui|build|ios|macos] [--net|--no-net]
#               [--project-root DIR] -- <cmd...>
#
# 设计要点：
#   · fail-closed：sandbox-exec 缺失 / profile 写失败 ⇒ 退出 117，**绝不执行原命令**；
#   · 写面白名单：只允许项目 build/、docs/test/、${TMPDIR}（adb 需要写日志与 socket）、/private/tmp；
#   · 凭证与凭据路径 deny 读+写；~/.config/opencode 写全拒、auth.json 读也拒（skill 脚本仍可读）；
#   · 网络默认关（仅放行 adb 5037 / appium 4723 的本机端口）；--profile build 默认开。
#   · `--project-root` 只接受白名单根（见 ALLOW_ROOTS），防止把家目录当项目根治逃逸。
#   · 执行前导出 SAFE_RUN_PROFILE（= profile 名）与 SAFE_RUN_NET（on/off），供被调脚本做能力降级判断。
#
# 退出码：0 命令成功 / 其余透传命令退出码 / 2 用法错 / 117 沙箱不可用（fail-closed）
#
# ⚠ 117 是**本脚本自用**的错误码，与命令自身的退出码区分开（命令 rc=4 会原样透传，
#   例如 `snapshot.sh` 的 rc=4 = 语义树为空，属正常观测，不能误判成沙箱故障）。

set -uo pipefail

PROFILE_KIND="ui"
NET_MODE="auto"
ROOT=""
CMD=()

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() { echo "safe_run: $1" >&2; exit 2; }
die_sandbox() { echo "safe_run: $1（fail-closed：未执行任何命令）" >&2; exit 117; }

# 取一个有值的选项；缺值或值以 `-` 开头（疑似误吞下一个选项/分隔符）一律用法错。
# 结果写全局 VAL（不用 `$(...)`：子 shell 里的 exit 不会退出主脚本，会漏掉 fail-closed）。
VAL=""
take_value() {   # $1=选项名  $2=候选值  $3=当前参数个数
  [ "$3" -ge 2 ] || die_usage "$1 需要参数值"
  case "$2" in
    '') die_usage "$1 的值不能为空" ;;
    -*) die_usage "$1 的值不能以 '-' 开头（当前：$2）" ;;
  esac
  VAL="$2"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)        take_value "$1" "${2:-}" $#; PROFILE_KIND="$VAL"; shift 2 ;;
    --net)            NET_MODE="on";  shift ;;
    --no-net)         NET_MODE="off"; shift ;;
    --project-root)   take_value "$1" "${2:-}" $#; ROOT="$VAL";         shift 2 ;;
    --)               shift; break ;;
    -h|--help)        usage; exit 0 ;;
    --*=*)            die_usage "不支持 '--opt=value' 形态，请用空格分隔（当前：$1）" ;;
    *)                break ;;
  esac
done
CMD=("$@")

if [ "${#CMD[@]}" -eq 0 ]; then
  echo "safe_run: 缺少命令（用法：safe_run.sh [--profile P] -- <cmd...>）" >&2
  exit 2
fi
case "$PROFILE_KIND" in
  ui|build|ios|macos) ;;
  *) die_usage "未知 profile '${PROFILE_KIND}'" ;;
esac

SBD="/usr/bin/sandbox-exec"
if [ ! -x "$SBD" ]; then
  die_sandbox "缺少 ${SBD}"
fi

HOME_DIR="${HOME:-/Users/$(id -un)}"
# adb 会在 ${TMPDIR} 根写 `adb.<uid>.log` 与 socket，故写面放行整个 ${TMPDIR}（仍限于本用户临时目录）。
# ⚠ 写面继承调用方环境里的 ${TMPDIR}：入口被白名单以 `bash <绝对路径> *` 前缀匹配，
#   `TMPDIR=… bash …` 形态不匹配 ⇒ 该变量不可被模型随手改写。
TMPROOT="${TMPDIR:-/tmp}"
TMPROOT="$(cd "$TMPROOT" 2>/dev/null && pwd -P || printf '%s' "$TMPROOT")"
TMPBASE="${TMPROOT}/opencode"
mkdir -p "$TMPBASE" 2>/dev/null || true

# ---- 项目根白名单：不允许把 $HOME / / 之类声明成「项目根」（否则 build profile 会放开整个家目录）
ALLOW_ROOTS=(
  "${HOME_DIR}/Projects"
  "/Volumes"
  "/private/tmp"
  "${TMPROOT}"
)
# in_allow_roots <dir> ⇒ 0/1
in_allow_roots() {
  local real="$1" base
  for base in "${ALLOW_ROOTS[@]}"; do
    case "${real}/" in
      "${base%/}/"*) return 0 ;;
    esac
  done
  return 1
}

EXPLICIT_ROOT=1
if [ -z "$ROOT" ]; then
  EXPLICIT_ROOT=0
  ROOT="$PWD"
fi
ROOT_REAL="$(cd "$ROOT" 2>/dev/null && pwd -P)"
if [ -z "$ROOT_REAL" ] || [ ! -d "$ROOT_REAL" ]; then
  die_usage "项目根不存在或不是目录：${ROOT}"
fi
_deny_root=0
case "${ROOT_REAL%/}" in
  "/"|"${HOME_DIR}") _deny_root=1 ;;
esac
if [ "$_deny_root" -eq 1 ] && [ "$EXPLICIT_ROOT" -eq 1 ]; then
  die_usage "拒绝把 '${ROOT_REAL}' 当作项目根（请给真正的项目目录）"
fi
# 显式指定的根不得**等于**白名单条目本体（`--project-root ~/Projects` 会让 build profile 放开整个项目区）
if [ "$EXPLICIT_ROOT" -eq 1 ]; then
  for _base in "${ALLOW_ROOTS[@]}"; do
    if [ "${ROOT_REAL%/}" = "${_base%/}" ]; then _deny_root=1; break; fi
  done
fi
if [ "$_deny_root" -eq 1 ] || ! in_allow_roots "$ROOT_REAL"; then
  if [ "$EXPLICIT_ROOT" -eq 1 ]; then
    echo "safe_run: 项目根 '${ROOT_REAL}' 不在允许清单内。" >&2
    echo "           允许的根：$(printf '%s、' "${ALLOW_ROOTS[@]}" | sed 's/、$//')" >&2
    echo "           需要新根请改本脚本的 ALLOW_ROOTS（不要用 \$HOME 本体）。" >&2
    exit 2
  fi
  # 未显式指定且 cwd 不在允许清单（如从 $HOME 启动）⇒ 写面**收窄到临时目录**，不擅自放开 cwd。
  echo "safe_run: 当前目录 '${ROOT_REAL}' 不在允许清单内 ⇒ 写面收窄到 ${TMPBASE}；" >&2
  echo "           需要项目内落盘请显式传 --project-root <项目根>。" >&2
  ROOT_REAL="$TMPBASE"
fi
ROOT="$ROOT_REAL"

if [ "$NET_MODE" = "auto" ]; then
  case "$PROFILE_KIND" in
    build) NET_MODE="on" ;;
    *)     NET_MODE="off" ;;
  esac
fi

PROF="$(mktemp "${TMPBASE}/safe_run.XXXXXX" 2>/dev/null)"
if [ -z "$PROF" ] || [ ! -f "$PROF" ]; then
  die_sandbox "无法创建 profile 临时文件"
fi
chmod 600 "$PROF" 2>/dev/null || true
cleanup() { rm -f "$PROF" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# SBPL 字符串转义：反斜杠与双引号
q() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# 解析软链链到真实路径（BSD `readlink` 没有 `-f`，只能自己跟）：
#   · 入参必须是**绝对路径**（PATH 含 `.`/空项时会命中相对名 ⇒ 直接失败，不猜 CWD）
#   · 每跳把「相对目标」拼到源链接所在目录，并立刻 `cd`+`pwd -P` 归一化
#     （同时消掉 `..` 与父级目录软链重定向）
#   · 上限 10 跳：成环 / 过深软链一律失败（fail-closed）
# 输出：真实路径（stdout）；失败：无输出，return 1
resolve_symlink_chain() {
  local p="${1:-}" t="" i=0
  case "$p" in /*) ;; *) return 1 ;; esac
  while [ -L "$p" ]; do
    i=$((i+1))
    [ "$i" -le 10 ] || return 1
    t="$(readlink "$p" 2>/dev/null)" || return 1
    [ -n "$t" ] || return 1
    case "$t" in
      /*) p="$t" ;;
      *)  p="$(dirname "$p")/$t" ;;
    esac
    # 归一化；父目录不存在 ⇒ 失败（不把不存在的路径当 SDK 根）
    t="$(cd "$(dirname "$p")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$p")")" || return 1
    [ -n "$t" ] || return 1
    p="$t"
  done
  printf '%s' "$p"
}

ROOT_Q="$(q "$ROOT")"
TMPROOT_Q="$(q "$TMPROOT")"
HOME_Q="$(q "$HOME_DIR")"

{
  echo '(version 1)'
  echo '(deny default)'
  echo '(allow file-read*)'
  echo '(allow process-exec)'
  echo '(allow process-fork)'
  echo '(allow signal (target self))'
  # 仅允许给**同一沙箱内**的进程发信号（不扩展到宿主机上其它进程）⇒ 脚本内超时/清理子进程可用。
  echo '(allow signal (target same-sandbox))'
  echo '(allow sysctl-read)'
  echo '(allow user-preference-read)'
  echo '(allow file-write-data (literal "/dev/null"))'
  # libimobiledevice 全家族（idevice_id / ideviceinfo / idevicesyslog / ideviceinstaller）都经
  #   usbmuxd 的**本机 unix socket** 通信；不放行时报 `Unable to retrieve device list!`
  #   （实测取证：deny network-outbound /private/var/run/usbmuxd）。只开这一条 socket，不开网络。
  echo '(allow network-outbound (literal "/private/var/run/usbmuxd"))'
  echo "(allow file-write* (subpath \"${ROOT_Q}/build\") (subpath \"${ROOT_Q}/docs/test\") (subpath \"${TMPROOT_Q}\") (subpath \"/private/tmp\"))"

  # 工具缓存（**所有 profile** 都要）：maestro 首次运行会把 applesimutils 等依赖解包到
  #   ~/.maestro/deps 并 chmod ⇒ 不放行则 `maestro hierarchy` 直接抛
  #   `setPosixFilePermissions ... Operation not permitted`；日志锁在 ~/Library/Logs/maestro。
  echo "(allow file-write* (subpath \"${HOME_Q}/.maestro\") (subpath \"${HOME_Q}/.appium\") (subpath \"${HOME_Q}/Library/Logs/maestro\"))"

  if [ "$PROFILE_KIND" = "build" ]; then
    echo "(allow file-write* (subpath \"${ROOT_Q}\") (subpath \"${HOME_Q}/.pub-cache\") (subpath \"${HOME_Q}/.gradle\") (subpath \"${HOME_Q}/Library/Caches\") (subpath \"${HOME_Q}/Library/Developer\"))"
    # Flutter SDK 缓存（SDK 常装在项目白名单之外，如 /Volumes/<盘>/dev/flutter）：
    #   `flutter` 会在 `<SDK>/bin/cache` 写 engine.stamp / 解包 artifacts，不放行每条命令都
    #   `Operation not permitted`（实测 update_engine_version.sh:71 engine.stamp.tmp）。
    #   ⚠️ 该路径来自 PATH，属于**外部可控输入** ⇒ 逐条校验、任一不过就 fail-closed 不放行：
    #     · `command -v` 结果必须是**绝对路径**（PATH 含 `.`/空项时会命中 CWD 的相对名）
    #     · 结果可能是**软链**（brew cask：`/opt/homebrew/bin/flutter` → `Caskroom/<ver>/flutter/bin/flutter`）
    #       ⇒ 必须先 `resolve_symlink_chain` 解析，否则推导出的根是链接所在目录，`bin/cache` 不存在
    #     · 必须是存在的普通可执行文件
    #     · `<root>/bin/cache` 必须是**真实路径**：`cd` 进入后 `pwd -P` 与字面路径相等
    #       （同时覆盖「cache 本身是链接」和「bin 是链接」两种父级重定向）
    #     · 不得等于 ALLOW_ROOTS 本体、不得落在 `$HOME` 的隐藏目录子树内
    #   ⚠️ 拒绝必须**可观测**：PATH 里没有 flutter 时静默（与放行无关），
    #      有 flutter 但解析/校验不过时一律 stderr 说明原因（否则表现为「已放行」却仍 EPERM）。
    _fb_raw="$(command -v flutter 2>/dev/null || true)"
    _fb=""; _fr=""; _fr_reject=""
    if [ -z "$_fb_raw" ]; then
      : # PATH 里没有 flutter ⇒ 不涉及放行，静默
    else
      case "$_fb_raw" in
        /*) ;;
        *)  _fr_reject="flutter 解析为相对路径（PATH 含 '.' 或空项）：${_fb_raw}" ;;
      esac
      if [ -z "$_fr_reject" ]; then
        if ! _fb="$(resolve_symlink_chain "$_fb_raw")" || [ -z "$_fb" ]; then
          _fb=""
          _fr_reject="flutter 软链解析失败（断链，或成环/超过 10 跳）"
        elif [ ! -f "$_fb" ] || [ ! -x "$_fb" ]; then
          _fr_reject="flutter 软链解析失败（解析结果不是可执行文件：${_fb}）"
          _fb=""
        fi
      fi
      if [ -n "$_fb" ]; then
        _fr="$(cd "$(dirname "$_fb")/.." 2>/dev/null && pwd -P || true)"
        case "$_fr" in ""|/) _fr=""; _fr_reject="推导不出 SDK 根" ;; esac
        [ "$_fr" = "$HOME_DIR" ] && { _fr=""; _fr_reject="SDK 根就是 \$HOME"; }
        # `*` 在 case 里跨 `/` ⇒ 这里实际拒的是「$HOME 下任一隐藏目录及其整棵子树」
        case "$_fr" in "$HOME_DIR"/.*) _fr=""; _fr_reject="SDK 根在 \$HOME 的隐藏目录内" ;; esac
        if [ -n "$_fr" ]; then
          _fc="$(cd "$_fr/bin/cache" 2>/dev/null && pwd -P || true)"
          if [ -z "$_fc" ] || [ "$_fc" != "$_fr/bin/cache" ]; then
            _fr=""; _fr_reject="<SDK>/bin/cache 不是真实目录（可能经符号链接重定向）"
          fi
        fi
        if [ -n "$_fr" ]; then
          for _base in "${ALLOW_ROOTS[@]}"; do
            if [ "$_fr" = "$_base" ]; then _fr=""; _fr_reject="SDK 根等于白名单根本体"; fi
          done
        fi
      fi
      if [ -n "$_fr" ]; then
        echo "(allow file-write* (subpath \"$(q "$_fr/bin/cache")\"))"
      elif [ -n "$_fr_reject" ]; then
        echo "safe_run: 未放行 Flutter SDK 缓存（${_fr_reject}）⇒ flutter 写 cache 会 EPERM" >&2
      fi
    fi
    # flutter/dart 工具自身状态目录：telemetry session 会 `setLastModified`
    #   ⇒ 不放行时构建以 `Failed to set file modification time ... .dart-tool/...` 崩掉（rc=255）。
    echo "(allow file-write* (subpath \"${HOME_Q}/.dart-tool\"))"
    # 拉依赖走 HTTPS：证书链校验要问 trustd（Security.framework）。缺这两条时
    #   `flutter pub get` 报 `CERTIFICATE_VERIFY_FAILED: application verification failure`。
    #   ⚠️ trustd 是沙箱外的证书校验代理（本身会外联 OCSP/CRL）⇒ **不要**把这两条复制到
    #      `--no-net` 的 profile：那等于给禁网 profile 开一个间接外联通道。
    echo '(allow mach-lookup (global-name "com.apple.trustd") (global-name "com.apple.trustd.agent"))'
  fi

  # ---- 敏感面：deny 必须写在 allow 之后（Seatbelt = last-match-wins）
  # 凭证/凭据：读+写都拒（调试链路不需要）
  # opencode 自身状态：写全拒；auth.json / 会话数据读也拒（防 API key 与其它会话内容外泄）
  echo "(deny file-write* (subpath \"${HOME_Q}/.config/opencode\") (subpath \"${HOME_Q}/.local/share/opencode\"))"
  # 持久化点：即使 `--project-root` 指到某个宽目录，也不许改登录脚本 / 开机项
  echo "(deny file-write* (subpath \"${HOME_Q}/Library/LaunchAgents\") (subpath \"${HOME_Q}/Library/LaunchDaemons\") (literal \"${HOME_Q}/.zshrc\") (literal \"${HOME_Q}/.zprofile\") (literal \"${HOME_Q}/.bashrc\") (literal \"${HOME_Q}/.bash_profile\") (literal \"${HOME_Q}/.profile\"))"
  # `.env` 家族：shell 面也不许 cat（config 层的 read deny 只管 read 工具）。
  #   `.debug.env` 是调试常量、无密钥 ⇒ 最后单独放回（顺序 = 覆盖前面两条 deny）。
  echo "(deny file-read* (regex #\"^.*\\.[Ee][Nn][Vv]$\") (regex #\"^.*\\.[Ee][Nn][Vv]\\.[^/]+$\"))"
  echo "(allow file-read* (regex #\"^.*\\.debug\\.env$\"))"
  echo "(deny file-read* (subpath \"${HOME_Q}/.local/share/opencode\") (literal \"${HOME_Q}/.config/opencode/auth.json\"))"
  # ⚠ 凭证面放在**最后**：上面的 `.debug.env` 通配 allow 会覆盖一切前置 deny，
  #   故凭证 deny 必须后置，确保 `~/.ssh/x.debug.env` 之类同样被拒。
  echo "(deny file-read* file-write* (subpath \"${HOME_Q}/.ssh\") (subpath \"${HOME_Q}/.aws\") (subpath \"${HOME_Q}/.gnupg\") (literal \"${HOME_Q}/.netrc\") (subpath \"${HOME_Q}/Library/Keychains\"))"

  if [ "$NET_MODE" = "on" ]; then
    echo '(allow network*)'
  else
    # 禁网；只放行**设备通信**的三类精确目标：
    #   · `localhost:5037` adb server、`localhost:4723` appium；
    #   · `*:22087` maestro 的 iOS/Android 驱动端口（实测固定；主机名在沙箱内解析不出，故用 `*`）。
    # ⚠ 不可用 `localhost:*` 通配：本机代理（如 7897）会被一并放行 ⇒ curl 经代理即可出网（实测 200）。
    # ⚠ 也不可用「先 allow 通配再 deny 具体端口」：本机 macOS 的 SBPL 对带端口的 deny 匹配不生效（实测）。
    echo '(deny network*)'
    echo '(allow network-outbound (remote ip "localhost:5037"))'
    echo '(allow network-outbound (remote ip "localhost:4723"))'
    echo '(allow network-outbound (remote ip "*:22087"))'
    # adb server 需要在 5037 上 listen（沙箱内起的 daemon）。
    # ⚠ 实测（log stream 取证）：listen 由 `network-inbound` 授权（`network-bind` 单独给不够）；
    #   且 adb 还会 `bind(local, port 0)` 取临时端口 ⇒ 需放行 `network-bind` 的 `*:*`。
    #   两者都只作用于**本机**（可占本机端口，但**不能出网**），不构成外泄面。
    echo '(allow network-bind (local ip "*:*"))'
    # maestro 会自己起一个本机 HTTP 端口供驱动回连（端口随机）⇒ inbound 需放开本机通配。
    echo '(allow network-inbound (local ip "localhost:*"))'
  fi

  # 调试工具的通用 mach 查询（实测 deny 会刷日志/降级，个别会**挂死**）：
  #   · `SystemConfiguration.configd`：JVM 启动时 `CreateExecutionEnvironment` 会进 CFRunLoop 取代理配置，
  #     不给则 `maestro` 起来就卡在 mach_msg（实测 90 s 无输出）——不是慢，是等一个永远不来的回包。
  echo '(allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo") (global-name "com.apple.system.logger"))'
  echo '(allow mach-lookup (global-name "com.apple.SystemConfiguration.configd") (global-name "com.apple.system.opendirectoryd.membership"))'
  # 磁盘余量查询（`system-info vfs.disk-space`）：当前 macOS 的 SBPL 不接受该过滤器写法
  #   （`unbound variable`）⇒ 只能让它走 deny（仅影响可用空间上报，不影响功能）。

  case "$PROFILE_KIND" in
    ios)
      # 实测（log stream 取证）：缺这些 ⇒ `simctl list` 把全部 runtime 判成
      #   「unavailable, runtime profile not found」——simdiskimaged 是 runtime 挂载卷的定位者。
      # maestro 的 iOS 驱动是 `xcodebuild test-without-building` 起的 XCTest runner
      #   ⇒ 必须能写 DerivedData 与 Xcode 缓存，否则驱动**起不来**，JVM 会无限轮询 127.0.0.1:22087
      #   （表现为「无输出挂死」，不是连接被拒那么直白）。
      echo "(allow file-write* (subpath \"${HOME_Q}/Library/Developer\") (subpath \"${HOME_Q}/Library/Caches/com.apple.dt.Xcode\"))"
      echo '(allow mach-lookup (global-name "com.apple.CoreSimulator.simdiskimaged"))'
      echo '(allow mach-lookup (global-name "com.apple.CoreSimulator.SimLaunchHost-arm64"))'
      echo '(allow mach-lookup (global-name "com.apple.DiskArbitration.diskarbitrationd"))'
      echo '(allow mach-lookup (global-name "com.apple.CoreSimulator.CoreSimulatorService"))'
      # XCTest runner（maestro 驱动）需要：simctl 通道 + XCTest 的 mach 服务
      echo '(allow mach-lookup (global-name "com.apple.CoreSimulator.simctl") (global-name "com.apple.dt.XCTest"))'
      # iOS **真机**链路（devicectl / CoreDevice）：缺 CoreDeviceService ⇒
      #   `devicectl list devices` 报 "Timed out waiting for CoreDeviceService to fully initialize"。
      echo '(allow mach-lookup (global-name "com.apple.CoreDevice.CoreDeviceService") (global-name "com.apple.CoreServices.coreservicesd"))'
      echo '(allow mach-lookup (global-name "com.apple.cfprefsd.agent"))'
      echo '(allow mach-lookup (global-name "com.apple.system.logger"))'
      echo '(allow mach-lookup (global-name "com.apple.lsd.mapdb"))'
      echo '(allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo"))'
      ;;
    macos)
      echo '(allow mach-lookup (global-name "com.apple.windowserver.active"))'
      echo '(allow mach-lookup (global-name "com.apple.tccd"))'
      # 实测（log stream 取证）：screencapture 需要下列显示/通知/服务发现通道；
      #   缺它们只会在「已获屏幕录制授权」的环境里表现为 `could not create image from display`。
      echo '(allow mach-lookup (global-name "com.apple.CARenderServer"))'
      echo '(allow mach-lookup (global-name "com.apple.dock.server"))'
      echo '(allow mach-lookup (global-name "com.apple.distributed_notifications@Uv3"))'
      echo '(allow mach-lookup (global-name "com.apple.coreservices.launchservicesd"))'
      echo '(allow mach-lookup (global-name "com.apple.CoreServices.coreservicesd"))'
      echo '(allow mach-lookup (global-name "com.apple.tccd.system"))'
      echo '(allow mach-lookup (global-name "com.apple.replayd"))'
      echo '(allow mach-lookup (global-name "com.apple.cfprefsd.agent"))'
      echo '(allow mach-lookup (global-name "com.apple.system.logger"))'
      echo '(allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo"))'
      ;;
  esac
} > "$PROF"

if [ ! -s "$PROF" ]; then
  die_sandbox "profile 生成失败"
fi

# 排障用：SAFE_RUN_DUMP_PROFILE=<path> 时把本次 profile 复制到该路径（不改变执行）。
if [ -n "${SAFE_RUN_DUMP_PROFILE:-}" ]; then
  cp "$PROF" "$SAFE_RUN_DUMP_PROFILE" 2>/dev/null || true
fi

# 告诉被执行的脚本「自己在沙箱里、用的是哪个 profile」⇒ 脚本可据此对有已知限制的能力快失败降级
#   （如 snapshot.sh 在沙箱内对 iOS 模拟器 maestro 有界等待，超时不重试）。
#   ⚠ 不新增权限面：该变量只影响脚本的**降级判断**，不改变 profile 内容。
SAFE_RUN_PROFILE="$PROFILE_KIND"
SAFE_RUN_NET="$NET_MODE"
export SAFE_RUN_PROFILE SAFE_RUN_NET

"$SBD" -f "$PROF" -- "${CMD[@]}"
exit $?
