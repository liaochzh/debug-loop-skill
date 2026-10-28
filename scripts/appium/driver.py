#!/usr/bin/env python3
# driver.py — 极简 Appium W3C WebDriver 客户端（基于 requests，无额外依赖）
#
# 用法:
#   driver.py source      --server <url> --caps <caps.json>
#   driver.py find-click  --server <url> --caps <caps.json> [--using "accessibility id"] [--value "登录"]
#   driver.py find-assert --server <url> --caps <caps.json> [--using ...] [--value ...]
#   driver.py find-type   --server <url> --caps <caps.json> [--using ...] [--value ...] --text "要输入的文字"
#   driver.py screenshot  --server <url> --caps <caps.json> --out <path.png>
#   driver.py flow        --server <url> --caps <caps.json> --steps <steps.json>
#
# flow 的 steps.json 为步骤数组，每步 {"type": ...}：
#   {"type":"tap","using":"...","value":"..."}            点击元素
#   {"type":"type","using":"...","value":"...","text":"…","click":true}  点焦点+输入文字
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
import sys
import time
import warnings

warnings.filterwarnings("ignore")

import requests

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


def execute_sync(server, sid, script, args=None):
    """执行 W3C 脚本（Appium mobile: 命令走这里，如 mobile: setPasteboard）。"""
    resp = _post(
        server.rstrip("/") + f"/session/{sid}/execute/sync",
        {"script": script, "args": [args or {}]},
    )
    if resp.status_code >= 400:
        raise RuntimeError(f"执行脚本失败 {resp.status_code}: {_error_text(resp)}")
    return resp.json().get("value")


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
                    time.sleep(float(step.get("click_wait", 0.5)))
                send_text(server, sid, eid, step.get("text", ""))
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
                print(src if step.get("full") else src[:4000], flush=True)
            elif kind == "wait":
                time.sleep(float(step.get("seconds", 1)))
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


def main():
    p = argparse.ArgumentParser(description="Appium W3C WebDriver 极简客户端")
    p.add_argument("action", choices=["source", "find-click", "find-assert", "find-type", "screenshot", "flow"])
    p.add_argument("--server", default="http://127.0.0.1:4723")
    p.add_argument("--caps", required=True, help="capabilities JSON 文件路径")
    p.add_argument("--using", default="accessibility id")
    p.add_argument("--value", default="")
    p.add_argument("--text", default="", help="find-type 要输入的文字")
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
        if args.action == "find-type" and not args.text:
            print("--text 必填", file=sys.stderr)
            sys.exit(2)
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
            send_text(args.server, sid, eid, args.text)
            print(json.dumps({"found": True, "typed": args.text, "value": args.value}, ensure_ascii=False))
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