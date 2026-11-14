#!/usr/bin/env python3
"""_secret.py — debug-loop 凭据文件解析唯一实现（扁平 KEY=VALUE + [acct:<名字>] 账号组）。

为什么单一实现：android/input.sh 的 read_secret 与 appium/driver.py 的 _load_text_source
曾各写一套扁平解析，语义已出现分叉（单行无 "=" 回退只在 Python 侧）。多账号必须只有一份
解析器，否则「账号组」会成为第三套。后续 maestro/flow 若要接凭据文件，也只许复用本文件。

用法:
  python3 _secret.py get  --file <凭据文件> [--account 名字] [--key 角色]
  python3 _secret.py list --file <凭据文件>

语义（与历史行为对齐）:
  扁平模式（无 --account）: 只看账号组之外的行；键名删除全部空白；首个 `KEY=` 命中或第一行值；
                            首个 "=" 切分（值可含 "="）；单行且无 "=" ⇒ 整行作值（driver 旧用法）。
  账号组模式: `[acct:<名字>]` 起一个组，组内 `KEY=VALUE`；--key 缺省 ACCOUNT；角色名精确匹配。

安全纪律:
  - 只往 stdout 打值，不落临时文件、不写日志；错误信息只提组名/角色名，不提值。
  - 文件权限只拒 group/other 位（644/640 拒；0400/0700 放行），与 driver.py 历史行为一致。
  - 退出码固定 2（用法/凭据问题），未预期异常同样折算 2，避免被调用方当成「未找到」。
"""
import argparse
import os
import re
import sys

GROUP_RE = re.compile(r"^\[acct:([^\]]+)\]\s*$")
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


class SecretError(Exception):
    """凭据文件语义错误（调用方统一映射成 rc=2）。"""


def _read_lines(path):
    try:
        st = os.stat(path)
    except OSError:
        raise SecretError(f"凭据文件不存在: {path}（先由人工创建，勿入库）") from None
    if st.st_mode & 0o077:
        raise SecretError(
            f"凭据文件权限为 {oct(st.st_mode & 0o777)[2:]}，要求 600：chmod 600 {path}"
        )
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        raise SecretError(f"凭据读取失败: {exc}") from None
    return [ln.rstrip("\r") for ln in raw.splitlines()], st


def parse_lines(lines):
    """→ (flat, groups)。组内畸形行/重复键 fail-closed（组内值可能含密，报错不带行内容）。"""
    flat, groups, current, current_name = [], {}, None, ""
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = GROUP_RE.match(line)
        if m:
            name = m.group(1).strip()
            if not NAME_RE.match(name):
                raise SecretError(f"账号组名非法: '{name}'（允许 A-Z a-z 0-9 _ . -）")
            if name in groups:
                raise SecretError(f"账号组重复定义: '{name}'（同文件只允许一组）")
            groups[name] = {}
            current, current_name = groups[name], name
            continue
        if current is not None:
            if "=" not in line:
                raise SecretError(f"账号组 '{current_name}' 内有无法解析的行（缺少 =）")
            k, v = line.split("=", 1)
            k = re.sub(r"\s+", "", k)
            if k in current:
                raise SecretError(f"账号组 '{current_name}' 内 KEY={k} 重复定义")
            current[k] = v
            continue
        if "=" not in line:
            # 扁平模式的历史兼容：单行无 "=" 由调用方按整行取值；这里先原样收进 flat
            flat.append(("\x00raw", line))
            continue
        k, v = line.split("=", 1)
        flat.append((re.sub(r"\s+", "", k), v))
    return flat, groups


def parse(path):
    """→ (flat: list[tuple[str, str]], groups: dict[str, dict[str, str]])。"""
    lines, _ = _read_lines(path)
    return parse_lines(lines)


def _flat_lookup(flat, key):
    """扁平取值：指定 key 精确匹配；未指定取第一条（无 "=" 的行整行作值，沿 driver 旧语义）。"""
    if key:
        for k, v in flat:
            if k == key:
                return v
        raise SecretError(f"凭据文件里没有可用的 KEY=VALUE（--key '{key}'）")
    if not flat:
        raise SecretError("凭据文件里没有可用的 KEY=VALUE")
    return flat[0][1]


def _lookup(flat, groups, account, key):
    if not account:
        return _flat_lookup(flat, key)
    if account not in groups:
        avail = ", ".join(sorted(groups)) or "（无）"
        raise SecretError(f"账号组 '{account}' 不存在；可用组: {avail}")
    role = key or "ACCOUNT"
    group = groups[account]
    if role not in group:
        avail = ", ".join(sorted(group)) or "（无）"
        raise SecretError(f"账号组 '{account}' 里没有 KEY={role}；可用角色: {avail}")
    return group[role]


def load(path, account=None, key=None):
    """取单值（文件）；失败抛 SecretError。"""
    if path == "-":
        raise SecretError("文件路径不能是 -（stdin 请走 load_text）")
    flat, groups = parse(path)
    return _lookup(flat, groups, account, key)


def load_text(raw, account=None, key=None):
    """从 stdin 原文取值（与文件路径同一套扁平/分组语义）。"""
    lines = [ln.rstrip("\r") for ln in raw.splitlines()]
    flat, groups = parse_lines(lines)
    return _lookup(flat, groups, account, key)


def list_accounts(path):
    """→ 每行 `<组名>\t<角色,...>`；只列名字，不含值。"""
    _, groups = parse(path)
    for name in sorted(groups):
        yield f"{name}\t{','.join(sorted(groups[name]))}"


def main():
    p = argparse.ArgumentParser(description="debug-loop 凭据解析（扁平 KEY=VALUE + [acct:名字] 组）")
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("get", help="取一个值（stdout，无换行）")
    g.add_argument("--file", required=True)
    g.add_argument("--account", default="")
    g.add_argument("--key", default="")
    lst = sub.add_parser("list", help="列账号组与角色（不含值）")
    lst.add_argument("--file", required=True)
    args = p.parse_args()
    try:
        if args.cmd == "get":
            value = load(args.file, args.account or None, args.key or None)
            sys.stdout.write(value)
            sys.stdout.flush()
            return 0
        for line in list_accounts(args.file):
            print(line)
        return 0
    except SecretError as exc:
        print(f"❌ {exc}", file=sys.stderr)
        return 2
    except Exception as exc:  # noqa: BLE001  未预期异常也折算 2，绝不落成「未找到」
        print(f"❌ 凭据读取失败: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())