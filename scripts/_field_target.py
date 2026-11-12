#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_field_target.py — 输入框定位 + 清空/校验方案（纯函数 + 单次 CLI）

为什么单独一个文件：输入框的「读当前值 → 算删除次数 → 读回校验」判据要在
`android/input.sh`（shell 派发）与 `appium/driver.py`（iOS 真机走 W3C）两处复用，
写两遍必然漂移（settle.sh 的 PREV 自比假静止就是同类事故）。

用法:
    bash scripts/snapshot.sh --platform android --json > /tmp/s.json
    python3 _field_target.py --snapshot /tmp/s.json --field 账号 [--index N] [--mask] [--kv]
    python3 _field_target.py --snapshot /tmp/s.json --bounds "[0,100][200,160]" [--kv]
    python3 _field_target.py --verify --expect 'abc' --actual 'abc' [--mask]

子命令/模式:
    默认        选节点 + 给方案，输出单行 JSON
    --bounds    按 bounds 精确定位（**输入后原文/占位符可能变化 ⇒ 不能再用关键词定位**）
    --kv        输出 KEY=VALUE 行（供 shell 读取；值不做转义，调用方按首个 '=' 切分）
    --verify    只做读回比对：rc=0 一致 / rc=1 不一致

退出码: 0 命中且校验一致 / 1 未命中·无坐标·校验不一致 / 2 用法错
"""
import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import _tap_target as tap  # noqa: E402  复用 matches / node_values / offscreen / screen_rect

# 掩码字段（密码）语义值常为空或全为圆点；读不到长度时按此下限保守删除
MASK_MIN_DELS = 12
# 单批 DEL 上限：一次 `adb shell input keyevent` 不宜过长（老 ROM 有参数上限）
MAX_DELS = 64


def plan_clear(current, mask=False):
    """纯函数：给出清空方案 → (dels, visible_len)。

    - 掩码字段且当前值不可见（空串）⇒ MASK_MIN_DELS，避免「看起来空其实有内容」
    - 可见值 ⇒ 长度 +3（吃掉尾随空格/光标位置误差），上限 MAX_DELS
    """
    text = current or ""
    visible = len(text)
    if mask and visible == 0:
        return MASK_MIN_DELS, 0
    if visible == 0:
        return 0, 0
    return min(visible + 3, MAX_DELS), visible


def verify(expected, actual, mask=False, append=False):
    """纯函数：读回校验。

    - mask=True 只比长度（密码框语义值常被掩码或置空）
    - append=True 表示「追加输入」：读回值是「旧内容 + 本次输入」⇒ 只能判**后缀**
      （不判后缀就会把「追加成功」误判成不符，进而多删一遍 —— 2026-11-12 实测）
    """
    expected = expected or ""
    actual = actual or ""
    if append:
        if mask:
            return len(actual) >= len(expected)
        return actual.endswith(expected)
    if mask:
        return len(actual) == len(expected)
    return actual == expected


EDITABLE_HINTS = ("edittext", "textfield", "textinput", "autocompletetextview",
                  "searchview", "securetextfield")


def is_editable(node):
    """可编辑节点判定（Android EditText / iOS TextField / Compose 语义）。

    用途：读回阶段用 `--editable-only` 定位，避免「关键词先命中同名静态 label」而读到别的值。
    """
    return any(h in (node.get("type") or "").lower() for h in EDITABLE_HINTS)


def candidates(nodes, limit=8):
    """未命中时的候选清单（附中心坐标，便于人工确认是不是选错节点）。"""
    out = []
    for node in nodes:
        if not isinstance(node, dict):
            continue
        text = (node.get("text") or "").strip()
        nid = (node.get("id") or "").strip()
        if not text and not nid:
            continue
        label = text or nid
        center = node.get("center")
        out.append("%s%s" % (label[:30], "" if not center else " (%d,%d)" % (center[0], center[1])))
        if len(out) >= limit:
            break
    return out


def emit(obj, kv=False, code=0):
    if kv and obj.get("ok"):
        node = obj.get("node") or {}
        lines = [
            "ok=1",
            "cx=%d" % obj["center"][0],
            "cy=%d" % obj["center"][1],
            "dels=%d" % obj["dels"],
            "needs_clear=%d" % (1 if obj["needs_clear"] else 0),
            "clickable=%d" % (1 if obj["clickable"] else 0),
            "offscreen=%d" % (1 if obj["offscreen"] else 0),
            "bounds=%s" % (node.get("bounds") or ""),
            "id=%s" % (node.get("id") or ""),
            "total=%d" % obj.get("total", 1),
            "current=%s" % (obj.get("current") or ""),
        ]
        print("\n".join(lines))
    else:
        print(json.dumps(obj, ensure_ascii=False))
    return code


def load_nodes(path):
    raw = ""
    if path:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                raw = fh.read()
        except OSError as exc:
            return None, None, "无法读取快照: %s" % exc
    else:
        raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except ValueError:
        return None, None, "快照不是合法 JSON"
    nodes = payload.get("nodes")
    if not isinstance(nodes, list):
        return None, None, "快照 nodes 不是数组"
    return nodes, payload, ""


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--snapshot", default="", help="snapshot.sh --json 产物路径（缺省读 stdin）")
    ap.add_argument("--field", default="", help="目标关键词（text 或 id 子串，忽略大小写、非正则）")
    ap.add_argument("--bounds", default="", help="按 bounds 精确定位（输入后再定位用）")
    ap.add_argument("--exact", action="store_true", help="精确匹配且大小写敏感")
    ap.add_argument("--editable-only", action="store_true",
                    help="只在可编辑节点（EditText/TextField…）上匹配，避免命中静态 label")
    ap.add_argument("--index", type=int, default=1, help="多处命中取第 N 个（1-based）")
    ap.add_argument("--mask", action="store_true", help="掩码字段（只比长度、不回显值）")
    ap.add_argument("--kv", action="store_true", help="输出 KEY=VALUE 行（供 shell）")
    ap.add_argument("--verify", action="store_true", help="只做读回比对")
    ap.add_argument("--append", action="store_true", help="追加输入语义（--verify 只判后缀）")
    ap.add_argument("--plan-clear", default=None, metavar="值",
                    help="只按给定值算清空次数并打印数字（供 shell 复用，避免第二处漂移）")
    ap.add_argument("--expect", default="", help="--verify 的期望值")
    ap.add_argument("--actual", default="", help="--verify 的实际值")
    args = ap.parse_args(argv)

    if args.verify:
        ok = verify(args.expect, args.actual, args.mask, args.append)
        print("ok" if ok else "mismatch")
        return 0 if ok else 1

    if args.plan_clear is not None:
        dels, _ = plan_clear(args.plan_clear, args.mask)
        print(dels)
        return 0

    if args.index < 1:
        print(json.dumps({"ok": False, "reason": "--index 必须 ≥1"}, ensure_ascii=False))
        return 2
    if not args.field and not args.bounds:
        print(json.dumps({"ok": False, "reason": "需要 --field 或 --bounds"}, ensure_ascii=False))
        return 2

    nodes, payload, err = load_nodes(args.snapshot)
    if nodes is None:
        print(json.dumps({"ok": False, "reason": err}, ensure_ascii=False))
        return 1

    if args.bounds:
        hits = [n for n in nodes if isinstance(n, dict) and (n.get("bounds") or "") == args.bounds]
        # 父容器与输入框 bounds 可能完全相同（常见于 TextInputLayout/FilledBox）⇒ 优先取可编辑节点，
        # 否则会读到父容器的空 text，把「有内容」误判成「已清空」（假 rc=0）。
        if len(hits) > 1:
            edit_hits = [n for n in hits if is_editable(n)]
            if edit_hits:
                hits = edit_hits
        why = "未命中 bounds（该输入框可能已不在当前页/被滚动走）"
    else:
        hits = []
        for node in nodes:
            if not isinstance(node, dict):
                continue
            if args.editable_only and not is_editable(node):
                continue
            if any(tap.matches(v, args.field, args.exact) for v in tap.node_values(node, False)):
                hits.append(node)
        why = "未命中字段"

    if not hits:
        return emit({"ok": False, "reason": why, "candidates": candidates(nodes)}, kv=args.kv, code=1)
    if args.index > len(hits):
        return emit({"ok": False, "reason": "--index %d 越界（命中 %d 处）" % (args.index, len(hits)),
                     "candidates": candidates(hits)}, kv=args.kv, code=1)

    node = hits[args.index - 1]
    center = node.get("center")
    if not center:
        return emit({"ok": False, "reason": "节点无中心坐标（可能不在屏内）",
                     "candidates": candidates(hits)}, kv=args.kv, code=1)

    current = node.get("text") or ""
    dels, visible = plan_clear(current, args.mask)
    # 掩码场景不回显明文（值可能其实是「圆点」或干脆是明文密码）：只给长度
    shown_current = "" if args.mask else current
    obj = {
        "ok": True,
        "node": {"text": "" if args.mask else current, "id": node.get("id") or "",
                 "bounds": node.get("bounds") or "", "type": node.get("type") or ""},
        "center": [center[0], center[1]],
        "current": shown_current,
        "visible_len": visible,
        "dels": dels,
        "needs_clear": dels > 0,
        "total": len(hits),
        "clickable": bool(node.get("clickable")),
        "offscreen": tap.offscreen(center, tap.screen_rect(nodes, payload.get("dialect") or "uiautomator")),
    }
    return emit(obj, kv=args.kv, code=0)


if __name__ == "__main__":
    sys.exit(main())