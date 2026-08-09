# SafeServer (Go) build & check — codegen not required.
#
# 与 server/justfile 目标等价；Makefile 在 CI runner（如 GitHub Actions
# ubuntu-latest 自带 GNU make）上更通用。交叉编译统一交给 build.go（单一
# 事实来源），不会污染全局 `go env`。
#
# 用法：
#   make build            # 本机(host)构建
#   make multi            # 全部目标平台交叉编译
#   make dist TARGETS=... # 指定平台，如 make dist TARGETS=windows/amd64,linux/arm64
#   make test             # 运行全部单测
#   make ci               # vet + test + multi（CI 入口）

GO      ?= go
DIST    := dist/go
BIN     := safeserver

.PHONY: default build multi dist test vet analyze ci clean help
default: help

## build: 本机(HOST)构建
build:
	$(GO) run build.go -targets host

## multi: 构建全部目标平台 (输出 dist/go/safeserver-<os>-<arch>[.exe])
multi:
	$(GO) run build.go

## dist: 构建指定平台（TARGETS=os/arch,...）
dist:
	$(GO) run build.go -targets "$(TARGETS)"

## test: 运行 Go 单元测试
test:
	cd go && $(GO) test ./...

## vet: 静态检查
vet:
	cd go && $(GO) vet ./...

## analyze: vet + test
analyze: vet test

## ci: CI 入口（校验 + 全部构建）
ci: analyze multi

## help: 显示可用目标
help:
	@echo "Available goals:"
	@grep -E '^[a-z_-]+:.*##' $(MAKEFILE_LIST) | awk -F '[:##]' '{ printf "  %-12s %s\n", $$1, $$3 }'

## clean: 删除产物目录
clean:
	rm -rf $(DIST)
