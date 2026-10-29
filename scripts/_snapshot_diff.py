#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_snapshot_diff.py — 两份快照的变化判定（`snapshot.sh --diff` 的纯离线引擎）

用法:
    # 1) 选基线（snapshot.sh 内部调用；也可单独排查）
    python3 _snapshot_diff.py --pick-baseline --log-dir <dir> --platform <P> --dialect <D>
                              [--against <json>]

    # 2) 计算并输出 diff（人读 TSV，TAB 分隔）
    python3 _snapshot_diff.py --baseline <json> --current <json> [--max-diff 20]
                              [--baseline-kind last|prev|file] [--baseline-age 12]

--pick-baseline 输出（单行）:
    `<path>\\t<kind>\\t<age>\\t<stale>`，kind=file|last|prev，age 为整数秒或 `-`，stale=0|1

diff 输出:
    第 1 行 header（`# diff baseline=… fp=…→… nodes=M: +a -b ~c (text t / pos p / clickable k)`），
    随后每行一类变化（TAB 分隔）:
        +\\t<type>\\t<text>\\t<id>\\t<bounds>
        -\\t<type>\\t<text>\\t<id>\\t<bounds>
        ~ text\\t<type>\\t<旧→新（各截断 40 字符）>\\t<id>\\t<bounds>
        ~ pos\\t<type>\\t<text>\\t<id>\\t<旧 bounds>→<新 bounds>
        ~ clickable\\t<type>\\t<text>\\t<id>\\t<bounds>\\t<旧>→<新>
    截断时补一行 `另有 N 项未显示（共 T 项变化；--max-diff 调大可看全部）`。
    header 的计数与括号内分类计数都是**截断前全量**。

配对（三轮，每轮只看剩余集）:
    ⓪ bounds 不可解析者按 (type,text,id,bounds) 完全相等配对（相同记录必是同一节点）
    ① (type, id) —— 仅 id 非空的节点
    ② (type, bounds 解析后的四元组) —— 位置稳定、文本可能变（时间戳刷新）
    ③ (type, text) —— 位置变、文本稳定（滚动位移）
    ①②③ 之后仍剩余的只作 +/-；bounds 不可解析者不进 ①②③，排序时置尾。

变化分类（配对成功的一对，只报一类）: text > pos（任一坐标差 > 2px）> clickable

退出码:
    0 成功 / 1 无可用基线或基线不可解析 / 2 用法错（--against 缺文件、--max-diff 非正整数）
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _snapshot_parse import parse_rect, truncate  # noqa: E402  单一方言 bounds 解析事实源

POS_THRESHOLD = 2      # px：吸收动画/亚像素抖动
STALE_AGE = 60         # s：与 tap_snapshot 的缓存 TTL 对齐（只提示，不阻断）
TEXT_MAX = 40          # ~ text 行两侧各自的截断长度
DEFAULT_MAX_DIFF = 20
REQUIRED_KEYS = ("raw_nodes", "dialect", "fingerprint")

CLASS_ORDER = {"+": 0, "-": 1, "text": 2, "pos": 3, "clickable": 4}


# ---------- 基线可用性 ----------

def load_payload(path):
    """读取并校验「可用基线/当前快照」：能 json.load、nodes 为 list、含三个顶层键。"""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get("nodes"), list):
        return None
    for key in REQUIRED_KEYS:
        if key not in data:
            return None
    return data


def meta_of(payload):
    meta = payload.get("_meta")
    return meta if isinstance(meta, dict) else {}


def age_of(payload):
    """_meta.ts 距今秒数；缺失/非法返回 None（显式 --against 允许无 _meta 的产物）。"""
    ts = meta_of(payload).get("ts")
    try:
        return max(0, int(time.time()) - int(ts))
    except (TypeError, ValueError):
        return None


def mismatch_reasons(payload, dialect, platform):
    """基线与本次快照的 dialect/_meta.platform 不一致项（缺字段不参与比较）。"""
    reasons = []
    base_dialect = payload.get("dialect") or ""
    if dialect and base_dialect and base_dialect != dialect:
        reasons.append("dialect %s≠%s" % (base_dialect, dialect))
    base_platform = meta_of(payload).get("platform") or ""
    if platform and base_platform and base_platform != platform:
        reasons.append("platform %s≠%s" % (base_platform, platform))
    return reasons


