#!/usr/bin/env python3
"""_flow_index.py — 由 flows/*.json 全量重建 index.md（flow_save / flow_run 共用）

用法: python3 _flow_index.py <flows_dir>

为什么单独成文件：flow_save（固化）与 flow_run（回放后回写计数）都要刷新索引，
两处各写一份必然漂移（r2 复审条目 6 的同类风险）。

约定：
  · 只读 <flows_dir>/*.json；解析失败的文件跳过并在表尾列出（不删、不改）
  · 输出原子写（`.index.md.<pid>.tmp` + os.replace；pid 后缀防并发互踩同名临时文件）
  · 退出码：0 成功 / 2 用法错 / 3 目录不可写
"""
import json
import os
import sys
import time


def fmt_ts(ts):
    try:
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(int(ts))) if ts else "—"
    except Exception:
        return "—"


def main():
    if len(sys.argv) != 2:
        print("❌ 用法: _flow_index.py <flows_dir>", file=sys.stderr)
        return 2
    flows_dir = sys.argv[1]
    if not os.path.isdir(flows_dir):
        print("❌ 目录不存在: %s" % flows_dir, file=sys.stderr)
        return 3

    rows, broken = [], []
    for fn in sorted(os.listdir(flows_dir)):
        if not fn.endswith(".json"):
            continue
        p = os.path.join(flows_dir, fn)
        try:
            d = json.load(open(p, encoding="utf-8"))
            if not isinstance(d, dict):
                raise ValueError("top-level not object")
        except Exception:
            broken.append(fn)
            continue
        rows.append(d)

    lines = [
        "# 流程库（debug-loop 固化回放）",
        "",
        "> 由 `scripts/flow_save.sh` 自动维护，勿手改；回放用 `scripts/flow_run.sh --name <名>`。",
        "> A 级可免确认回放；B 级需用户确认（流程含坐标/危险词/放宽 profile/降级平台/无断言之一）。",
        "",
        "| 名 | 平台 | 级 | 设备 | 前提 | 最近成功 | 状态 |",
        "|---|---|---|---|---|---|---|",
    ]
    for d in rows:
        def cell(v):
            # 表格单元格转义：值里的 `|` 会切断 markdown 表格列
            return str(v if v is not None else "").replace("|", "\\|").replace("\n", " ").replace("\r", " ")
        lines.append("| %s | %s | %s | %s | %s | %s | %s |" % (
            cell(d.get("name", "?")), cell(d.get("platform", "?")), cell(d.get("grade", "?")),
            cell(d.get("device", "?") or "—"), cell(d.get("precond") or "—"),
            fmt_ts(d.get("last_success_at")), cell(d.get("status", "active"))))
    if broken:
        lines += ["", "> ⚠️ 无法解析的流程文件（已跳过）: " + ", ".join(broken)]

    tmp = os.path.join(flows_dir, ".index.md.%d.tmp" % os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        os.replace(tmp, os.path.join(flows_dir, "index.md"))
    except OSError as exc:
        print("❌ 无法写索引: %s" % exc, file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
