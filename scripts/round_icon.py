#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给一张图片加圆角，输出到原文件夹，命名为 <原名>-rounded.png。

只做一件事：按圆角比例把图片四角裁成圆角（其余像素原样保留）。

用法:
  python scripts/round_icon.py <图片路径> [--ratio 0.22] [--out 输出路径]

参数:
  --ratio  圆角半径占短边比例（0 ~ 0.5）。0 = 直角，0.5 = 圆角到极限（竖边变半圆）。
            默认 0.22，近似 iOS App 图标观感。
  --out    可选，指定输出路径；默认写到输入同目录，文件名为 <原名>-rounded.<原扩展名>。
"""

import argparse
import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.stderr.write("错误: 需要 Pillow，请先运行: pip install Pillow\n")
    sys.exit(2)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")


def make_rounded_icon(src, ratio=0.22):
    """给图片加圆角。

    src  : PIL.Image（任意尺寸、任意模式，内部转 RGBA）
    ratio: 圆角半径 / 短边 的比例
    返回  : 加了圆角的 RGBA 图片，尺寸与输入一致。
    """
    if not (0.0 <= ratio <= 0.5):
        raise ValueError(f"ratio 必须在 0~0.5 之间，收到 {ratio}")

    img = src.convert("RGBA")
    w, h = img.size
    r = int(min(w, h) * ratio)

    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=255)

    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def main():
    parser = argparse.ArgumentParser(description="给图片加圆角，输出 <原名>-rounded。")
    parser.add_argument("input", help="输入图片路径")
    parser.add_argument("--ratio", type=float, default=0.22, help="圆角半径占短边比例（默认 0.22）")
    parser.add_argument("--out", type=str, default=None, help="输出路径（默认: <原名>-rounded.<ext>）")
    args = parser.parse_args()

    inp = os.path.abspath(args.input)
    if not os.path.isfile(inp):
        sys.stderr.write(f"输入文件不存在: {inp}\n")
        sys.exit(1)

    with Image.open(inp) as im:
        rounded = make_rounded_icon(im, args.ratio)

    if args.out:
        out_path = os.path.abspath(args.out)
    else:
        base, ext = os.path.splitext(inp)
        ext = ext or ".png"
        out_path = f"{base}-rounded{ext}"

    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    rounded.save(out_path, "PNG")
    print(f"已生成: {out_path} ({rounded.width}x{rounded.height}, radius={int(min(rounded.size) * args.ratio)})")


if __name__ == "__main__":
    main()
