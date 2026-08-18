#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
copyright.py — 为缺失 license header 的源文件批量补充头部声明。

设计要点
--------
1. 宽松检测（不写死某一种协议）：
   只检查文件「顶部注释块」里是否出现 license / spdx / copyright（不区分大小写）。
   命中即视为「已带 license 声明」，跳过，绝不重复写入。
   从别处 copy 进来的 MIT / BSD / Apache / GPL / 其它协议头（形如
   `// Copyright (c) ...`、`/// Copyright 2013 Google`、`// SPDX-License-Identifier: ...`）
   都能被正确识别，不会重复叠加。
   顶部注释块内部的空行、首行之前的空行一律忽略（兼容头部带空行或 // 风格注释的文件）。

2. 幂等：跑一次或多次结果一致，不会重复叠加头部。

3. 安全：
   - 默认只做 dry-run（打印将要改哪些文件），加 --write 才真正落盘；
   - --check 用于 CI（发现缺失即非零退出）。

4. 兼容特殊首行：
   保留 #! 脚本行与 // @dart= 语言版本注释，把 license 头插在它们「之后」。

5. 目录必须显式指定（相对如 `lib`、`.`，或绝对路径），不默认扫全仓。

6. 多语言：默认处理 .dart/.js/.go/.ts/.tsx/.java（均使用 /* */ 块注释，与本项目
   GPL-3.0 头兼容）；用 --ext 可追加其它扩展名。自动忽略 node_modules / vendor /
   .dart_tool / build / temp / coverage 等目录，绝不碰第三方依赖。

用法
----
    python scripts/copyright.py lib packages          # dry-run
    python scripts/copyright.py lib --write          # 真正写入
    python scripts/copyright.py . --check            # CI 检查
    python scripts/copyright.py server --ext .go .js # 只处理 go/js
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

# ---- 规范的 license 头（与 lib/main.dart、lib/app.dart 保持一致）----
# 使用 /* */ 块注释，对所有启用扩展名的语言（dart/js/go/ts/java...）均合法。
LICENSE_HEADER = """/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/"""

# 顶部注释块中出现以下任一关键字即视为「已有 license 声明」（宽松匹配）
LICENSE_KEYWORDS = ("license", "spdx", "copyright")

# 默认处理的扩展名（均兼容 /* */ 块注释）
DEFAULT_EXTS = (".dart", ".js", ".go", ".ts", ".tsx", ".java")

# 扫描时忽略的目录（构建 / 缓存 / 依赖）；node_modules、vendor 等第三方代码绝不碰
EXCLUDE_DIRS = {
    ".git", ".dart_tool", ".pub-cache", "build", "temp", "coverage",
    "node_modules", "vendor", "bower_components", ".idea", ".vscode",
    "dist", "out", ".cache",
}

# 默认跳过的代码生成产物（可用 --all 关闭）
GENERATED_PATTERNS = (
    "*.g.dart", "*.freezed.dart", "*.gr.dart", "*.config.dart",
    "*.generated.*", "*.gen.*", "*.min.js", "*.pb.go", "*.pb.js", "*.pb.ts",
)


def _split_preamble(lines):
    """返回前置行（#! 与 // @dart=）之后的索引；首行之前的空行不计入 preamble。"""
    i = 0
    if lines and lines[0].lstrip().startswith("#!"):
        i = 1
        while i < len(lines) and lines[i].strip() == "":
            i += 1
        if i < len(lines) and re.match(r"\s*//\s*@dart", lines[i]):
            i += 1
    return i


def extract_leading_comment(text: str) -> str:
    """提取文件开头的连续注释块（块注释 /* */ 或行注释 //，含 ///）。

    规则：
    - 跳过首行之前的空行；
    - 注释块内部的空行透明跳过（继续往后找注释）；
    - 遇到首个非注释、非空行即停止。
    """
    lines = text.splitlines()
    i = _split_preamble(lines)
    # 跳过顶部可能存在的空行
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    buf = []
    in_block = False
    n = len(lines)
    while i < n:
        line = lines[i]
        s = line.strip()
        if in_block:
            buf.append(line)
            i += 1
            if "*/" in line:
                in_block = False
            continue
        if s.startswith("/*"):
            in_block = True
            buf.append(line)
            i += 1
            if "*/" in line:
                in_block = False
            continue
        if s.startswith("//"):  # 兼容 // 与 /// 文档注释
            buf.append(line)
            i += 1
            continue
        if s == "":  # 头部注释块内部的空行：透明跳过
            i += 1
            continue
        break
    return "\n".join(buf)


def has_license_header(text: str) -> bool:
    head = extract_leading_comment(text).lower()
    return any(kw in head for kw in LICENSE_KEYWORDS)


def _glob_match(name: str, pat: str) -> bool:
    if pat.startswith("*"):
        return name.endswith(pat[1:])
    return name == pat


