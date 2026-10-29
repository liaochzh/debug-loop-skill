#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_assert_page.py — 对 snapshot --json 结果做声明式断言

用法（推荐经 assert_page.sh，它会校验 snapshot 退出码）:
    ./assert_page.sh --file <断言文件> [--platform P]

断言文件语法（每行一条，# 开头为注释）:
    has <文本>            任一节点 text/id 包含该文本（字面，忽略大小写）
    has-not <文本>        任一节点都不包含
    match <正则>          任一节点 text/id 命中正则
    not-match <正则>      任一节点都不命中
    count <正则> <N>      命中正则的节点数 == N

退出码:
    0 全部通过 / 1 有断言失败 / 2 用法错 / 5 快照数据不可解析
"""

import argparse
import json
import re
import sys

CANDIDATE_LIMIT = 5


def die(msg, code):
    print("❌ " + msg, file=sys.stderr)
    sys.exit(code)


def parse_asserts(path):
    items = []
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.readlines()
    except OSError as exc:
        die("无法读取断言文件: %s (%s)" % (path, exc), 2)

    for lineno, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        kind = parts[0]
        try:
            if kind in ("has", "has-not", "match", "not-match"):
                if len(parts) < 2:
                    raise ValueError("缺少参数")
                items.append((kind, " ".join(parts[1:]), lineno))
            elif kind == "count":
                if len(parts) < 3:
                    raise ValueError("需要 <正则> <N>")
                items.append((kind, (" ".join(parts[1:-1]), int(parts[-1])), lineno))
            else:
                raise ValueError("未知断言类型 %s" % kind)
        except ValueError as exc:
            die("断言文件第 %d 行无效: %s (%s)" % (lineno, line, exc), 2)
    return items


def node_texts(node):
    values = []
    if node.get("text"):
        values.append(node["text"])
    if node.get("id"):
        values.append(node["id"])
    return values


def check(item, nodes):
    """返回 (ok, 描述, 候选)。"""
    kind, arg, _lineno = item
    texts = [text for node in nodes for text in node_texts(node)]

    if kind in ("has", "has-not"):
        needle = arg.lower()
        hits = [text for text in texts if needle in text.lower()]
        ok = bool(hits) if kind == "has" else not hits
        desc = '%s "%s"' % (kind, arg)
        return ok, desc, hits[:CANDIDATE_LIMIT]

    if kind in ("match", "not-match"):
        try:
            pattern = re.compile(arg)
        except re.error as exc:
            die("正则无效: %s (%s)" % (arg, exc), 2)
        hits = [text for text in texts if pattern.search(text)]
        ok = bool(hits) if kind == "match" else not hits
        desc = '%s "%s"' % (kind, arg)
        return ok, desc, hits[:CANDIDATE_LIMIT]

    # count
    pattern_text, expected = arg
    try:
        pattern = re.compile(pattern_text)
    except re.error as exc:
        die("正则无效: %s (%s)" % (pattern_text, exc), 2)
    matched = [node for node in nodes
               if any(pattern.search(text) for text in node_texts(node))]
    ok = len(matched) == expected
    desc = 'count "%s" 期望%d 实际%d' % (pattern_text, expected, len(matched))
    candidates = [node.get("text") or node.get("id") for node in matched][:CANDIDATE_LIMIT]
    return ok, desc, candidates


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--file", required=True)
    parser.add_argument("--platform", default="auto")
    args = parser.parse_args()

    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError) as exc:
        die("快照 JSON 不可解析: %s" % exc, 5)

    nodes = payload.get("nodes") or []
    items = parse_asserts(args.file)
    if not items:
        die("断言文件为空: %s" % args.file, 2)

    failures = []
    for item in items:
        ok, desc, candidates = check(item, nodes)
        if not ok:
            failures.append((desc, candidates))

    total = len(items)
    head = "platform=%s dialect=%s nodes=%d fp=%s" % (
        args.platform,
        payload.get("dialect", "?"),
        len(nodes),
        payload.get("fingerprint", "?"),
    )

    if not failures:
        print("✅ %d/%d PASS %s" % (total, total, head))
        return 0

    print("❌ %d/%d FAIL %s" % (len(failures), total, head))
    for desc, candidates in failures:
        print("  - %s" % desc)
        if candidates:
            shown = [str(c) for c in candidates if c]
            if shown:
                print("    候选: " + " / ".join(shown))
    return 1


if __name__ == "__main__":
    sys.exit(main())
