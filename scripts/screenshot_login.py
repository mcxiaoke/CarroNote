#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
登录页主题对比截图工具。

用法:
  python screenshot_login.py [round_name] [exe_path]

- round_name: 输出子目录名(默认 round1_opaque)，截图保存到
  temp/screenshots/<round_name>/<variant>.png
- exe_path: 可选，覆盖默认 safenotes.exe 路径

行为:
  对每个 DynamicSchemeVariant，启动 safenotes.exe(带 SN_DATA_DIR + SN_THEME_DSV
  环境变量)，等待登录页渲染后截图，再结束进程。无需重复打包。
"""

import os
import sys
import time
import ctypes
import subprocess

from pywinauto import Application

ROOT = r"C:\Home\Projects\safenotes"
EXE_DEFAULT = os.path.join(
    ROOT, "build", "windows", "x64", "runner", "Release", "safenotes.exe"
)
DATA_DIR = os.path.join(ROOT, "temp", "screenshots", "data")
OUT_ROOT = os.path.join(ROOT, "temp", "screenshots")

# 截图的 variant 列表(与 lib/utils/env_config.dart 的 _dsvByName 对应)
VARIANTS = ["tonalSpot", "monochrome", "neutral", "vibrant", "expressive", "fidelity"]

# 窗口标题匹配(应用名为 'CarroNote')
TITLE_RE = ".*CarroNote.*"

# 截图窗口尺寸：模拟手机竖屏，便于横向对比登录页布局
PHONE_WIDTH = 390
PHONE_HEIGHT = 844

# 启动后等待渲染的额外秒数(Flutter 首帧 + 登录页布局稳定)
RENDER_WAIT = 4.0
# 连接/可见超时
TIMEOUT = 40.0


def _get_hwnd(dlg):
    """获取窗口句柄，兼容 uia/win32 后端。"""
    try:
        return int(dlg.handle)
    except Exception:
        return ctypes.windll.user32.FindWindowW(None, "CarroNote")


def _resize_to_phone(dlg):
    """将窗口调整为手机竖屏尺寸并置于屏幕左上角附近。"""
    hwnd = _get_hwnd(dlg)
    if not hwnd:
        return
    user32 = ctypes.windll.user32
    SWP_NOZORDER = 0x0004
    SWP_SHOWWINDOW = 0x0040
    user32.SetWindowPos(
        hwnd,
        0,
        100,
        100,
        PHONE_WIDTH,
        PHONE_HEIGHT,
        SWP_NOZORDER | SWP_SHOWWINDOW,
    )


def capture_variant(exe, variant, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"{variant}.png")

    env = dict(os.environ)
    env["SN_DATA_DIR"] = DATA_DIR
    env["SN_THEME_DSV"] = variant

    print(f"[*] variant={variant}: launching exe with SN_THEME_DSV={variant}")
    proc = subprocess.Popen([exe], env=env)
    app = None
    try:
        app = Application(backend="uia").connect(
            process=proc.pid, timeout=TIMEOUT
        )
        dlg = app.window(title_re=TITLE_RE)
        dlg.wait("visible", timeout=TIMEOUT)
        _resize_to_phone(dlg)
        # 额外等待首帧渲染稳定
        time.sleep(RENDER_WAIT)
        img = dlg.capture_as_image()
        img.save(out_path)
        print(f"    -> saved {out_path} ({img.width}x{img.height})")
        return True
    except Exception as e:  # noqa: BLE001
        print(f"    !! failed for variant={variant}: {e}")
        return False
    finally:
        # 确保进程退出，避免残留窗口影响下一次截图
        try:
            if app is not None:
                app.window(title_re=TITLE_RE).close()
        except Exception:
            pass
        try:
            proc.terminate()
        except Exception:
            pass
        # 给一点时间优雅退出，否则强杀
        try:
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass


def main():
    round_name = sys.argv[1] if len(sys.argv) > 1 else "round1_opaque"
    exe = sys.argv[2] if len(sys.argv) > 2 else EXE_DEFAULT
    if not os.path.exists(exe):
        print(f"[!] exe not found: {exe}")
        sys.exit(1)

    out_dir = os.path.join(OUT_ROOT, round_name)
    print(f"=== round: {round_name}  out: {out_dir} ===")
    ok, fail = 0, 0
    for v in VARIANTS:
        if capture_variant(exe, v, out_dir):
            ok += 1
        else:
            fail += 1
        # 轮次之间稍作停顿，确保上一个进程完全退出
        time.sleep(2)
    print(f"=== done: {ok} ok, {fail} failed ===")


if __name__ == "__main__":
    main()
