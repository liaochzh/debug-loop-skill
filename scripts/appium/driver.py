#!/usr/bin/env python3
# driver.py — 极简 Appium W3C WebDriver 客户端（基于 requests，无额外依赖）
#
# 用法:
#   driver.py source      --server <url> --caps <caps.json>
#   driver.py find-click  --server <url> --caps <caps.json> [--using "accessibility id"] [--value "登录"]
#   driver.py find-assert --server <url> --caps <caps.json> [--using ...] [--value ...]
#   driver.py find-type   --server <url> --caps <caps.json> [--using ...] [--value ...]
#                         (--text "要输入的文字" | --text-from <KEY=VALUE 文件|->  [--key NAME])
#                         [--clear|--no-clear] [--mask] [--expect "<期望读回值>"]
#                         ⚠️ 默认先清空再输入，输入后读回校验（不符 rc=1）；敏感值用 --text-from
#                         --expect：输入后额外断言 attribute/value 等于该值（输入会被平台转换时用），
#                         掩码字段只比长度；不符 rc=1
#   driver.py screenshot  --server <url> --caps <caps.json> --out <path.png>
#   driver.py flow        --server <url> --caps <caps.json> --steps <steps.json>
#
# flow 的 steps.json 为步骤数组，每步 {"type": ...}：
#   {"type":"tap","using":"...","value":"..."}            点击元素
#   {"type":"type","using":"...","value":"...","text":"…","click":true}
#                                                         点焦点+（默认清空）+输入+读回校验
#                                                         "clear":false 追加；"mask":true 只比长度
#   {"type":"assert","using":"...","value":"..."}         断言元素存在
#   {"type":"exec","script":"mobile: setPasteboard","args":{...}}  执行 W3C 脚本/Appium mobile 命令
#   {"type":"shot","out":"<path.png>"}                    截图
#   {"type":"source"}                                     打印 page source
#   {"type":"wait","seconds":3}                           休眠
# 单会话执行全部步骤（iOS 真机每次新建会话会重启 App，多步场景必须走 flow）
#
# 退出码: 0 成功 / 1 元素未找到或步骤失败 / 2 用法错误 / 3 会话或驱动错误
import argparse
import base64
import json
import os
import sys
import threading
import time
import warnings

warnings.filterwarnings("ignore")

import requests

# 输入框「清空/读回校验」判据与 android/input.sh 共用一份（scripts/_field_target.py），
# 两处各写一份必然漂移（历史教训：settle.sh 的 PREV 自比 ⇒ 假「已静止」）。
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import _field_target as field  # noqa: E402

W3C_ELEMENT_KEY = "element-6066-11e4-a52e-4f735466cecf"
JSONWP_ELEMENT_KEY = "ELEMENT"


def _post(url, payload, timeout=120):
    return requests.post(url, json=payload, timeout=timeout)


def start_session(server, caps):
    resp = _post(server.rstrip("/") + "/session", {"capabilities": {"alwaysMatch": caps}})
    if resp.status_code >= 400:
        raise RuntimeError(f"创建会话失败 {resp.status_code}: {resp.text[:500]}")
    value = resp.json().get("value", {})
    sid = value.get("sessionId") or resp.json().get("sessionId")
    if not sid:
        raise RuntimeError(f"响应缺少 sessionId: {resp.text[:300]}")
    return sid


def end_session(server, sid):
    try:
        requests.delete(server.rstrip("/") + f"/session/{sid}", timeout=30)
    except Exception as e:  # noqa: BLE001
        print(f"⚠️ 结束会话失败（忽略）: {e}", file=sys.stderr)


def _error_text(resp):
    """从 W3C 错误响应中提取 error/message，失败时回退原始文本。"""
    try:
        val = resp.json().get("value", {})
        if isinstance(val, dict):
            return val.get("error") or val.get("message") or resp.text[:500]
        return str(val)
    except Exception:  # noqa: BLE001
        return resp.text[:500]


# 元素等待默认秒数：App 冷启动/首帧/页面动画期间元素会短暂缺失，固定 sleep 不可靠
ELEMENT_WAIT = 10.0


