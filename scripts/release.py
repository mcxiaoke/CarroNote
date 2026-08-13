#
# Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# You may use, distribute and modify this code under the
# terms of the GPL-3.0+ license.
#
# You should have received a copy of the GNU General Public License v3.0 with
# this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
#
# See https://safenotes.dev for support or download.
#
# GitHub Release packaging: builds Android APKs + Windows desktop, then packs
# them into zip archives with a SHA256SUMS checksum file. App Store AAB is NOT
# built here — this fork only publishes Windows + Android binaries via GitHub
# Release.
#

import hashlib
import re
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APK_RELEASE_DIR = ROOT / "build" / "app" / "outputs" / "apk" / "release"
WIN_RELEASE_DIR = ROOT / "build" / "windows" / "x64" / "runner" / "Release"


def run(cmd: str, *, check: bool = True):
    """在项目根目录执行 shell 命令（脚本需从项目根运行，路径均用 ROOT 锚定）。"""
    print(f"-> {cmd}")
    ret = subprocess.run(cmd, shell=True, cwd=str(ROOT), check=False).returncode
    if check and ret != 0:
        raise SystemExit(f"命令执行失败（exit {ret}）：{cmd}")


def get_destination():
    """
    解析 pubspec.yaml 版本号并创建 releases/<version>/github 产物目录。

    Returns:
        github (Path): GitHub Release 产物目录。
        version (str): 语义化版本号，如 "3.0.0"。
    """
    pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(r"version:\s*([0-9][0-9.]*)\+(\d+)", pubspec)
    if m is None:
        raise SystemExit("无法从 pubspec.yaml 解析 version（需形如 'version: x.y.z+<build>'）")
    version = m.group(1)

    github = (ROOT / "releases" / version / "github").resolve()
    github.mkdir(parents=True, exist_ok=True)
    return github, version


def generate_build_info():
    """构建前注入最新 Git 提交信息与构建时间，确保产物携带准确版本元数据。"""
    script = ROOT / "scripts" / "generate_build_info.py"
    print("-> 生成构建信息（git hash + 构建时间）")
    run(f"python \"{script}\"")


def copy_apk(src: str, dst: str, newdir: Path):
    """把 release APK 构建产物复制到 GitHub Release 目录。"""
    source = APK_RELEASE_DIR / src
    if not source.exists():
        raise SystemExit(f"APK 产物缺失：{source}")
    shutil.copy2(src=str(source), dst=str(newdir / dst))
    print(f"-> {newdir / dst}")


def zip_windows(github: Path, version: str):
    """
    把整个 Windows Release 目录（safenotes.exe + 各插件 DLL + data/）打包成 zip。
    只复制单个 exe 无法运行——Flutter Windows 应用依赖同目录下的 DLL 与资源。
    排除运行时生成的 logs/ 目录。
    """
    src = WIN_RELEASE_DIR
    if not (src / "safenotes.exe").exists():
        raise SystemExit(f"Windows 构建产物缺失：{src / 'safenotes.exe'}")
    dst = github / f"safenotes-{version}-windows-x64.zip"
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(src.rglob("*")):
            if f.is_dir():
                continue
            rel = f.relative_to(src).as_posix()
            if rel.startswith("logs/"):
                continue
            zf.write(f, rel)
    size_mb = dst.stat().st_size / 1024 / 1024
    print(f"-> {dst.name}（{size_mb:.1f} MB）")


def zip_android(github: Path, version: str):
    """把全部 Android APK + metadata 汇总打成一个 android zip。"""
    dst = github / f"safenotes-{version}-android.zip"
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(github.glob(f"safenotes-{version}-*.apk")):
            zf.write(f, f.name)
        for f in sorted(github.glob(f"metadata-{version}-*.json")):
            zf.write(f, f.name)
    size_mb = dst.stat().st_size / 1024 / 1024
    print(f"-> {dst.name}（{size_mb:.1f} MB）")


def write_sha256(github: Path):
    """为 Release 目录内所有产物生成 SHA256 校验清单，供下载后核验完整性。"""
    dst = github / "SHA256SUMS.txt"
    with open(dst, "w", encoding="utf-8") as out:
        for f in sorted(github.iterdir()):
            if not f.is_file():
                continue
            if f.suffix.lower() not in (".zip", ".apk", ".json"):
                continue
            digest = hashlib.sha256(f.read_bytes()).hexdigest()
            out.write(f"{digest}  {f.name}\n")
    print(f"-> {dst.name}")


def make_release():
    """
    完整发布打包流程：
      1. 注入构建信息；
      2. 构建 Android 分 ABI APK（arm / arm64 / x64）+ 全 ABI fat APK；
      3. 构建 Windows desktop，打包整目录 zip（排除 logs/）；
      4. 汇总 android zip + SHA256SUMS.txt。
    产物统一输出到 releases/<version>/github/，用 `gh release create` 上传。
    """
    github, version = get_destination()

    generate_build_info()
    run("flutter clean && flutter pub get")

    # ① Android 分 ABI APK（体积最小，GitHub Release 首选）
    run(
        "flutter build apk --release --split-per-abi "
        "--target-platform android-arm,android-arm64,android-x64"
    )
    copy_apk("app-x86_64-release.apk", f"safenotes-{version}-x86_64.apk", github)
    copy_apk("app-arm64-v8a-release.apk", f"safenotes-{version}-arm64-v8a.apk", github)
    copy_apk("app-armeabi-v7a-release.apk", f"safenotes-{version}-armeabi-v7a.apk", github)
    copy_apk("output-metadata.json", f"metadata-{version}-split-per-abi.json", github)

    # ② Android fat APK（单包兼容所有 ABI，方便侧载）
    run("flutter build apk --release")
    copy_apk("app-release.apk", f"safenotes-{version}-all.apk", github)
    copy_apk("output-metadata.json", f"metadata-{version}-all.json", github)

    # ③ Windows desktop（整目录打包 zip，单 exe 缺 DLL 无法运行）
    run("flutter build windows --release")
    zip_windows(github, version)

    # ④ 汇总压缩包 + 校验清单
    zip_android(github, version)
    write_sha256(github)

    print(f"\n== Release 产物已就绪：{github} ==")
    for f in sorted(github.iterdir()):
        if f.is_file():
            print(f"  - {f.name}（{f.stat().st_size / 1024 / 1024:.1f} MB）")
    print(
        "\n发布命令示例：\n"
        f"  gh release create v{version} {github}/*.zip {github}/SHA256SUMS.txt \\\n"
        f"    --title 'Safe Notes v{version}' --notes '...'"
    )


if __name__ == "__main__":
    make_release()
