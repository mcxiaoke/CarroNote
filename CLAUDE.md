# CLAUDE.md — 开发与安全须知

本文件供 AI 协作者 / 开发者快速上手 Safe Notes（fork 自 keshav-space/safenotes，已新增 E2EE 同步子系统）。

## 1. 项目简介
- Flutter 加密笔记应用，纯本地优先，外加端到端加密多设备同步。
- 入口：`lib/main.dart`；同步核心：`lib/sync/`；服务端参考实现：`server/`（Go / Node.js）。

## 2. 测试流程
1. 改码后先跑 `flutter flutter analyze`，确保无 lint / format 错误。
2. 单元测试（纯本地）：
   - 加密：`flutter test test/encryption`
   - 同步引擎（内存 FakeBackend）：`flutter test test/sync/sync_engine_test.dart`
3. 集成测试（需 SafeServer）：
   - 默认 Go：`flutter test test/sync/safe_server_integration_test.dart`
   - 切换 Node.js：`$env:SN_SERVER="node"`（PowerShell）后同上。
4. 全量测试 `flutter test`

## 3. 代码规范
- 关键逻辑、核心算法、复杂分支必须加**简体中文注释**。
- 遵守 `flutter_lints` 与 `analysis_options.yaml`。
- 导入排序使用 import_sorter（`make isort`）。
- 修复 Bug / 改码后**必须运行相关测试**。

## 4. 重要说明
- **勿自发 git commit / push**：除非用户明确要求。
- **协议兼容性**：改动 `lib/sync/` 的协议字段（manifest 结构、SyncBackend 接口）须同步更新 `docs/sync-protocol-spec.md` 与测试，避免破坏跨设备 / 跨服务端互操作。

## 5. 文档与变更约定
- 设计 / 协议 / 评审归档于 `docs/`，按主题命名。
- 每日变更在 `docs/CHANGES-YYYYMMDD.md` **顶部**追加；仅文档改动可不追加。
- 临时文件放 `temp/`，文档放 `docs/`；
- 根目录 `README.md` / `CLAUDE.md` 为项目标准文件。