def is_generated(path: Path) -> bool:
    """判断是否为代码生成产物（默认跳过）。"""
    name = path.name
    if name.startswith("generated_"):
        return True
    if any(part == "generated" for part in path.parts):
        return True
    return any(_glob_match(name, pat) for pat in GENERATED_PATTERNS)


def iter_files(roots, exts):
    exts = {e.lower() for e in exts}
    for root in roots:
        root = Path(root)
        if root.is_file():
            if root.suffix.lower() in exts:
                yield root
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            # 原地剪枝：跳过构建 / 缓存 / 依赖目录
            dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS]
            for fn in filenames:
                if Path(fn).suffix.lower() in exts:
                    yield Path(dirpath) / fn


def apply_header(raw: bytes) -> bytes:
    """在保留 #! / // @dart= 前置行的前提下，把 license 头插到最前面。

    关键：按字节原样保留 body，绝不改动其行尾；license 头使用与原文件相同的行尾，
    因此 git diff 只会显示新增的头部几行，而非整个文件（避免 write_text 在 Windows
    上把 \\n 全部转成 \\r\\n 导致整文件被判为 modified 的问题）。
    """
    eol = b"\r\n" if b"\r\n" in raw else b"\n"
    # 用逻辑行定位 preamble 结束位置（#! 与 // @dart=）
    text_lines = raw.decode("utf-8", "replace").split("\n")
    i = _split_preamble(text_lines)
    # 按原文件行尾切分字节，取 body 部分（原样保留，含/不含末尾换行由 split 自动还原）
    raw_lines = raw.split(eol)
    preamble_raw = eol.join(raw_lines[:i])
    body_raw = eol.join(raw_lines[i:])
    # 去掉 body 开头多余空行，保证头与代码之间正好一个空行
    while body_raw.startswith(eol):
        body_raw = body_raw[len(eol):]
    header_bytes = LICENSE_HEADER.replace("\n", eol.decode()).encode("utf-8")
    if preamble_raw:
        return preamble_raw + eol + header_bytes + eol + eol + body_raw
    return header_bytes + eol + eol + body_raw


def main() -> int:
    ap = argparse.ArgumentParser(
        description="为缺失 license header 的源文件补充头部声明"
    )
    ap.add_argument(
        "paths", nargs="+",
        help="要扫描的目录/文件（相对如 lib/. 或绝对路径），至少指定一个，不默认全仓",
    )
    ap.add_argument(
        "--ext", nargs="+", default=list(DEFAULT_EXTS), metavar="EXT",
        help=f"处理的文件扩展名（默认：{' '.join(DEFAULT_EXTS)}）",
    )
    ap.add_argument("--write", action="store_true", help="真正写入文件（默认仅 dry-run）")
    ap.add_argument("--check", action="store_true", help="检查模式：发现缺失返回退出码 1")
    ap.add_argument("--all", action="store_true", help="不过滤代码生成产物")
    ap.add_argument("--verbose", action="store_true", help="打印每个被处理的文件")
    args = ap.parse_args()

    roots = [Path(p) for p in args.paths]
    exts = list(args.ext)

    scanned = skipped_gen = already = to_write = written = errors = 0
    missing_files: list[Path] = []

    for path in iter_files(roots, exts):
        scanned += 1
        if not args.all and is_generated(path):
            skipped_gen += 1
            if args.verbose:
                print(f"[skip:generated] {path}")
            continue
        try:
            raw = path.read_bytes()
        except Exception as e:  # noqa: BLE001
            errors += 1
            print(f"[error] 读取失败 {path}: {e}", file=sys.stderr)
            continue

        if has_license_header(raw.decode("utf-8-sig", "replace")):
            already += 1
            continue

        to_write += 1
        missing_files.append(path)
        if args.verbose:
            print(f"[need ] {path}")

        if args.write:
            try:
                path.write_bytes(apply_header(raw))
                written += 1
            except Exception as e:  # noqa: BLE001
                errors += 1
                print(f"[error] 写入失败 {path}: {e}", file=sys.stderr)

    print("\n==== 统计 ====")
    print(f"扫描文件 (.{'/'.join(exts)}) : {scanned}")
    print(f"跳过(生成产物): {skipped_gen}")
    print(f"已有 license  : {already}")
    print(f"需要补充      : {to_write}")
    if args.write:
        print(f"本次写入      : {written}")
    print(f"出错          : {errors}")
    if not args.write and to_write:
        print("\n（dry-run，未实际修改。加 --write 执行写入；加 --all 包含生成产物）")

    if args.check:
        if missing_files:
            print(
                f"\n[check] 发现 {len(missing_files)} 个文件缺失 license header",
                file=sys.stderr,
            )
            return 1
        print("[check] 所有文件均已带 license header ✓")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
