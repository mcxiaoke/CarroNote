#!/usr/bin/env bash
#
# WSNS（WebDAV-compatible SafeNotes Server）一键安装脚本（Linux amd64）
#
# 在解压后的目录中以 root 运行：
#   sudo ./install.sh                 # 安装并启动
#   sudo ./install.sh --no-start      # 仅安装，不启动
#   WSNS_TOKEN=xxx sudo ./install.sh  # 指定 Bearer Token（否则自动生成强随机 Token）
#
# 脚本会把同目录下的三个文件安装到标准位置：
#   wsns           → /usr/local/bin/wsns              （二进制）
#   wsns.service   → /etc/systemd/system/wsns.service （systemd 单元）
#   config.json    → /etc/safenotes/config.json       （配置，含 Token）
#
# 并自动创建专用用户、数据目录、备份目录，最后启用并启动服务（或打印手动启动命令）。
# 安装结束会打印各文件路径与生成的 Token。
#
# 安全说明：Token 是客户端同步的凭据，请妥善保存脚本打印出的 Token；
# 若已存在 /etc/safenotes/config.json，会先备份为 .bak.<时间戳> 再覆盖。

set -euo pipefail

# ── 0. 运行环境检查 ──────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "错误：请以 root 运行（sudo ./install.sh）" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 可覆盖的安装路径 ─────────────────────────────────────────────
BIN_NAME="wsns"
BIN_DEST="/usr/local/bin/${BIN_NAME}"
SERVICE_SRC="${SCRIPT_DIR}/${BIN_NAME}.service"
SERVICE_DEST="/etc/systemd/system/${BIN_NAME}.service"
CONFIG_SRC="${SCRIPT_DIR}/config.json"
CONFIG_DIR="/etc/safenotes"
CONFIG_DEST="${CONFIG_DIR}/config.json"
DATA_DIR="/var/lib/safenotes"
BACKUP_DIR="/var/backups/wsns"
RUN_USER="safenotes"
NO_START=0

for arg in "$@"; do
  case "$arg" in
    --no-start) NO_START=1 ;;
    *) echo "未知参数: $arg" >&2; exit 1 ;;
  esac
done

# ── 1. 定位二进制（兼容多种命名） ───────────────────────────────
BIN_SRC=""
for cand in "${SCRIPT_DIR}/${BIN_NAME}" "${SCRIPT_DIR}/${BIN_NAME}-linux-amd64" "${SCRIPT_DIR}/${BIN_NAME}-amd64"; do
  if [[ -f "$cand" ]]; then BIN_SRC="$cand"; break; fi
done
if [[ -z "$BIN_SRC" ]]; then
  echo "错误：在 ${SCRIPT_DIR} 未找到二进制（期望 ${BIN_NAME} 或 ${BIN_NAME}-linux-amd64）" >&2
  exit 1
fi

# ── 2. 生成 / 采用 Token ────────────────────────────────────────
if [[ -n "${WSNS_TOKEN:-}" ]]; then
  TOKEN="$WSNS_TOKEN"
else
  if command -v openssl >/dev/null 2>&1; then
    TOKEN="$(openssl rand -hex 24)"
  else
    TOKEN="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48)"
  fi
fi

# ── 3. 安装二进制 ───────────────────────────────────────────────
install -m 0755 "$BIN_SRC" "$BIN_DEST"
echo "✓ 二进制   : $BIN_DEST"

# ── 4. 创建专用用户、数据 / 备份目录 ───────────────────────────
if ! id "$RUN_USER" >/dev/null 2>&1; then
  useradd -r -s /usr/sbin/nologin "$RUN_USER"
  echo "✓ 创建专用用户: $RUN_USER"
fi
install -d -m 0700 -o "$RUN_USER" -g "$RUN_USER" "$DATA_DIR"
install -d -m 0700 -o "$RUN_USER" -g "$RUN_USER" "$BACKUP_DIR"
echo "✓ 数据目录 : $DATA_DIR"
echo "✓ 备份目录 : $BACKUP_DIR"

# ── 5. 安装配置（注入 Token；已存在则先备份） ──────────────────
install -d -m 0755 "$CONFIG_DIR"
if [[ -f "$CONFIG_DEST" ]]; then
  cp -a "$CONFIG_DEST" "${CONFIG_DEST}.bak.$(date +%Y%m%d%H%M%S)"
  echo "⚠ 已存在配置，已备份为 ${CONFIG_DEST}.bak.*"
fi
if grep -q '__WSNS_TOKEN__' "$CONFIG_SRC"; then
  sed "s/__WSNS_TOKEN__/$TOKEN/g" "$CONFIG_SRC" > "$CONFIG_DEST"
else
  cp "$CONFIG_SRC" "$CONFIG_DEST"
fi
chown root:"$RUN_USER" "$CONFIG_DEST"
chmod 0640 "$CONFIG_DEST"
echo "✓ 配置     : $CONFIG_DEST"

# ── 6. 安装 systemd 单元 ────────────────────────────────────────
if [[ ! -f "$SERVICE_SRC" ]]; then
  echo "错误：未找到服务单元文件 $SERVICE_SRC" >&2
  exit 1
fi
install -m 0644 "$SERVICE_SRC" "$SERVICE_DEST"
echo "✓ 服务单元 : $SERVICE_DEST"

# ── 7. 启用并启动 ──────────────────────────────────────────────
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  systemctl enable "$BIN_NAME"
  if [[ $NO_START -eq 0 ]]; then
    systemctl restart "$BIN_NAME"
    sleep 1
    echo "✓ 服务已启动"
  else
    echo "⏭ 跳过启动（--no-start）"
  fi
else
  echo "⚠ 未检测到 systemd，跳过启用 / 启动。可手动运行："
  echo "    $BIN_DEST -config $CONFIG_DEST"
fi

# ── 8. 安装摘要 ─────────────────────────────────────────────────
echo ""
echo "=============================================="
echo " WSNS 安装完成"
echo "=============================================="
echo " 二进制   : $BIN_DEST"
echo " 配置     : $CONFIG_DEST"
echo " 数据目录 : $DATA_DIR"
echo " 备份目录 : $BACKUP_DIR"
echo " 服务单元 : $SERVICE_DEST"
echo " 运行用户 : $RUN_USER"
echo "----------------------------------------------"
echo " Bearer Token（客户端同步需填此值）:"
echo "   $TOKEN"
echo "----------------------------------------------"
echo " 查看状态 : systemctl status $BIN_NAME"
echo " 查看日志 : journalctl -u $BIN_NAME -f"
echo " 健康检查 : curl -fsS http://localhost:4080/api/v2/health"
echo "=============================================="
