# CLAUDE.md — 开发与安全须知

Flutter 加密笔记应用，本地优先 + E2EE 多设备同步。

## 项目结构

* `lib/`：App UI 与状态装配，入口 `lib/main.dart`

* `packages/core/`：纯 Dart 核心包（加密 / 数据库 / 同步引擎），

* `bin/`：CLI，无需 Flutter SDK

* `docs/`：文档；`temp/`：临时文件

* `server/`：服务端参考实现（Go / Node.js）

## 环境路径

* `PUB_CACHE`: Flutter|Dart包缓存路径看这里 `./dart_tool/package_config.json`

* 查找工具和开发环境和软件包用 Everything Cli工具 `es.exe` 直接搜索，禁止大范围find

## 开发测试

* 代码格式: 针对修改过的代码，运行 `dart format` 和 `dart pub run import_sorter:main` 确保代码格式一致，禁止全仓库运行

* 普通测试: 改代码后运行 `flutter analyze` 和 `dart test packages\core\test` 和 `flutter test` 测试通过

* 编译验证: 运行 `flutter build windows --debug` 验证编译无错误

* 集成测试：重大UI重构后运行 flutter test integration\_test/app\_test.dart -d windows (耗时较长)

## 注意事项

* 翻译语言资源只需要添加 `zh-CN` 和 `en-US` 就行

* 未经用户明确允许，禁止 `git commit` ，任何情况下都禁止 `git push`

* commit msg使用英文，commit可以用临时文件或改用 -m 多行参数

* 核心包 `packages/core` 禁止引入任何 Flutter 依赖

* 关键代码变更的改动概要记入 `docs/CHANGES-YYYYMMDD.md` 顶部

