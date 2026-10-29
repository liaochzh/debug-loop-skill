#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_snapshot_parse.py — 页面 XML 归一化解析（uiautomator / XCUITest / mac2）

用法:
    python3 _snapshot_parse.py --input <xml> [--json] [--max 40] [--center]
                               [--dialect auto|uiautomator|xcuitest|mac2|maestro]

输出:
    默认: 人读摘要（TSV，text 截断 40 字符、最多 --max 行）
          --center 追加第 7 列 cx,cy（无中心则 `-`；--json 时忽略）
    --json: 断言/点击专用全量数据（全文 text、不限行数；节点集与摘要一致，仅不截断）
            每条记录含 type/text/id/bounds/clickable/center（center 为 [cx,cy] 或 null）

退出码:
    0 成功
    1 解析失败 / 文件不可读 / 方言无法识别
    2 用法错误
    4 语义树为空（raw_nodes > 0 且过滤后 nodes == 0）
       ⚠️ 观测失败一律返回 1，不得返回 4（见 SKILL.md「页面观测阶梯」）
"""

import argparse
import csv
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET

SUMMARY_TEXT_MAX = 40
DEFAULT_MAX = 40

# XCUITest / mac2 无 clickable 字段（恒 true）⇒ 用 type 白名单剔除容器行，避免摘要被容器占满。
XCUI_ALLOW = {
    "StaticText", "Button", "TextField", "SecureTextField", "TextView",
    "Switch", "Slider", "Link", "SearchField", "Image",
}
MAC2_ALLOW = {
    "AXButton", "AXStaticText", "AXTextField", "AXTextArea", "AXImage",
    "AXLink", "AXCheckBox", "AXRadioButton", "AXCell", "AXMenuItem",
}


def detect_dialect(root):
    """按标签名分流三种 page source 方言。"""
    tags = [el.tag for el in root.iter()]
    if any(t == "node" for t in tags):
        return "uiautomator"
    if any(t.startswith("XCUIElementType") for t in tags):
        return "xcuitest"
    if any(t.startswith("AX") for t in tags):
        return "mac2"
    return "unknown"


def _first(el, keys):
    for key in keys:
        value = el.get(key)
        if value:
            return value
    return ""


def _xcui_bounds(el):
    try:
        x = int(float(el.get("x", 0)))
        y = int(float(el.get("y", 0)))
        w = int(float(el.get("width", 0)))
        h = int(float(el.get("height", 0)))
    except (TypeError, ValueError):
        return ""
    return "[%d,%d][%d,%d]" % (x, y, x + w, y + h)


def parse_rect(bounds, dialect):
    """bounds 原文 → (x1, y1, x2, y2)；解析失败返回 None。四种方言共用同一事实源。"""
    if not bounds:
        return None
    if dialect == "mac2":
        match = re.search(r"\{\{\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\}\s*,\s*"
                          r"\{\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\}\s*\}", bounds)
        if match:
            x, y, w, h = (float(v) for v in match.groups())
            return (int(x), int(y), int(x + w), int(y + h))
    match = re.search(r"\[\s*(-?\d+)\s*,\s*(-?\d+)\s*\]\s*\[\s*(-?\d+)\s*,\s*(-?\d+)\s*\]", bounds)
    if not match:
        return None
    return tuple(int(v) for v in match.groups())


def compute_center(bounds, dialect):
    rect = parse_rect(bounds, dialect)
    if rect is None:
        return None
    x1, y1, x2, y2 = rect
    if x2 - x1 <= 0 or y2 - y1 <= 0:
        return None
    return [(x1 + x2) // 2, (y1 + y2) // 2]


def build_record(node_type, text, node_id, bounds, clickable, dialect):
    """唯一的记录构造入口：`to_record` 与 `parse_maestro` 共用，保证两路都有 `center`。"""
    return {
        "type": node_type,
        "text": " ".join(text.split()),
        "id": node_id,
        "bounds": bounds,
        "clickable": clickable,
        "center": compute_center(bounds, dialect),
    }


def to_record(el, dialect):
    if dialect == "uiautomator":
        text = _first(el, ["text", "content-desc"])
        node_id = el.get("resource-id") or ""
        node_type = el.get("class") or ""
        bounds = el.get("bounds") or ""
        clickable = el.get("clickable") == "true"
    elif dialect == "xcuitest":
        text = _first(el, ["label", "name", "value"])
        node_id = el.get("name") or ""
        node_type = el.tag.replace("XCUIElementType", "")
        bounds = _xcui_bounds(el)
        clickable = True
    elif dialect == "mac2":
        text = _first(el, ["AXTitle", "AXValue", "AXDescription"])
        node_id = el.get("AXIdentifier") or ""
        node_type = el.get("AXRole") or el.tag
        bounds = el.get("AXFrame") or ""
        clickable = True
    else:
        return None

    return build_record(node_type, text, node_id, bounds, clickable, dialect)


def keep(rec, dialect):
    """统一过滤集：摘要与 --json 共用，保证断言不会因摘要截断而漏节点。"""
    if dialect == "maestro":
        return bool(rec["text"] or rec["id"])
    if dialect == "uiautomator":
        return bool(rec["text"] or rec["id"] or rec["clickable"])
    allow = XCUI_ALLOW if dialect == "xcuitest" else MAC2_ALLOW
    if rec["type"] not in allow:
        return False
    return bool(rec["text"] or rec["id"])


def parse_maestro(path):
    """解析 `maestro hierarchy --compact` 的 CSV（iOS 模拟器实测唯一可靠的 Flutter 语义源）。"""
    records = []
    raw_nodes = 0
    with open(path, encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            raw_nodes += 1
            attrs = {}
            for part in re.split(r"; (?=[A-Za-z0-9_-]+=)", row.get("attributes") or ""):
                if "=" not in part:
                    continue
                key, value = part.split("=", 1)
                attrs[key.strip()] = value.strip()
            text = attrs.get("accessibilityText") or attrs.get("text") or attrs.get("value") or ""
            node_id = attrs.get("resource-id") or ""
            rec = build_record("node", text, node_id, attrs.get("bounds") or "",
                               attrs.get("enabled") == "true", "maestro")
            if keep(rec, "maestro"):
                records.append(rec)
    return records, raw_nodes


def fingerprint(records):
    payload = "\n".join("%s|%s|%s" % (r["type"], r["text"], r["id"]) for r in records)
    return hashlib.md5(payload.encode("utf-8")).hexdigest()[:8]


def truncate(text, limit):
    return text if len(text) <= limit else text[:limit] + "…"


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--max", type=int, default=DEFAULT_MAX)
    parser.add_argument("--center", action="store_true",
                        help="摘要追加第 7 列 cx,cy（--json 时忽略：全量已含 center 字段）")
    parser.add_argument("--dialect", default="auto",
                        choices=["auto", "uiautomator", "xcuitest", "mac2", "maestro"])
    args = parser.parse_args()

    if args.max <= 0:
        print("❌ --max 必须为正整数", file=sys.stderr)
        return 2

    is_csv = False
    try:
        with open(args.input, encoding="utf-8", errors="replace") as handle:
            is_csv = handle.readline().startswith("element_num,")
    except OSError as exc:
        print("❌ 无法读取输入: %s (%s)" % (args.input, exc), file=sys.stderr)
        return 1

    if args.dialect == "maestro" or is_csv:
        try:
            records, raw_nodes = parse_maestro(args.input)
        except OSError as exc:
            print("❌ 无法读取 CSV: %s (%s)" % (args.input, exc), file=sys.stderr)
            return 1
        dialect = "maestro"
    else:
        try:
            tree = ET.parse(args.input)
        except (ET.ParseError, OSError) as exc:
            print("❌ 无法解析 XML: %s (%s)" % (args.input, exc), file=sys.stderr)
            return 1

        root = tree.getroot()
        dialect = args.dialect if args.dialect != "auto" else detect_dialect(root)
        if dialect == "unknown":
            print("❌ 无法识别 page source 方言（期望 uiautomator/XCUITest/mac2/maestro CSV）", file=sys.stderr)
            return 1

        raw_nodes = 0
        records = []
        for el in root.iter():
            if dialect == "uiautomator" and el.tag != "node":
                continue
            if dialect == "xcuitest" and not el.tag.startswith("XCUIElementType"):
                continue
            if dialect == "mac2" and not el.tag.startswith("AX"):
                continue
            raw_nodes += 1
            rec = to_record(el, dialect)
            if rec is not None and keep(rec, dialect):
                records.append(rec)

    fp = fingerprint(records)

    if args.json:
        payload = {
            "dialect": dialect,
            "raw_nodes": raw_nodes,
            "nodes": records,
            "fingerprint": fp,
        }
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print("# dialect=%s raw=%d nodes=%d fp=%s"
              % (dialect, raw_nodes, len(records), fp))
        shown = records[:args.max]
        for idx, rec in enumerate(shown, 1):
            line = "%d|%s|%s|%s|%s|%s" % (
                idx,
                rec["type"],
                truncate(rec["text"], SUMMARY_TEXT_MAX),
                rec["id"],
                rec["bounds"],
                "true" if rec["clickable"] else "false",
            )
            if args.center:
                center = rec.get("center")
                line += "|%s" % ("%d,%d" % (center[0], center[1]) if center else "-")
            print(line)
        rest = len(records) - len(shown)
        if rest > 0:
            print("…(另有 %d 个)" % rest)

    # 观测失败（空 dump / App 未启动 / 无障碍未开）：raw=0 不是「语义树为空」，必须 exit 1
    if raw_nodes == 0:
        print("❌ page source 无任何节点（App 未启动或无障碍未开启，可重试）", file=sys.stderr)
        return 1
    # 语义树为空：dump 成功但没有任何可判定节点（≠ 页面空白，也 ≠ 观测失败）
    if not records:
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