def find_element(server, sid, using, value, timeout=None):
    deadline = time.time() + (ELEMENT_WAIT if timeout is None else timeout)
    while True:
        resp = _post(server.rstrip("/") + f"/session/{sid}/element", {"using": using, "value": value})
        if resp.status_code < 400:
            break
        err = _error_text(resp)
        # 404 可能是 "no such element"（等一会再试）或 "invalid session id"（需报错）
        if "no such element" not in err.lower():
            raise RuntimeError(f"查找元素失败 {resp.status_code}: {err}")
        if time.time() >= deadline:
            return None
        time.sleep(1)
    val = resp.json().get("value", {})
    eid = val.get(W3C_ELEMENT_KEY) or val.get(JSONWP_ELEMENT_KEY)
    return eid


def click_element(server, sid, eid):
    resp = _post(server.rstrip("/") + f"/session/{sid}/element/{eid}/click", {})
    if resp.status_code >= 400:
        raise RuntimeError(f"点击失败 {resp.status_code}: {resp.text[:500]}")
    return True


def pointer_actions(server, sid, ticks, timeout=120):
    payload = {"actions": [{
        "type": "pointer", "id": "finger1",
        "parameters": {"pointerType": "touch"},
        "actions": ticks,
    }]}
    resp = _post(server.rstrip("/") + f"/session/{sid}/actions", payload, timeout=timeout)
    if resp.status_code >= 400:
        raise RuntimeError(f"指针动作失败 {resp.status_code}: {_error_text(resp)}")
    return True


def perform_pointer(server, sid, x, y, hold=0.0):
    """单指坐标操作：移到 (x,y) → 按下 → 停顿 hold 秒 → 抬起（一次调用内完成）。"""
    ticks = [
        {"type": "pointerMove", "duration": 0, "x": int(x), "y": int(y), "origin": "viewport"},
        {"type": "pointerDown", "button": 0},
    ]
    if hold > 0:
        ticks.append({"type": "pause", "duration": int(hold * 1000)})
    ticks.append({"type": "pointerUp", "button": 0})
    return pointer_actions(server, sid, ticks, timeout=int(hold) + 60)


def hold_and_background(server, sid, x, y, hold=4.0, at=1.5, seconds=3.0):
    """按住指定坐标，并在按住期间把 App 退到后台（复现「按住对讲 → 立即退后台」竞态）。

    为什么必须原子化：W3C actions 的指针状态**不跨调用保持**（实测单独发 pointerUp
    会 500），所以「先 down 再另发 background」这条路走不通；改为单次 actions 按住
    hold 秒，同时在另一线程 at 秒时下发 backgroundApp。若 driver 把两条命令串行化，
    本函数退化为「松手后立刻退后台」——仍覆盖 forceStop 与排空窗口重叠的时序。
    """
    err = {}

    def _bg():
        try:
            time.sleep(at)
            background_app(server, sid, seconds)
        except Exception as e:  # noqa: BLE001
            err["e"] = e

    t = threading.Thread(target=_bg, daemon=True)
    t.start()
    perform_pointer(server, sid, x, y, hold=hold)
    t.join(timeout=hold + float(seconds) + 15)
    if "e" in err:
        raise RuntimeError(f"按住期间退后台失败: {err['e']}")
    return True


def background_app(server, sid, seconds=3):
    """退后台 N 秒（mobile: backgroundApp）。

    ⚠️ 不用 `mobile: pressButton home`：在 iOS 真机 + 新版 XCUITest driver 上下发成功但空操作
    （实测截图仍在 App 内），会静默把「退后台回归」跑成假通过。
    ⚠️ 也不要用 devicectl/launchApp 冷启动 debug 包：会命中 iOS 14+ 限制页。
    """
    return execute_sync(server, sid, "mobile: backgroundApp", {"seconds": int(seconds)})


def activate_app(server, sid, bundle_id):
    """把已在后台的 App 唤回前台（不冷启动 ⇒ 不触发 debug 限制页）。"""
    return execute_sync(server, sid, "mobile: activateApp", {"bundleId": bundle_id})


def press_button(server, sid, name="home"):
    """按硬件键（mobile: pressButton）。

    ⚠️ 实测 iOS 真机 + 新版 XCUITest driver 上 `home` 会**返回成功但空操作**
    （截图仍在 App 内）⇒ 退后台请用 background_app，不要用本函数。
    """
    return execute_sync(server, sid, "mobile: pressButton", {"name": name})


def get_source(server, sid):
    resp = requests.get(server.rstrip("/") + f"/session/{sid}/source", timeout=120)
    if resp.status_code >= 400:
        raise RuntimeError(f"获取 page source 失败 {resp.status_code}: {resp.text[:300]}")
    return resp.json().get("value", "")


