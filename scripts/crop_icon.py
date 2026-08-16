#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""将大于 1024x1024 的 PNG 图标居中裁剪为 1024x1024。

如果输入的 PNG 宽或高大于 1024，则从四周居中裁掉超出部分，
生成一个新的 1024x1024 PNG，文件名为 <原名>_ic.png。

用法:
    python scripts/crop_icon.py <输入.png> [--out-dir <输出目录>]

    # 处理单个文件（输出默认与输入同目录）
    python scripts/crop_icon.py assets/images/icon_with_space.png

    # 指定输出目录
    python scripts/crop_icon.py assets/images/icon_with_space.png --out-dir assets/images

    # 批量处理目录内所有 PNG（输出默认在同目录）
    python scripts/crop_icon.py assets/images

依赖: Pillow  (pip install Pillow)
"""

import argparse
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.stderr.write("错误: 需要 Pillow 库，请先运行: pip install Pillow\n")
    sys.exit(2)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

TARGET = 1024


def crop_one(src_path, out_dir):
    """裁剪单个 PNG。无需裁剪或无规则文件时返回 None。"""
    if not os.path.isfile(src_path):
        print(f"跳过(不存在): {src_path}")
        return None
    try:
        with Image.open(src_path) as im:
            im = im.convert("RGBA")
            w, h = im.size
    except Exception as e:  # noqa: BLE001
        print(f"跳过(无法读取 {src_path}): {e}")
        return None

    if w <= TARGET and h <= TARGET:
        print(f"无需裁剪(已 <= {TARGET}): {src_path} ({w}x{h})")
        return None

    # 居中裁剪框：四周各裁掉 (尺寸-1024)//2 像素
    left = (w - TARGET) // 2
    top = (h - TARGET) // 2
    right = left + TARGET
    bottom = top + TARGET
    cropped = im.crop((left, top, right, bottom))

    stem, _ = os.path.splitext(os.path.basename(src_path))
    out_name = f"{stem}_ic.png"
    out_path = os.path.join(out_dir, out_name)
    os.makedirs(out_dir, exist_ok=True)
    cropped.save(out_path, "PNG")
    print(
        f"已生成: {out_path}  "
        f"(从 {w}x{h} 居中裁掉四周 左{left}/上{top}/右{w-right}/下{h-bottom} 像素)"
    )
    return out_path


def main():
    parser = argparse.ArgumentParser(
        description=f"将 >{TARGET}x{TARGET} 的 PNG 图标居中裁剪为 {TARGET}x{TARGET} (输出后缀 _ic)"
    )
    parser.add_argument("path", help="输入 PNG 文件或目录")
    parser.add_argument(
        "--out-dir",
        default=None,
        help="输出目录(默认: 单文件=输入同目录, 目录=该目录)",
    )
    args = parser.parse_args()

    if os.path.isdir(args.path):
        out_dir = args.out_dir or args.path
        targets = [
            os.path.join(args.path, f)
            for f in sorted(os.listdir(args.path))
            if f.lower().endswith(".png")
        ]
        if not targets:
            print(f"目录内无 PNG: {args.path}")
            return
        results = [crop_one(t, out_dir) for t in targets]
        made = sum(1 for r in results if r is not None)
        print(f"处理完成: {made}/{len(targets)} 个文件已生成到 {out_dir}")
    else:
        out_dir = args.out_dir or os.path.dirname(os.path.abspath(args.path))
        crop_one(args.path, out_dir)


if __name__ == "__main__":
    main()
