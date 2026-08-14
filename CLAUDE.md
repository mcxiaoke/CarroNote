# CLAUDE.md — 开发与安全须知

Flutter 加密笔记应用，本地优先 + E2EE 多设备同步。

## 项目结构
- `lib/`：App UI 与状态装配，入口 `lib/main.dart`
- `packages/core/`：纯 Dart 核心包（加密 / 数据库 / 同步引擎），
- `bin/`：CLI，无需 Flutter SDK
- `docs/`：文档；`temp/`：临时文件
- `server/`：服务端参考实现（Go / Node.js）

## 环境路径
- `PUB_CACHE`: 这里 C:\Home\Develop\flutter\dart\cache\hosted

## 开发测试
- 格式化: 需要运行 `dart run import_sorter:main` 和 `dart format .` 确保代码格式一致
- 测试: 改代码后运行 `flutter analyze` 和 `dart test` 和 `flutter test` 测试通过
- 验证: 运行 `flutter build windows` 验证编译，运行 `flutter run -d windows` 无问题后结束进程

## 注意事项
- 翻译语言资源只需要添加 `zh-CN` 和 `en-US` 就行
- 勿自发 git commit / push
- 核心包禁止引入任何 Flutter 依赖
- 关键代码变更记入 `docs/CHANGES-YYYYMMDD.md` 顶部