def send_text(server, sid, eid, text):
    """向元素发送文本（W3C element/value；XCUITest 走键盘，Flutter 输入框可接收）。"""
    payload = {"text": text, "value": list(text)}
    resp = _post(server.rstrip("/") + f"/session/{sid}/element/{eid}/value", payload)
    if resp.status_code >= 400:
        raise RuntimeError(f"输入文本失败 {resp.status_code}: {_error_text(resp)}")
    return True


def get_element_value(server, sid, eid):
    """读元素当前值（密码框可能返回空串或掩码，调用方按长度比对）。失败返回 None。"""
    base = server.rstrip("/") + f"/session/{sid}/element/{eid}"
    for suffix in ("/attribute/value", "/text"):
        try:
            resp = requests.get(base + suffix, timeout=30)
        except requests.exceptions.RequestException:
            continue
        if resp.status_code < 400:
            val = resp.json().get("value")
            if isinstance(val, str):
                return val
    return None


def clear_element(server, sid, eid, mask=False):
    """清空元素内容：优先 W3C element/clear；不可用时按当前值长度发退格键。

    为什么不是「直接 send_text」：element/value 是**追加**语义（XCUITest typeText），
    旧内容不清空 ⇒ 账号变成「alicealice」这类错值（2026-11-12 立项的真实故障形态）。

    mask=True 时套用 plan_clear 的空值保底（密码框语义值常为空 ⇒ 否则一次都不删）。
    """
    base = server.rstrip("/") + f"/session/{sid}/element/{eid}"
    try:
        resp = _post(base + "/clear", {})
        if resp.status_code < 400:
            return True
    except requests.exceptions.RequestException:
        pass
    current = get_element_value(server, sid, eid) or ""
    dels, _ = field.plan_clear(current, mask)
    if dels > 0:
        send_text(server, sid, eid, "\ue003" * dels)   # \ue003 = W3C BACKSPACE
    return True


def type_into(server, sid, eid, text, clear=True, mask=False, retries=0):
    """（清空）→ 输入 → 读回比对；不符则重来。返回 (ok, actual)。

    clear=False 是「追加」语义（兼容旧行为）：此时读回是「旧值+新值」，必须只判后缀，
    否则必然假失败并再追加一遍（2026-11-12 复审 P0#2），且**不允许重试**（会变「旧+text+text」）。
    """
    actual = None
    append = not clear
    if append:
        retries = 0
    for attempt in range(retries + 1):
        if clear:
            clear_element(server, sid, eid, mask)
        send_text(server, sid, eid, text)
        time.sleep(0.3)
        actual = get_element_value(server, sid, eid)
        if actual is not None and field.verify(text, actual, mask, append):
            return True, actual
        shown = None if actual is None else len(actual)
        print(f"⚠️ 第 {attempt + 1} 次输入后读回不符（期望长度 {len(text)}，实际 {shown}）", flush=True)
    return False, actual


def execute_sync(server, sid, script, args=None):
    """执行 W3C 脚本（Appium mobile: 命令走这里，如 mobile: setPasteboard）。"""
    resp = _post(
        server.rstrip("/") + f"/session/{sid}/execute/sync",
        {"script": script, "args": [args or {}]},
    )
    if resp.status_code >= 400:
        raise RuntimeError(f"执行脚本失败 {resp.status_code}: {_error_text(resp)}")
    return resp.json().get("value")


def _step_xy(step, kind):
    """取步骤坐标。缺字段/非数字一律 RuntimeError（⇒ rc=1 步骤失败），不要冒泡成 rc=3 驱动错误。"""
    try:
        return int(float(step["x"])), int(float(step["y"]))
    except KeyError as e:
        raise RuntimeError(f"{kind} 步骤缺少坐标 {e}") from None
    except (TypeError, ValueError):
        raise RuntimeError(
            f"{kind} 步骤的 x/y 不是数字: {step.get('x')!r}, {step.get('y')!r}"
        ) from None


def _step_num(step, key, default):
    """取数值参数（秒 / 保持时长）；非法值同样是步骤错误（rc=1），不是驱动错误。"""
    try:
        return float(step.get(key, default))
    except (TypeError, ValueError):
        raise RuntimeError(f"步骤参数 {key} 不是数字: {step.get(key)!r}") from None


