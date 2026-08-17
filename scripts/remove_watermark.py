#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
去除 temp/generated_icons 中图标右下角的 AI 生成水印（"AI生成" + "WORKBUDDY"）。

方法（对纯色 / 渐变背景都安全，且不依赖水印像素级位置，也不误伤主体）：
1. 只在「右下角安全区」(默认 x∈[0.85,1.0], y∈[0.90,1.0]) 内处理。
   插画主体不会延伸到 0.85 之后的角落，水印文字固定在极角，二者不冲突。
2. 用「高斯模糊」估计背景：把整张图做轻度高斯模糊，模糊会保留平滑的背景
   (纯色或渐变)，却把水印文字这种高频细节抹平 → 得到「本该的背景图」。
3. 逐像素比较：与模糊背景差异大 → 判定为水印文字 → 直接用「模糊背景值」覆盖。
   - 纯色背景：填纯色；渐变背景：填该处渐变值。笔画内外、抗锯齿都能准确识别。
4. 白底白字（水印本就不可见）的图，文字与模糊背景差异极小 → 不改动，原样保留。

用法：
    python scripts/remove_watermark.py
    python scripts/remove_watermark.py --src <输入> --dst <输出> \
        [--zone 0.85 0.90] [--radius 6] [--thr 40]

依赖：Pillow
"""

import argparse
import os
import sys
from concurrent.futures import ThreadPoolExecutor

try:
    from PIL import Image, ImageFilter
except ImportError:
    sys.exit("需要 Pillow: pip install pillow")


def process_file(path, dst_dir, rx0, ry0, radius, thr):
    name = os.path.basename(path)
    im = Image.open(path).convert("RGB")
    w, h = im.size

    x0, y0 = int(w * rx0), int(h * ry0)
    x1, y1 = w, h
    if x1 - x0 < 4 or y1 - y0 < 4:
        im.save(os.path.join(dst_dir, name))
        return name, "skipped(region too small)", 0

    # 整图高斯模糊 → 背景估计
    blur_im = im.filter(ImageFilter.GaussianBlur(radius=radius))
    bp = blur_im.load()
    px = im.load()

    changed = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            c = px[x, y]
            b = bp[x, y]
            d = ((c[0] - b[0]) ** 2 + (c[1] - b[1]) ** 2 + (c[2] - b[2]) ** 2) ** 0.5
            if d > thr:
                px[x, y] = b
                changed += 1

    im.save(os.path.join(dst_dir, name))
    if changed < 30:
        return name, f"skipped(clean, px={changed})", changed
    return name, f"cleaned px={changed}", changed


def main():
    ap = argparse.ArgumentParser(description="去除图标右下角 AI 生成水印")
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    ap.add_argument("--src", default=os.path.join(root, "temp", "generated_icons"))
    ap.add_argument("--dst", default=os.path.join(root, "temp", "generated_icons_clean"))
    ap.add_argument("--zone", nargs=2, type=float, default=[0.85, 0.90],
                    metavar=("RX0", "RY0"), help="水印区左/上边界(宽/高比例)")
    ap.add_argument("--radius", type=float, default=6, help="高斯模糊半径")
    ap.add_argument("--thr", type=float, default=40, help="与模糊背景的差异阈值")
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()

    if not os.path.isdir(args.src):
        sys.exit(f"输入目录不存在: {args.src}")
    os.makedirs(args.dst, exist_ok=True)

    files = sorted(
        os.path.join(args.src, f)
        for f in os.listdir(args.src)
        if f.lower().endswith((".png", ".jpg", ".jpeg", ".webp", ".bmp"))
    )
    if not files:
        sys.exit("输入目录没有图片文件")

    rx0, ry0 = args.zone
    print(f"输入: {args.src}  ({len(files)} 张)")
    print(f"输出: {args.dst}")
    print(f"参数: 水印区 x>={rx0}, y>={ry0}, 模糊半径={args.radius}, 阈值={args.thr}")

    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = [ex.submit(process_file, p, args.dst, rx0, ry0, args.radius, args.thr)
                for p in files]
        for f in futs:
            results.append(f.result())

    cleaned = sum(1 for _, s, _ in results if s.startswith("cleaned"))
    skipped = sum(1 for _, s, _ in results if s.startswith("skipped"))
    for name, status, _ in results:
        print(f"  [{status.split()[0]:7}] {name:45} {status}")
    print(f"\n完成: 清理 {cleaned} 张, 跳过 {skipped} 张, 共 {len(results)} 张")


if __name__ == "__main__":
    main()
