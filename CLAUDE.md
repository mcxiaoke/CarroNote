# CLAUDE.md — 开发与安全须知

本文件供 AI 协作者 / 开发者快速上手 Safe Notes（fork 自 keshav-space/safenotes，已新增 E2EE 同步子系统）。

## 1. 项目简介
- Flutter 加密笔记应用，纯本地优先，外加端到端加密多设备同步。
- **代码分层**：核心逻辑（加密 / 数据库 / 同步引擎）为独立纯 Dart 包 `packages/core`（无 Flutter 依赖，编译器强制），App 侧仅保留 UI 与状态装配。
- 入口：`lib/main.dart`；核心包：`packages/core/`（统一经 `package:core/core.dart` 出口导入）；服务端参考实现：`server/`（Go / Node.js）。
- CLI：`bin/safenotes_cli.dart`（纯 Dart，无需 Flutter SDK，可读写加密笔记数据库）。
  - **编译 AOT 产物**：`make cli-build` / `task cli-build` / `just cli-build`
    （= `dart build cli -t bin/safenotes_cli.dart -o build/cli`，注意 SDK ≥3.12 的 `dart compile exe`
    不支持 build hooks，须用 `dart build cli`）。产物 `build/cli/bundle/bin/safenotes_cli.exe`
    + `build/cli/bundle/lib/sqlite3.dll`（bundle 需整体分发），日常用产物比 `dart run` 快约 58x 且无
    "Running build hooks" 噪声。
  - **任务管理**：`make`（Makefile）、`task`（Taskfile.yml）、`just`（justfile）三份等价，
    按 依赖/构建/测试 三类组织，均含 `cli-build`、`e2e`、`analyze`、`test`、`test-core` 等；
    Windows 下 `make` 可能不在 PATH，推荐 `task` / `just`（可 `task --list` / `just --list` 查看）。
  - **CLI 端到端测试**：`make e2e` / `task e2e` / `just e2e`（= `pwsh scripts/cli-e2e-test.ps1`，
    需先 cli-build；脚本自动优先用二进制，缺失时回退 `dart run`）。

## 2. 测试流程
1. 改码后先跑 `make analyze`（= `flutter analyze lib test` + `dart analyze packages/core`），确保无 lint / format 错误。
2. 单元测试：
   - 核心包（纯 Dart，无 Flutter SDK 也可跑）：`dart test packages/core/test`
     - 加密：`dart test packages/core/test/encryption`
     - 同步引擎 / 多设备 / 长期存续：`dart test packages/core/test/sync`
   - App 侧（需 Flutter）：`flutter test`（change_password / widget / generate_real_db）
3. 集成测试（需 SafeServer，位于核心包）：
   - 默认 Go：`flutter test packages/core/test/sync/safe_server_integration_test.dart`
   - 切换 Node.js：`$env:SN_SERVER="node"`（PowerShell）后同上。
4. 全量测试 `make test`（= `dart test packages/core/test` + `flutter test`）；仅核心 `make test-core`。

## 3. 代码规范
- 关键逻辑、核心算法、复杂分支必须加**简体中文注释**。
- App 侧遵守 `flutter_lints` 与 `analysis_options.yaml`；核心包 `packages/core` 使用 `package:lints/recommended.yaml`（纯 Dart，不用 flutter_lints）。
- 导入排序使用 import_sorter（`make isort`）。
- 修复 Bug / 改码后**必须运行相关测试**。

## 4. 重要说明
- **勿自发 git commit / push**：除非用户明确要求。
- **纯 Dart 约束**：核心包 `packages/core` 禁止引入任何 Flutter 依赖（含 flutter/foundation 等）；需要平台能力（路径、安全存储、日志）一律走 `lib/src/ports.dart` 注入点或 App 侧注入（如 `NotesDatabase.dbFactoryOverride` / `logDirResolverOverride`）。
- **协议兼容性**：改动 `packages/core/lib/src/sync/` 的协议字段（manifest 结构、SyncBackend 接口）须同步更新 `docs/sync-protocol-spec.md` 与测试，避免破坏跨设备 / 跨服务端互操作。

## 5. 文档与变更约定
- 设计 / 协议 / 评审归档于 `docs/`，按主题命名。
- 每日变更在 `docs/CHANGES-YYYYMMDD.md` **顶部**追加；仅文档改动可不追加。
- 临时文件放 `temp/`，文档放 `docs/`；
- 根目录 `README.md` / `CLAUDE.md` 为项目标准文件。
