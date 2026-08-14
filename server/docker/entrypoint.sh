#!/bin/sh
# wsns 容器启动脚本
#
# 职责：
#   1. 在单一根目录 /srv/wsns 下建好 config/ data/ logs/ backups 四个子目录；
#   2. 若 config/ 下没有 config.json，从镜像内置的 /etc/wsns/config.json 拷贝一份；
#   3. 用 -config 拉起 wsns；token 通过环境变量 SAFESERVER_TOKEN 注入
#      （默认 config.json 不含 token，优先级：CLI flag > 环境变量 > 配置文件）。
set -eu

BASE="/srv/wsns"
CONFIG_DIR="$BASE/config"
DATA_DIR="$BASE/data"
LOG_DIR="$BASE/logs"
BACKUP_DIR="$BASE/backups"
CONFIG_FILE="$CONFIG_DIR/config.json"

mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$BACKUP_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[entrypoint] no config found, seeding default config -> $CONFIG_FILE"
    cp /etc/wsns/config.json "$CONFIG_FILE"
fi

echo "[entrypoint] starting wsns with config: $CONFIG_FILE"
exec /usr/local/bin/wsns -config "$CONFIG_FILE"