def pick_baseline(args):
    """按 --against > last > prev 选基线；隐式基线不一致时硬拒且不降级读 prev。"""
    if args.against:
        if not os.path.isfile(args.against):
            print("❌ --against 指定的文件不存在: %s" % args.against, file=sys.stderr)
            return 2
        payload = load_payload(args.against)
        if payload is None:
            print("❌ 基线不可解析（需 snapshot.sh 的 --json 产物，含 nodes/raw_nodes/dialect/fingerprint）: %s"
                  % args.against, file=sys.stderr)
            return 1
        reasons = mismatch_reasons(payload, args.dialect, args.platform)
        if reasons:
            print("⚠️ 基线平台/方言不一致（%s），diff 结果仅供人工参考" % "、".join(reasons),
                  file=sys.stderr)
        print_pick(args.against, "file", payload)
        return 0

    for kind, name in (("last", "last_snapshot.json"), ("prev", "prev_snapshot.json")):
        path = os.path.join(args.log_dir, name)
        if not os.path.isfile(path):
            continue
        payload = load_payload(path)
        if payload is None:
            continue  # 不可解析 ⇒ 尝试下一个候选
        reasons = mismatch_reasons(payload, args.dialect, args.platform)
        if reasons:
            # 隐式基线是自动选择：错误基线会产出「以 rc=0 交付的假 diff」⇒ 直接落空
            print("⚠️ 隐式基线 %s 与本次快照不一致（%s），已跳过（不降级读 prev）"
                  % (kind, "、".join(reasons)), file=sys.stderr)
            return 1
        print_pick(path, kind, payload)
        return 0

    print("❌ 无可用基线（last/prev 均不存在或不可解析）", file=sys.stderr)
    return 1


def print_pick(path, kind, payload):
    age = age_of(payload)
    stale = 1 if (age is not None and age > STALE_AGE) else 0
    print("%s\t%s\t%s\t%d" % (path, kind, "-" if age is None else age, stale))


# ---------- 配对 ----------

def _round_keys(nodes, key_fn, used, usable):
    buckets = {}
    for idx, node in enumerate(nodes):
        if used[idx] or not usable[idx]:
            continue
        key = key_fn(node)
        if key is None:
            continue
        buckets.setdefault(key, []).append(idx)
    return buckets


def _identity(node):
    return (node.get("type") or "", node.get("text") or "",
            node.get("id") or "", node.get("bounds") or "")


def pair_nodes(old, new, dialect):
    """配对；返回 (pairs, only_old, only_new)。

    bounds 不可解析者不参与①②③（避免幽灵节点 `View||[]` 假配对），但先按「完全相等」配对一次
    ——相同记录必然是同一节点，否则完全相同的两份快照会报出幽灵 +/-。
    """
    old_usable = [parse_rect(node.get("bounds") or "", dialect) is not None for node in old]
    new_usable = [parse_rect(node.get("bounds") or "", dialect) is not None for node in new]
    old_used = [False] * len(old)
    new_used = [False] * len(new)
    pairs = []

    # 第 0 轮：bounds 不可解析者的完全相等配对
    buckets = {}
    for idx, node in enumerate(old):
        if not old_usable[idx]:
            buckets.setdefault(_identity(node), []).append(idx)
    for idx, node in enumerate(new):
        if new_usable[idx]:
            continue
        bucket = buckets.get(_identity(node))
        if not bucket:
            continue
        old_idx = bucket.pop(0)
        old_used[old_idx] = True
        new_used[idx] = True
        pairs.append((old_idx, idx))

    def key_id(node):
        node_id = node.get("id") or ""
        return (node.get("type") or "", node_id) if node_id else None

    def key_bounds(node):
        rect = parse_rect(node.get("bounds") or "", dialect)
        return None if rect is None else (node.get("type") or "", rect)

    def key_text(node):
        text = node.get("text") or ""
        return (node.get("type") or "", text) if text else None

    for key_fn in (key_id, key_bounds, key_text):
        buckets = _round_keys(old, key_fn, old_used, old_usable)
        if not buckets:
            continue
        for idx, node in enumerate(new):
            if new_used[idx] or not new_usable[idx]:
                continue
            key = key_fn(node)
            if key is None:
                continue
            bucket = buckets.get(key)
            if not bucket:
                continue
            old_idx = bucket.pop(0)
            old_used[old_idx] = True
            new_used[idx] = True
            pairs.append((old_idx, idx))

    only_old = [idx for idx in range(len(old)) if not old_used[idx]]
    only_new = [idx for idx in range(len(new)) if not new_used[idx]]
    return pairs, only_old, only_new


# ---------- 变化分类与渲染 ----------

def classify(old_node, new_node, dialect):
    """只报一类：text > pos（任一坐标差 > 2px）> clickable。"""
    if (old_node.get("text") or "") != (new_node.get("text") or ""):
        return "text"
    old_rect = parse_rect(old_node.get("bounds") or "", dialect)
    new_rect = parse_rect(new_node.get("bounds") or "", dialect)
    if old_rect is not None and new_rect is not None:
        if max(abs(a - b) for a, b in zip(old_rect, new_rect)) > POS_THRESHOLD:
            return "pos"
    if bool(old_node.get("clickable")) != bool(new_node.get("clickable")):
        return "clickable"
    return None


def build_entries(old, new, dialect):
    pairs, only_old, only_new = pair_nodes(old, new, dialect)
    entries = []
    for old_idx, new_idx in pairs:
        kind = classify(old[old_idx], new[new_idx], dialect)
        if kind is not None:
            entries.append((kind, old_idx, new_idx))
    for old_idx in only_old:
        entries.append(("-", old_idx, None))
    for new_idx in only_new:
        entries.append(("+", None, new_idx))
    return entries


