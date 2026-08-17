#!/usr/bin/env python3
"""
从单张 2×2 图标合成图中分离出 4 个独立图标。

实现思路：
1. 将图片中非白色（允许阈值）的像素做成二值掩码；
2. 用 scipy.ndimage.label 做 8-连通域标记；
3. 取面积最大的 4 个连通域，按左上/右上/左下/右下排序；
4. 裁剪并保存。

假设：
- 4 个图标在白色背景上按 2×2 排列；
- 图标之间有明显的白色间隔；
- 输出保留原图内容，不做抠透明处理。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


def split_2x2_icons(image: Image.Image, white_threshold: int = 250, padding: int = 0) -> list[Image.Image]:
    """
    将 2×2 图标图切分为 4 张独立图标。
    返回顺序：左上、右上、左下、右下。
    """
    rgb = image.convert("RGB")
    arr = np.array(rgb)

    # 非白掩码：任意通道低于阈值即视为前景
    mask = np.any(arr < white_threshold, axis=2)

    # 8-连通域标记
    labeled, num_features = ndimage.label(mask, structure=np.ones((3, 3), dtype=int))

    if num_features < 4:
        raise ValueError(
            f"前景连通域只有 {num_features} 个，不足 4 个。"
            "请确认图片是白底 2×2 图标布局，或调低 --threshold。"
        )

    # 收集各连通域信息
    regions = []
    for label_id in range(1, num_features + 1):
        component = labeled == label_id
        area = int(component.sum())
        rows, cols = np.where(component)
        bbox = (int(cols.min()), int(rows.min()), int(cols.max()) + 1, int(rows.max()) + 1)
        regions.append((area, bbox))

    # 取面积最大的 4 个（图标主体）
    regions.sort(key=lambda x: x[0], reverse=True)
    top4 = regions[:4]

    # 按位置排序：先按中心 y 分上下两行，每行内按中心 x 分左右
    def center(item):
        _, (left, top, right, bottom) = item
        return ((top + bottom) / 2, (left + right) / 2)

    top4.sort(key=center)  # 先按 y 排序，得到上下两行
    top_row = sorted(top4[:2], key=lambda item: center(item)[1])  # 上行按 x 排序
    bottom_row = sorted(top4[2:], key=lambda item: center(item)[1])  # 下行按 x 排序
    top4 = top_row + bottom_row

    icons: list[Image.Image] = []
    for _, (left, top, right, bottom) in top4:
        icon = rgb.crop((left, top, right, bottom))
        if padding > 0:
            padded = Image.new("RGB", (icon.width + padding * 2, icon.height + padding * 2), (255, 255, 255))
            padded.paste(icon, (padding, padding))
            icon = padded
        icons.append(icon)

    return icons


def main() -> int:
    parser = argparse.ArgumentParser(description="将 2×2 排列的图标从白底图片中分离为 4 张独立图片。")
    parser.add_argument("input", type=Path, help="输入图片路径")
    parser.add_argument("-o", "--outdir", type=Path, default=None, help="输出目录（默认与输入图片同目录）")
    parser.add_argument("-p", "--prefix", type=str, default="icon", help="输出文件名前缀")
    parser.add_argument("--padding", type=int, default=0, help="裁剪后四周追加的白边像素")
    parser.add_argument("--threshold", type=int, default=250, help="白色背景判定阈值（0-255）")
    args = parser.parse_args()

    input_path: Path = args.input
    if not input_path.exists():
        print(f"错误：输入文件不存在：{input_path}", file=sys.stderr)
        return 1

    outdir: Path = args.outdir or input_path.parent
    outdir.mkdir(parents=True, exist_ok=True)

    try:
        with Image.open(input_path) as img:
            icons = split_2x2_icons(img, white_threshold=args.threshold, padding=args.padding)
    except Exception as exc:  # noqa: BLE001
        print(f"处理失败：{exc}", file=sys.stderr)
        return 1

    for i, icon in enumerate(icons, start=1):
        out_path = outdir / f"{args.prefix}_{i}.png"
        icon.save(out_path, "PNG")
        print(f"已保存：{out_path} ({icon.width}x{icon.height})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