def run_steps(server, sid, steps):
    """单会话按序执行步骤；任一步失败立即返回 False（已打印失败步骤）。"""
    for idx, step in enumerate(steps, 1):
        kind = step.get("type") or step.get("action") or ""
        try:
            if kind == "tap":
                eid = find_element(server, sid, step.get("using", "accessibility id"), step.get("value", ""))
                if eid is None:
                    raise RuntimeError(f"未找到元素: {step.get('value')}")
                click_element(server, sid, eid)
            elif kind == "type":
                eid = find_element(server, sid, step.get("using", "accessibility id"), step.get("value", ""))
                if eid is None:
                    raise RuntimeError(f"未找到输入元素: {step.get('value')}")
                if step.get("click", True):
                    click_element(server, sid, eid)
                    time.sleep(_step_num(step, "click_wait", 0.5))
                # clear 缺省 True：`element/value` 是追加语义，不清空会把旧内容留下（兼容性变更，
                # 还原追加行为需显式写 {"clear": false}；见 SKILL.md 的 Appium 小节）
                _text = step.get("text", "")
                # 空串不当作「输入成功」：清空后 verify("","") 会直接通过（凭据文件模板里
                # ACCOUNT= / PASSWORD= 就是空值），把「什么也没输」当成功是典型假绿。
                if _text == "" and not step.get("allow_empty", False):
                    raise RuntimeError(
                        f"type 步骤文本为空（元素={step.get('value')!r}）——检查凭据文件/--key；"
                        "确需清空请显式写 {\"allow_empty\": true}"
                    )
                _clear = bool(step.get("clear", True))
                _retries = int(_step_num(step, "retries", 1))
                if _retries < 0:
                    _retries = 0   # 负数会让 range 为空 ⇒ 一次都不输入却报「读回不符」，误导排障
                if not _clear:
                    # 追加语义下**不能重试**：send_text 是追加，重来一次会变成「旧+text+text」，
                    # 而后缀校验仍然通过 ⇒ 假绿 + 内容污染（2026-11-12 复审 P1-N1）。
                    _retries = 0
                _ok, _actual = type_into(
                    server, sid, eid, _text,
                    clear=_clear,
                    mask=bool(step.get("mask", False)),
                    retries=_retries,
                )
                if not _ok:
                    raise RuntimeError(
                        f"输入后读回校验不符（元素={step.get('value')!r}，期望长度 {len(_text)}，"
                        f"实际={None if _actual is None else len(_actual)}）"
                    )
            elif kind == "assert":
                eid = find_element(server, sid, step.get("using", "accessibility id"), step.get("value", ""))
                if eid is None:
                    raise RuntimeError(f"断言失败（元素不存在）: {step.get('value')}")
            elif kind == "exec":
                val = execute_sync(server, sid, step.get("script", ""), step.get("args"))
                print(f"  ↳ exec {step.get('script')} -> {str(val)[:200]}", flush=True)
            elif kind == "shot":
                out = step.get("out", "")
                if not out:
                    raise RuntimeError("shot 步骤缺少 out")
                print(f"  ↳ 截图: {get_screenshot(server, sid, out)}", flush=True)
            elif kind == "source":
                src = get_source(server, sid)
                # ⚠️ 截断必须显式提示：静默截断会让调用方把「末尾节点不存在」误判成
                # 「元素不在语义树」（2026-11-09 实测被坑过一次，弹层节点正落在 4000 字符之后）。
                limit = 0 if step.get("full") else 4000
                if limit and len(src) > limit:
                    print(src[:limit], flush=True)
                    print(
                        f"⚠️ source 已截断：共 {len(src)} 字符，仅显示前 {limit}；"
                        f'需要完整语义树请用 {{"type":"source","full":true}}',
                        flush=True,
                    )
                else:
                    print(src, flush=True)
            elif kind == "wait":
                time.sleep(float(step.get("seconds", 1)))
            elif kind == "tap_xy":
                _x, _y = _step_xy(step, "tap_xy")
                perform_pointer(server, sid, _x, _y, hold=_step_num(step, "hold", 0.05))
            elif kind == "long_press":
                _x, _y = _step_xy(step, "long_press")
                perform_pointer(server, sid, _x, _y, hold=_step_num(step, "seconds", 1.5))
            elif kind == "hold_and_background":
                _x, _y = _step_xy(step, "hold_and_background")
                hold_and_background(
                    server, sid, _x, _y,
                    hold=_step_num(step, "hold", 4),
                    at=_step_num(step, "at", 1.5),
                    seconds=_step_num(step, "seconds", 3),
                )
            elif kind == "background":
                background_app(server, sid, _step_num(step, "seconds", 3))
            elif kind == "activate":
                _bid = step.get("bundleId", "")
                if not _bid:
                    raise RuntimeError("activate 步骤缺少 bundleId")
                activate_app(server, sid, _bid)
            elif kind == "home":
                press_button(server, sid, step.get("name", "home"))
            else:
                raise RuntimeError(f"未知步骤类型: {kind!r}")
            print(f"✅ step {idx} [{kind}] ok", flush=True)
        except RuntimeError as e:
            print(f"❌ step {idx} [{kind}] 失败: {e}", flush=True)
            return False
    return True