def sort_key(entry, old, new, dialect):
    """+ → - → ~text → ~pos → ~clickable；同类按 y → x → 原索引；bounds 不可解析者置尾。"""
    kind, old_idx, new_idx = entry
    node = old[old_idx] if new_idx is None else new[new_idx]
    rect = parse_rect(node.get("bounds") or "", dialect)
    tie = old_idx if old_idx is not None else new_idx
    if rect is None:
        return (CLASS_ORDER[kind], 1, 0, 0, tie)
    return (CLASS_ORDER[kind], 0, rect[1], rect[0], tie)


def render(entry, old, new, dialect):
    kind, old_idx, new_idx = entry
    if kind == "+":
        node = new[new_idx]
        return "+\t%s\t%s\t%s\t%s" % (node.get("type") or "", node.get("text") or "",
                                      node.get("id") or "", node.get("bounds") or "")
    if kind == "-":
        node = old[old_idx]
        return "-\t%s\t%s\t%s\t%s" % (node.get("type") or "", node.get("text") or "",
                                      node.get("id") or "", node.get("bounds") or "")
    old_node, new_node = old[old_idx], new[new_idx]
    node_type = new_node.get("type") or ""
    node_id = new_node.get("id") or ""
    if kind == "text":
        return "~ text\t%s\t%s→%s\t%s\t%s" % (
            node_type,
            truncate(old_node.get("text") or "", TEXT_MAX),
            truncate(new_node.get("text") or "", TEXT_MAX),
            node_id,
            new_node.get("bounds") or "",
        )
    if kind == "pos":
        return "~ pos\t%s\t%s\t%s\t%s→%s" % (
            node_type, new_node.get("text") or "", node_id,
            old_node.get("bounds") or "", new_node.get("bounds") or "",
        )
    return "~ clickable\t%s\t%s\t%s\t%s\t%s→%s" % (
        node_type, new_node.get("text") or "", node_id, new_node.get("bounds") or "",
        "true" if old_node.get("clickable") else "false",
        "true" if new_node.get("clickable") else "false",
    )


def baseline_label(kind, age, path):
    if kind == "file":
        name = os.path.basename(path or "?")
        body = "file:%s(age=%s)" % (name, "-" if age is None else "%ds" % age)
    else:
        body = "%s(age=%s)" % (kind, "-" if age is None else "%ds" % age)
    if age is not None and age > STALE_AGE:
        body = body[:-1] + ",stale)"
    return body


def run_diff(args):
    baseline = load_payload(args.baseline)
    if baseline is None:
        print("❌ 基线不可解析: %s" % args.baseline, file=sys.stderr)
        return 1
    current = load_payload(args.current)
    if current is None:
        print("❌ 当前快照不可解析: %s" % args.current, file=sys.stderr)
        return 1

    dialect = current.get("dialect") or baseline.get("dialect") or "uiautomator"
    old, new = baseline["nodes"], current["nodes"]
    entries = build_entries(old, new, dialect)
    entries.sort(key=lambda entry: sort_key(entry, old, new, dialect))

    adds = sum(1 for entry in entries if entry[0] == "+")
    dels = sum(1 for entry in entries if entry[0] == "-")
    texts = sum(1 for entry in entries if entry[0] == "text")
    poses = sum(1 for entry in entries if entry[0] == "pos")
    clicks = sum(1 for entry in entries if entry[0] == "clickable")

    print("# diff baseline=%s fp=%s→%s nodes=%d: +%d -%d ~%d (text %d / pos %d / clickable %d)" % (
        baseline_label(args.baseline_kind, args.baseline_age, args.baseline),
        baseline.get("fingerprint") or "?",
        current.get("fingerprint") or "?",
        len(new), adds, dels, texts + poses + clicks, texts, poses, clicks,
    ))

    shown = entries[:args.max_diff]
    for entry in shown:
        print(render(entry, old, new, dialect))
    rest = len(entries) - len(shown)
    if rest > 0:
        print("另有 %d 项未显示（共 %d 项变化；--max-diff 调大可看全部）" % (rest, len(entries)))
    return 0


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--pick-baseline", action="store_true")
    parser.add_argument("--log-dir", default="build/debug")
    parser.add_argument("--platform", default="")
    parser.add_argument("--dialect", default="")
    parser.add_argument("--against", default="")
    parser.add_argument("--baseline", default="")
    parser.add_argument("--current", default="")
    parser.add_argument("--max-diff", type=int, default=DEFAULT_MAX_DIFF)
    parser.add_argument("--baseline-kind", default="last", choices=["last", "prev", "file"])
    parser.add_argument("--baseline-age", default="")
    args = parser.parse_args()

    if args.pick_baseline:
        return pick_baseline(args)

    if not args.baseline or not args.current:
        print("❌ 需要 --baseline 与 --current（或使用 --pick-baseline）", file=sys.stderr)
        return 2
    if args.max_diff <= 0:
        print("❌ --max-diff 必须为正整数", file=sys.stderr)
        return 2

    try:
        args.baseline_age = None if args.baseline_age in ("", "-") else int(args.baseline_age)
    except ValueError:
        print("❌ --baseline-age 必须为整数或 -", file=sys.stderr)
        return 2
    return run_diff(args)


if __name__ == "__main__":
    sys.exit(main())
