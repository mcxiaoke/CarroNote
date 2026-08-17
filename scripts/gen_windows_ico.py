#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一个正方形 PNG 生成为多尺寸复合 Windows .ico。

flutter_launcher_icons 的 Windows 生成器只能输出「单尺寸」.ico（见
https://github.com/fluttercommunity/flutter_launcher_icons/pull/651 仍未合并），
导致生成的 exe 在桌面/任务栏快捷方式上比别的程序「小一号」（Windows 只能从 256 缩放）。

本脚本弥补这一点：输入任意「正方形」PNG（建议 >= 256px，能覆盖到输出的最大 256 即可，
不必非得 1024），输出一个包含 16/24/32/48/64/128/256 的多尺寸 .ico，
可与 notepad++ 等程序一样在任意槽位取到精确尺寸。

依赖: Pillow (PIL)。本机托管 Python 已自带；若缺失：pip install Pillow

用法:
    # 基本：输入正方形 PNG，输出同名 .ico 到同一目录
    python scripts/gen_windows_ico.py assets/images/icon-round.png

    # 指定输出路径
    python scripts/gen_windows_ico.py assets/images/icon-round.png -o windows/runner/resources/app_icon.ico

    # 自定义尺寸集合（必须含 256，且 <=256 的会被写成 32bit BMP）
    python scripts/gen_windows_ico.py icon.png --sizes 16,32,48,256
"""
import argparse
import os
import struct
import sys

try:
    from PIL import Image
except ImportError:
    sys.stderr.write("缺少依赖 Pillow，请先安装：pip install Pillow\n")
    sys.exit(2)

DEFAULT_SIZES = [16, 24, 32, 48, 64, 128, 256]
MIN_RECOMMENDED = 256  # 输出最大为 256，输入至少 >=256 才不会被迫放大


def encode_bmp32(rgba: Image.Image) -> bytes:
    """把一个 RGBA 图像编码为一个 32bit 图标图像（BITMAPINFOHEADER + XOR + AND）。"""
    s = rgba.width
    assert rgba.height == s, "图像必须是正方形"
    px = rgba.load()
    xor = bytearray()
    and_row_bytes = ((s + 31) // 32) * 4
    andmask = bytearray()
    for y in range(s - 1, -1, -1):  # 自底向上
        row = bytearray()
        amask_row = bytearray(and_row_bytes)
        for x in range(s):
            r, g, b, a = px[x, y]
            row += bytes((b, g, r, a))
            if a == 0:  # 透明像素写入 1bpp AND 掩码
                amask_row[x // 8] |= (1 << (7 - (x % 8)))
        xor += row
        andmask += amask_row
    bih = struct.pack(
        "<IiiHHIIiiII",
        40,   # biSize
        s,    # biWidth
        s * 2,  # biHeight（含 XOR 上半 + AND 下半）
        1,    # biPlanes
        32,   # biBitCount
        0,    # biCompression (BI_RGB)
        len(xor) + len(andmask),  # biSizeImage
        0, 0, 0, 0,
    )
    return bih + xor + andmask


def build_ico(src: Image.Image, sizes) -> bytes:
    entries = []
    images = []
    for s in sizes:
        f = src.resize((s, s), Image.LANCZOS)
        data = encode_bmp32(f.convert("RGBA"))
        entries.append((s, data))
        images.append(data)
    out = bytearray(struct.pack("<HHH", 0, 1, len(entries)))
    offset = 6 + len(entries) * 16
    for (s, data) in entries:
        w = 0 if s == 256 else s  # .ico 中 256 宽高必须记 0
        out += struct.pack("<BBBBHHII", w, w, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    for data in images:
        out += data
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(
        description="把正方形 PNG 生成为多尺寸 Windows .ico")
    ap.add_argument("input", help="输入的正方形 PNG 路径（建议 >= 256px）")
    ap.add_argument("-o", "--output", default=None,
                    help="输出 .ico 路径（默认：输入文件同目录、同名 .ico）")
    ap.add_argument("--sizes", default=None,
                    help="逗号分隔的尺寸列表，如 16,32,48,256（默认含标准 7 档）")
    args = ap.parse_args()

    if not os.path.isfile(args.input):
        sys.stderr.write("输入文件不存在：%s\n" % args.input)
        sys.exit(1)

    if args.sizes:
        try:
            sizes = [int(x) for x in args.sizes.split(",") if x.strip()]
        except ValueError:
            sys.stderr.write("--sizes 必须是逗号分隔的整数，如 16,32,48,256\n")
            sys.exit(1)
    else:
        sizes = list(DEFAULT_SIZES)

    if 256 not in sizes:
        sys.stderr.write("警告：标准 Windows 图标必须包含 256，已自动补上。\n")
        sizes = sorted(set(sizes + [256]))
    sizes = sorted(set(sizes))

    img = Image.open(args.input).convert("RGBA")
    w, h = img.size
    if w != h:
        sys.stderr.write("错误：输入必须是正方形，当前为 %dx%d\n" % (w, h))
        sys.exit(1)
    if min(w, h) < MIN_RECOMMENDED:
        sys.stderr.write(
            "警告：输入较短边为 %dpx（建议 >= %d），输出 256 尺寸将被放大，可能发虚。\n"
            % (min(w, h), MIN_RECOMMENDED))

    out_path = args.output or (os.path.splitext(args.input)[0] + ".ico")
    out_path = os.path.abspath(out_path)

    data = build_ico(img, sizes)
    with open(out_path, "wb") as fp:
        fp.write(data)

    print("已生成多尺寸 .ico：%s" % out_path)
    print("包含尺寸：%s" % ", ".join("%dx%d" % (s, s) for s in sizes))
    print("文件大小：%d 字节" % len(data))


if __name__ == "__main__":
    main()
