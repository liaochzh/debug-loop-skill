#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_tap_target.py — 从 snapshot --json 里按文本/id 选出点击目标，给出中心坐标

用法:
    bash snapshot.sh --json | python3 _tap_target.py --text <关键词> [--id] [--index N] [--exact] [--json]

匹配语义（= assert_page 的 has，是 android/tap.sh --text 的超集）:
    默认      text 或 id 上做「字面包含、忽略大小写」、非正则
    --id      只在 id 上匹配（同上语义）
    --exact   全文精确匹配、大小写敏感（区分 "Add" 与 "Add device"）

--index 为 1-based（与 maestro/tap.sh 一致），默认 1；越界 ⇒ rc=1 并打印总数。

输出:
    人读: 一行结论 + 多命中时附候选（≤5）+ 未命中时按 dialect 给一条下一步建议
          + 非 clickable / 疑似离屏的 ⚠️ 提示
    --json: 单行 {"text","id","center","bounds","clickable","offscreen","total","index"}（stdout）
            ⚠️ 提示改走 stderr，两种通道都不丢信息

退出码:
    0 命中 / 1 未命中或 --index 越界 / 2 用法错 / 5 JSON 不可解析 / 6 选中项无中心点
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _snapshot_parse import parse_rect  # noqa: E402  单一方言 bounds 解析事实源

CANDIDATE_LIMIT = 5


def die(msg, code):
    print("❌ " + msg, file=sys.stderr)
    sys.exit(code)


def node_values(node, id_only):
    """参与匹配的字段；--id 时只看 id（与 --exact 组合仍然只看 id）。"""
    if id_only:
        return [node.get("id") or ""]
    values = [node.get("text") or ""]
    node_id = node.get("id") or ""
    if node_id:
        values.append(node_id)
    return [v for v in values if v]


def matches(value, needle, exact):
    if not value:
        return False
    if exact:
        return value == needle
    return needle.lower() in value.lower()


def screen_rect(nodes, dialect):
    """屏幕代理：取面积最大的记录（Android/Flutter 实测即根节点≈全屏）。

    ⚠️ 不能用「全体记录并集」——并集必包含任一被选节点的 bounds，越屏判据会恒假。
    ⚠️ 已知局限：长滚动容器里「内容节点高度 ≫ 屏」时，最大面积记录可能是内容而非屏幕，
       此时越屏判据偏**假阴性**（漏报），不会误报；真正的可点性仍由点击后的断言兜底。
    """
    best = None
    best_area = -1
    for node in nodes:
        rect = parse_rect(node.get("bounds") or "", dialect)
        if rect is None:
            continue
        area = (rect[2] - rect[0]) * (rect[3] - rect[1])
        if area > best_area:
            best, best_area = rect, area
    return best


def offscreen(center, screen):
    """免费启发式：负坐标 或 超出屏幕代理 bounds。mac2 退化，仅负值分支有效。"""
    if center is None:
        return False
    cx, cy = center
    if cx < 0 or cy < 0:
        return True
    if screen is None:
        return False
    x1, y1, x2, y2 = screen
    return not (x1 <= cx <= x2 and y1 <= cy <= y2)


def describe(node):
    label = node.get("text") or node.get("id") or "(无文本)"
    return '%s center=(%d,%d)' % (label, node["center"][0], node["center"][1])


def suggest_next(dialect):
    """未命中时的下一步建议：按方言给**一个**可执行方向（不无条件推 findtap，iOS 上会 require_device 失败）。"""
    base = os.path.dirname(os.path.abspath(__file__))
    if dialect == "uiautomator":
        return '💡 目标可能在屏外：bash %s/android/findtap.sh "<关键词>"（自动滚动查找+点击）' % base
    if dialect == "maestro":
        return '💡 目标可能在屏外：bash %s/maestro/tap.sh "<关键词>"（语义定位；滚动用 maestro flow 的 scroll）' % base
    if dialect == "xcuitest":
        return '💡 改用 python3 %s/appium/driver.py find-click（语义定位，含滚动）' % base
    return '💡 先用 bash %s/snapshot.sh 核对语义树；视觉定位用 %s/vision/' % (base, base)


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--text", required=True)
    parser.add_argument("--id", action="store_true", dest="id_only")
    parser.add_argument("--index", type=int, default=1)
    parser.add_argument("--exact", action="store_true")
    parser.add_argument("--json", action="store_true", dest="as_json")
    args = parser.parse_args()

    if args.index < 1:
        die("--index 必须 ≥1（1-based）", 2)

    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError) as exc:
        die("快照 JSON 不可解析: %s" % exc, 5)

    nodes = payload.get("nodes") or []
    dialect = payload.get("dialect") or "uiautomator"

    hits = [node for node in nodes
            if any(matches(value, args.text, args.exact) for value in node_values(node, args.id_only))]

    if not hits:
        print('❌ 未命中 "%s"（nodes=%d，匹配字段=%s）'
              % (args.text, len(nodes), "id" if args.id_only else "text∪id"), file=sys.stderr)
        candidates = [node.get("text") or node.get("id") for node in nodes
                      if (node.get("text") or node.get("id"))][:CANDIDATE_LIMIT]
        if candidates:
            print("💡 候选: " + " / ".join(candidates), file=sys.stderr)
        if nodes:
            print(suggest_next(dialect), file=sys.stderr)
        else:
            # 语义树为空（snapshot rc=4）时推「滚动查找」会把排障引到错误方向
            print("💡 语义树为空：页面无文本/可点击节点（非页面空白）— 需 App 侧 Semantics 或改用 shot.sh", file=sys.stderr)
        return 1

    total = len(hits)
    if args.index > total:
        die("--index %d 越界（命中 %d 处）" % (args.index, total), 1)

    node = hits[args.index - 1]
    center = node.get("center")
    if not center:
        die('选中项无可用坐标（bounds=%r，无法解析中心点）' % (node.get("bounds") or ""), 6)

    clickable = bool(node.get("clickable"))
    is_offscreen = offscreen(center, screen_rect(nodes, dialect))

    if args.as_json:
        # 机器载荷仍走 stdout（单行 JSON）；⚠️ 提示走 stderr，两种通道都不丢信息
        print(json.dumps({
            "text": node.get("text") or "",
            "id": node.get("id") or "",
            "center": center,
            "bounds": node.get("bounds") or "",
            "clickable": clickable,
            "offscreen": is_offscreen,
            "total": total,
            "index": args.index,
        }, ensure_ascii=False))
        if not clickable:
            print("⚠️ 该节点 clickable=false，点击可能无响应（事件可能落在父容器）", file=sys.stderr)
        if is_offscreen:
            print("⚠️ bounds 疑似离屏（负值或超出屏幕代理范围），点击可能无效", file=sys.stderr)
        return 0

    print('✅ 命中 %d 处，取第 %d 处: text="%s" bounds=%s center=(%d,%d) clickable=%s'
          % (total, args.index, node.get("text") or "", node.get("bounds") or "",
             center[0], center[1], "true" if clickable else "false"))

    others = [h for h in hits if h is not node][:CANDIDATE_LIMIT]
    for other in others:
        if other.get("center"):
            print("  另有: " + describe(other))

    if not clickable:
        print("⚠️ 该节点 clickable=false，点击可能无响应（事件可能落在父容器）")

    if is_offscreen:
        print("⚠️ bounds 疑似离屏（负值或超出屏幕代理范围），点击可能无效")

    return 0


if __name__ == "__main__":
    sys.exit(main())
