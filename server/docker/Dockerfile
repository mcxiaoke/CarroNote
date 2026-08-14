# syntax=docker/dockerfile:1
#
# wsns (SafeServer) — Go 参考服务端镜像
# 目标平台：linux/amd64，静态二进制 (CGO_ENABLED=0)，无外部依赖。
#
# 所有运行时产物（配置 / 数据 / 日志 / 备份）都落在容器内的单一根目录
# /srv/wsns 下，并通过 docker-compose 整体挂载到宿主机的一个目录，
# 其下自动划分 config/ data/ logs/ backups/ 四个子目录。

# ---------- 构建阶段 ----------
FROM golang:1.24-alpine AS build
WORKDIR /src
# 仅复制 Go 源码（go.mod 无外部依赖，纯标准库实现）
COPY server/go/ ./go/
WORKDIR /src/go
# 显式指定 linux/amd64 静态编译
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/wsns .

# ---------- 运行阶段 ----------
FROM alpine:3.20
# 提供 wget 供 healthcheck 使用
RUN apk add --no-cache wget \
    && mkdir -p /srv/wsns /etc/wsns

WORKDIR /srv/wsns

# 编译好的二进制
COPY --from=build /out/wsns /usr/local/bin/wsns
# 默认配置（首次启动时若挂载目录里没有 config.json，由 entrypoint 拷贝过去）
COPY server/docker/config.json /etc/wsns/config.json
# 启动脚本：建子目录 + 兜底配置文件 + 拉起服务
COPY server/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/wsns /usr/local/bin/entrypoint.sh

# 单一根目录：宿主机的 ./wsns-data 会挂到这里
VOLUME ["/srv/wsns"]

EXPOSE 4080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
