#!/usr/bin/env bash
#
# 本地打包 WSNS Linux/amd64 发布包（在开发机 Windows/macOS/Linux 上运行）
#
# 产物：server/dist/wsns-linux-amd64.zip
#   内含：wsns（二进制）、wsns.service、config.json、install.sh
#   解压后直接 sudo ./install.sh 即可完成安装。
#
# 用法：
#   bash server/deploy/package.sh
#   GO=go bash server/deploy/package.sh     # 指定 go 命令路径

set -euo pipefail

GO="${GO:-go}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/server"
STAGE="$ROOT/server/dist/.wsns-bundle"
OUT_ZIP="$ROOT/server/dist/wsns-linux-amd64.zip"

rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "→ 交叉编译 linux/amd64 ..."
( cd "$SRC/go" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "$GO" build -trimpath -o "$STAGE/wsns" . )

cp "$SRC/deploy/wsns.service" "$STAGE/"
cp "$SRC/deploy/config.json"   "$STAGE/"
cp "$SRC/deploy/install.sh"    "$STAGE/"

# 优先 zip；否则退化为 7z / tar.gz
rm -f "$OUT_ZIP" "${OUT_ZIP%.zip}.tar.gz"
cd "$STAGE"
if command -v zip >/dev/null 2>&1; then
  zip -j "$OUT_ZIP" ./*
  ARCHIVE="$OUT_ZIP"
elif command -v 7z >/dev/null 2>&1; then
  7z a "$OUT_ZIP" ./* >/dev/null
  ARCHIVE="$OUT_ZIP"
else
  tar -czf "${OUT_ZIP%.zip}.tar.gz" ./*
  ARCHIVE="${OUT_ZIP%.zip}.tar.gz"
fi

echo ""
echo "✓ 发布包: $ARCHIVE"
echo ""
echo "上传到服务器："
echo "  scp $ARCHIVE user@<server>:/tmp/"
echo ""
echo "服务端安装："
echo "  ssh user@<server>"
echo "  sudo apt-get install -y unzip   # 若没有 unzip"
echo "  unzip /tmp/${ARCHIVE##*/} -d /tmp/wsns && cd /tmp/wsns && sudo ./install.sh"
