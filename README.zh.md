# Carro Note

> 加密、私密的本地优先（local-first）笔记管理器 —— **端到端加密（E2EE）同步版**

Carro Note 是一款注重隐私的笔记应用：所有笔记**默认在本地设备上加密存储**（AES-256-GCM），不依赖任何第三方云。

本项目基于上游 [keshav-space/safenotes](https://github.com/keshav-space/safenotes) fork 并进行了大幅改造，**核心新增了一套完整的端到端加密多设备同步子系统**：客户端 `SyncEngine` + 可插拔后端抽象（WebDAV / 自建 HTTP 服务 / 本地文件系统），并配套提供了 **Go 与 Node.js 两种**参考实现的服务端（SafeServer）。

> [!IMPORTANT]
> 安全与责任：再强的加密也要求你**牢记自己的主密码（passphrase）**。密码只存在于你的脑中，任何人都无法帮你找回。

---

## 特性

**基础能力（继承自上游）**
- 本地 AES-256 加密存储，笔记在设备上永不以明文落盘
- 生物识别（指纹 / 面容）解锁
- 安卓后台快照保护、隐身键盘、防截屏
- 暴力破解防护、闲置自动锁定（inactivity guard）
- 北极风（Arctic Nord）深 / 浅色主题、列表 / 网格视图、彩色笔记
- 加密备份导出 / 导入（无缝迁移到新设备）

**新增能力（本 fork 改造）**
- 端到端加密同步：**MK + dataKey 两层密钥**，改密码 O(1) 且原子完成
- 后端无关（backend-agnostic）：WebDAV（坚果云 / NextCloud / 自建）、自建 SafeServer HTTP、本地文件系统任选
- 内容寻址（content hash）天然去重、软删除 / 墓碑同步
- 多设备同步 + LWW 冲突解决 + 历史版本保留
- 同步诊断页、同步状态可视化

---

## 项目结构

```
lib/                Flutter 客户端：UI、状态装配、平台注入（入口 lib/main.dart）
packages/core/      纯 Dart 核心包：加密、SQLite 数据库、模型、SyncEngine（无 Flutter 依赖）
bin/                纯 Dart CLI 客户端：无需 Flutter SDK 即可读写加密数据库
server/             SafeServer 服务端参考实现（Go 与 Node.js，已提交进仓库；仅 `data/`、`dist/` 运行时产物被 git 忽略）
docs/               设计文档、协议规范与开发指南
test/               App 侧与集成测试
```

核心逻辑（加密 / 数据库 / 同步引擎）独立为纯 Dart 包 `packages/core`（禁止 Flutter 依赖，由 pub workspace 编译器强制），App 侧只保留 UI 与状态装配，通过 `package:core/core.dart` 单一出口导入。另提供纯 Dart CLI `bin/safenotes_cli.dart`（无需 Flutter SDK 即可读写加密笔记数据库，可编译为 AOT 原生产物）。

---

## 文档

- **开发指南** —— 代码结构、构建与测试流程：[`docs/DEVELOPMENT.zh.md`](docs/DEVELOPMENT.zh.md)
- 详细设计、协议规范与每日变更日志见 `docs/` 目录（索引见 `docs/DEVELOPMENT.zh.md`）。

---

## 许可证

GPL-3.0-or-later。© Keshav Priyadarshi and others。详见 `LICENSE`、`AUTHORS.md`、`SECURITY.md`。