def get_screenshot(server, sid, out):
    resp = requests.get(server.rstrip("/") + f"/session/{sid}/screenshot", timeout=120)
    if resp.status_code >= 400:
        raise RuntimeError(f"截图失败 {resp.status_code}: {resp.text[:300]}")
    data = resp.json().get("value", "")
    with open(out, "wb") as f:
        f.write(base64.b64decode(data))
    return out


def _load_text_source(path, key=""):
    """读 --text-from：KEY=VALUE 行（可用 --key 选行）或单行原文；'-' 走 stdin。

    权限纪律：非 stdin 一律要求 0600（与 android/input.sh 一致），避免把密码文件
    放进仓库时人人可读；权限不符按用法错（rc=2）处理，不静默继续。
    """
    if path == "-":
        raw = sys.stdin.read()
    else:
        try:
            st = os.stat(path)
        except OSError as exc:
            print(f"❌ --text-from 无法读取: {exc}", file=sys.stderr)
            sys.exit(2)
        if st.st_mode & 0o077:
            print(f"❌ {path} 权限为 {oct(st.st_mode & 0o777)}，要求 600：chmod 600 {path}", file=sys.stderr)
            sys.exit(2)
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    lines = [ln for ln in raw.splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    if not lines:
        print("❌ --text-from 内容为空", file=sys.stderr)
        sys.exit(2)
    if key:
        for ln in lines:
            if "=" in ln:
                k, v = ln.split("=", 1)
                if k.strip() == key:
                    return v
        print(f"❌ --text-from 里没有 {key}=…", file=sys.stderr)
        sys.exit(2)
    first = lines[0]
    if len(lines) == 1 and "=" not in first:
        return first
    return first.split("=", 1)[1] if "=" in first else first


def main():
    p = argparse.ArgumentParser(description="Appium W3C WebDriver 极简客户端")
    p.add_argument("action", choices=["source", "find-click", "find-assert", "find-type", "screenshot", "flow"])
    p.add_argument("--server", default="http://127.0.0.1:4723")
    p.add_argument("--caps", required=True, help="capabilities JSON 文件路径")
    p.add_argument("--using", default="accessibility id")
    p.add_argument("--value", default="")
    p.add_argument("--text", default="", help="find-type 要输入的文字（与 --text-from 互斥）")
    p.add_argument("--text-from", default="", help="find-type 从 KEY=VALUE 文件读（'-' = stdin；须 0600）")
    p.add_argument("--key", default="", help="--text-from 取哪一行（缺省第一条）")
    p.add_argument("--clear", dest="clear", action="store_true", default=True,
                   help="find-type 先清空（默认开；旧内容不清空是登录输错的主因）")
    p.add_argument("--no-clear", dest="clear", action="store_false", help="find-type 追加而非替换")
    p.add_argument("--mask", action="store_true", help="find-type 掩码字段（读回只比长度）")
    p.add_argument("--expect", default="",
                   help="find-type 输入后额外断言读回值等于该值（平台会转换输入时用；掩码只比长度）")
    p.add_argument("--steps", default="", help="flow 步骤 JSON 文件路径")
    p.add_argument("--out", default="")
    # 会话创建即触发 App 启动；Flutter 首帧/启动页期间取 source 会拿到空树
    p.add_argument("--wait", type=float, default=0.0, help="会话创建后先休眠 N 秒再执行动作")
    p.add_argument("--element-wait", type=float, default=10.0, help="元素查找最长等待秒数（默认 10）")
    args = p.parse_args()

    global ELEMENT_WAIT
    ELEMENT_WAIT = args.element_wait

    try:
        caps = json.load(open(args.caps, encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        print(f"caps 读取失败: {e}", file=sys.stderr)
        sys.exit(2)

    steps = None
    if args.action == "flow":
        if not args.steps:
            print("--steps 必填", file=sys.stderr)
            sys.exit(2)
        try:
            steps = json.load(open(args.steps, encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            print(f"steps 读取失败: {e}", file=sys.stderr)
            sys.exit(2)
        if not isinstance(steps, list) or not steps:
            print("steps 必须是非空数组", file=sys.stderr)
            sys.exit(2)

    sid = None
    try:
        sid = start_session(args.server, caps)
        if args.wait and args.wait > 0:
            time.sleep(args.wait)
        if args.action == "source":
            print(get_source(args.server, sid))
            sys.exit(0)
        if args.action == "screenshot":
            if not args.out:
                print("--out 必填", file=sys.stderr)
                sys.exit(2)
            print(f"✅ 截图: {get_screenshot(args.server, sid, args.out)}")
            sys.exit(0)
        if args.action == "flow":
            ok = run_steps(args.server, sid, steps)
            sys.exit(0 if ok else 1)

        # find-click / find-assert / find-type
        if not args.value:
            print("--value 必填", file=sys.stderr)
            sys.exit(2)
        if args.action == "find-type":
            if args.text and args.text_from:
                print("--text 与 --text-from 互斥", file=sys.stderr)
                sys.exit(2)
            if not args.text and not args.text_from:
                print("find-type 需要 --text 或 --text-from（敏感值建议用文件，避免进会话记录）", file=sys.stderr)
                sys.exit(2)
            text = args.text or _load_text_source(args.text_from, args.key)
            if text == "":
                # 空值先拦：清空后 verify("","") 会假通过（凭据模板里 ACCOUNT= 就是空）
                print("❌ 取到的文本为空（检查 --text-from / --key）", file=sys.stderr)
                sys.exit(2)
        else:
            text = ""
        eid = find_element(args.server, sid, args.using, args.value)
        if eid is None:
            print(json.dumps({"found": False, "using": args.using, "value": args.value}, ensure_ascii=False))
            sys.exit(1)
        if args.action == "find-click":
            click_element(args.server, sid, eid)
            print(json.dumps({"found": True, "clicked": True, "value": args.value}, ensure_ascii=False))
        elif args.action == "find-type":
            click_element(args.server, sid, eid)
            time.sleep(0.5)
            ok, actual = type_into(args.server, sid, eid, text,
                                   clear=args.clear, mask=args.mask, retries=1)
            if not ok:
                # 校验不符 → rc=1（步骤失败），与 flow 的 type 步骤同义；不要落成 3（驱动错误）
                print(json.dumps({"found": True, "typed": False, "value": args.value,
                                  "expect_len": len(text),
                                  "actual_len": None if actual is None else len(actual)}, ensure_ascii=False))
                sys.exit(1)
            if args.expect:
                # 平台会转换输入（大写化/去空格/掩码）时，用 --expect 断言「读回应等于什么」；
                # 比对与 type_into 同源（field.verify），不另写一套
                if actual is None or not field.verify(args.expect, actual, args.mask, not args.clear):
                    print(json.dumps({"found": True, "typed": True, "verified": False,
                                      "value": args.value,
                                      "expect_len": len(args.expect),
                                      "actual_len": None if actual is None else len(actual)},
                                     ensure_ascii=False))
                    sys.exit(1)
            print(json.dumps({"found": True, "typed": True, "cleared": args.clear,
                              "value": args.value, "len": len(text)}, ensure_ascii=False))
        else:
            print(json.dumps({"found": True, "value": args.value}, ensure_ascii=False))
        sys.exit(0)
    except RuntimeError as e:
        print(f"❌ {e}", file=sys.stderr)
        sys.exit(3)
    except requests.exceptions.RequestException as e:
        print(f"❌ 无法连接 Appium 服务（{args.server}）: {e}", file=sys.stderr)
        sys.exit(3)
    except Exception as e:  # noqa: BLE001
        # 兜底：未预期异常也必须归为「驱动错误」(3)，绝不落成 1（未找到），否则会污染断言语义
        print(f"❌ 驱动异常: {e}", file=sys.stderr)
        sys.exit(3)
    finally:
        if sid:
            end_session(args.server, sid)


if __name__ == "__main__":
    main()