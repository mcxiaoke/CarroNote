# 主界面笔记列表卡顿问题诊断报告

- 日期：2026-08-02 10:28:16
- 现象：主界面（HomePage）几十条、单条 1KB–100KB 的笔记就出现严重卡顿
- 结论：**不是笔记条数问题，是"单条正文体积"问题**。当前实现把每条笔记的**完整正文**在
  「解密 → 正则清洗 → RTL 检测 → 文本布局」四个环节各完整走了一遍，而且每次 build / 每次刷新都重复付费。
  正文越大，成本线性（甚至超线性）增长，与条数无关。
- 本次只做调查，**未修改任何业务代码**。探针脚本位于 `temp/`。

---

## 一、量化证据

探针脚本（临时，可复跑）：

| 脚本 | 运行方式 | 测量内容 |
|---|---|---|
| `temp/perf_probe.dart` | `dart run temp/perf_probe.dart` | sanitize / Bidi RTL 检测 / AES-GCM 解密 |
| `temp/text_layout_probe_test.dart` | `flutter test temp/text_layout_probe_test.dart` | TextPainter 布局成本、搜索扫描成本 |
| `temp/autosize_probe_test.dart` | `flutter test temp/autosize_probe_test.dart` | AutoSizeText 端到端渲染成本 |

> 以下数字均在**开发机（Windows / JIT / desktop test 环境）**测得，中低端手机通常还要慢 2–5 倍。
> 60fps 的单帧预算是 **16.7ms**。

### 1.1 单条笔记的固定开销（按正文大小）

| 正文大小 | `sanitize()` | RTL 检测 | AES-GCM 解密 | 合计 |
|---|---|---|---|---|
| 1 KB | 0.7ms | 0.5ms | 3.6ms | 4.9ms |
| 4 KB | 0.5ms | 2.3ms | 7.2ms | 10.1ms |
| 16 KB | 2.0ms | 2.1ms | 17.2ms | 21.3ms |
| 50 KB | 4.4ms | 5.9ms | 50.8ms | 61.2ms |
| **100 KB** | **9.5ms** | **9.3ms** | **102.8ms** | **121.6ms** |

### 1.2 文本布局：`maxLines: 2` **完全不省钱**

| 正文大小 | TextPainter(maxLines=2) | TextPainter(无限制) |
|---|---|---|
| 16 KB | 6.9ms | 6.3ms |
| 50 KB | 29.1ms | 29.1ms |
| 100 KB | 46.3ms | 59.0ms |

说明：Flutter 的段落布局必须对**整段文本**做 shaping / 断行，`maxLines` 只在结果上截断行数，
**不会**提前停止计算。所以"只显示 2 行"这个直觉在这里完全不成立。

### 1.3 AutoSizeText 端到端（单条卡片一次渲染）

| 正文大小 | AutoSizeText(16~16)<br>note_card / note_tile | AutoSizeText(15~18)<br>compact 卡片 | 对照：先截断 300 字符 + 普通 Text |
|---|---|---|---|
| 16 KB | 33.2ms | 39.6ms | 12.1ms |
| 30 KB | 48.4ms | 60.4ms | 18.6ms |
| **100 KB** | **136.8ms** | **178.3ms** | **9.2ms** |

对照组里 ~10ms 是 `pumpWidget` 的固定框架开销，也就是说**截断后真实布局成本≈0**。
AutoSizeText 之所以更贵，是它为了二分搜索字号会对全文**反复 layout**：
- `minFontSize=16 / fontSize=16`（note_card、note_tile）≈ 2–3 次全文 layout；
- `minFontSize=15 / fontSize=18`（两个 compact 卡片）≈ 5–7 次全文 layout。

### 1.4 场景合成

以「50 条笔记，平均 30KB」为例：

- `readAllNotes()` 一次全量解密：**约 1.5 秒主线程冻结**（且是同步循环，中途不让出，连转圈动画都不动）
- 一屏 6 张卡片的 build+layout：**约 300ms**（`sanitize`+RTL 35ms，AutoSizeText 约 290ms）
- 搜索框每敲一个字：全库 `toLowerCase().contains()` **约 8ms**，外加整个列表重建（再付一次上面的 300ms）

---

## 二、根因清单（按影响从大到小）

### 根因 1（最大）：列表卡片把**完整正文**丢给 AutoSizeText

| 文件 | 行 | 代码 |
|---|---|---|
| `lib/widgets/note_card.dart` | 94–105 | `AutoSizeText(sanitize(note.description), minFontSize: 16, maxLines: getMaxLine(index))` |
| `lib/widgets/note_tile.dart` | 92–103 | `AutoSizeText(sanitize(note.description), minFontSize: 16, maxLines: 2)` |
| `lib/widgets/note_card_compact.dart` | 50–62 | `AutoSizeText(sanitize(previewText), minFontSize: 15, ...)`（`title==' '` 时 previewText 即全文） |
| `lib/widgets/note_tile_compact.dart` | 49–61 | 同上 |

列表只需要 1–4 行预览，却把 100KB 文本完整送进排版引擎，并且被 AutoSizeText 放大 2–7 倍。
这些都是 `StatelessWidget`，**没有任何缓存**：滚出视口再滚回来、任意一次 `setState`，全部重算。

### 根因 2：`sanitize()` 每次 build 对全文跑正则

`lib/utils/string_utils.dart:14`

```dart
String sanitize(String inputString) {
  final multipleSpaces = RegExp(' +');                    // 每次调用重新编译
  final emptylines = RegExp(r'(?:[\t ]*(?:\r?\n|\r))+');  // 嵌套量词，大文本上很贵
  return inputString.trim().replaceAll(...).replaceAll(...);
}
```

两个 `RegExp` 是局部变量，**每次调用都重新编译**；`replaceAll` 又会完整扫描并重建 100KB 字符串。
100KB → 9.5ms/次，而它在每条卡片的每次 build 都被调用。

### 根因 3：`getTextDirecton()` 对全文做 RTL 检测

`lib/utils/text_direction_util.dart:22` → `intl` 的 `Bidi.estimateDirectionOfText`（`bidi.dart:258`）：

```dart
for (var token in text.split(RegExp(r'\s+'))) {   // 100KB 切成上万个 token
  if (startsWithRtl(token)) ...                   // 内部：RegExp('^[^…]*[…]')  ← 每个 token 新建并编译正则
  else if (RegExp(r'^http://').hasMatch(token))   // ← 又一个
  else if (hasAnyLtr(token))                      // ← 又一个
  else if (RegExp(r'\d').hasMatch(token))         // ← 又一个
}
```

一条 100KB 笔记 ≈ 上万次正则编译 + 匹配 → **9.3ms**。
而它的产出只是"这段文字是不是从右往左排"这一个布尔值 —— 取正文前 100–200 字符判断即可，完全不需要全文。

全项目共 20 处调用（`lib/views/note_view.dart`、四个卡片 widget、`note_widget.dart`、`search_widget.dart`），
其中列表里的 4 处是热点。

> 根因 2 + 3 合计：单条 100KB 笔记**每帧**额外 ~19ms，已经超过整帧预算。

### 根因 4：`readAllNotes()` 在主 isolate 同步全量解密，且调用极其频繁

`lib/data/database_handler.dart:432-442`

```dart
Future<List<SafeNote>> readAllNotes() async {
  final result = await db.query(tableNotes, columns: NoteFields.values, where: 'deleted = 0', ...);
  return result.map((json) => _fromEncryptedRow(json)).toList();  // ← 同步循环，逐条 AES-GCM 解密
}
```

- 解密走 `pointycastle` 纯 Dart AES-256-GCM，实测吞吐 **≈1 MB/s**（100KB → 103ms）。
- `.map().toList()` 是**同步**的，中途不 `await`、不让出事件循环 → UI 完全冻结，
  `CircularProgressIndicator` 也停住。
- 列表页只需要预览，却把**每条笔记的完整正文**都解了。

`refreshNotes()` 的触发点（`lib/views/home.dart`）密集得超出预期：

| 位置 | 触发时机 |
|---|---|
| `initState` (81) | 进入主界面 |
| `_onSyncStateChanged` (131) | **每次同步完成**（success 或 error）；autoSync 默认 3 秒 debounce 后触发 |
| `_syncStatusButton` (307) | 从同步设置页返回 |
| `_addANewNoteButton` (424) | 新建笔记返回 |
| `_buildNotesTile` (517) / `_buildNotes` (551) | **每次查看完一条笔记返回** |
| `onSettingsCallback` (472) / `onDeletedNotesCallback` (490) | 从设置页、回收站返回 |
| `_shortNotes` (396) → `_sortAndStoreNotes` | **只是点一下正序/倒序按钮，也重新全量解密一遍** |

也就是说：点开一条笔记看完返回 = 1.5 秒冻结；切一次排序 = 1.5 秒冻结。

### 根因 5：搜索无 debounce，每次按键全库扫描 + 整表重建

`lib/views/home.dart:562`

```dart
void _searchNote(String query) {
  final notes = allnotes.where((note) {
    final descriptionLower = note.description.toLowerCase();  // 每条都新建一份 100KB 小写副本
    return titleLower.contains(queryLower) || descriptionLower.contains(queryLower);
  }).toList();
  setState(...);   // 触发整个列表重建 → 根因 1/2/3 全部重付
}
```

50 条 × 30KB ≈ 8ms/键（纯扫描），叠加列表重建的 ~300ms → 打字肉眼可见地一顿一顿。

### 次要问题

1. `home.dart:393-398`：`setState` 回调里 fire-and-forget 调用异步的 `_sortAndStoreNotes()`，
   既不等待也不处理异常；排序本可以下推到 SQL（`readAllNotes` 已有 `orderBy`）或直接对内存列表排序。
2. 列表项没有 `RepaintBoundary`，`AlignedGridView` 需要实际 layout 每个 child 才能对齐 → 昂贵的 layout 无法避开。
3. `lib/views/note_view.dart:100`：详情页也对完整正文做 `getTextDirecton` —— 打开一条大笔记同样会卡一下。
4. `home.dart:246` 的 `Provider.of<NotesColor>(context)` 会让整页随颜色变更重建（影响面小，但重建代价被上面几条放大）。

---

## 三、修复建议（按性价比排序，本次未实施）

**P0 — 引入"预览文本"概念，从源头砍掉大文本**

1. 列表数据与详情数据分离：新增轻量查询（例如 `readAllNotePreviews()`），解密后**立即**
   `description.substring(0, 200~300)` 生成预览并丢弃全文；卡片只吃预览串，点开详情时再按 `id/uuid` 读全文。
   这一条同时解决根因 1、2、3，并把根因 4 的解密量降到"只解需要的量"。
   - 更彻底的做法：写入时额外持久化一个加密的 `preview` 字段（前 N 字符），列表查询根本不碰 `description` 列。
2. 列表卡片改用普通 `Text`（固定字号 + `overflow: ellipsis`），去掉 `AutoSizeText`。
   实测同样内容从 137ms → 接近 0。

**P1 — 消除主线程长阻塞**

3. `readAllNotes` 的解密移入 Isolate（`compute`），或按批 `await Future.delayed(Duration.zero)` 让出；
   两者都需要注意 `dataKey` 的跨 isolate 传递与生命周期。
4. 主页维护内存缓存：排序、搜索、颜色切换一律**复用已加载的数据**，不再重查库、不再重解密。
5. `refreshNotes` 收敛：详情页返回时带回"是否有修改"的标记，无修改则不刷新；
   同步完成后按 `changedUuids` 做局部更新而非全量重载。

**P2 — 细节优化**

6. `sanitize()` 的两个 `RegExp` 提为顶层 `final` 常量（避免重复编译）；且只作用于截断后的预览串。
7. `getTextDirecton()` 内部先 `text.substring(0, min(200, len))` 再判断方向；顺带缓存结果。
8. 搜索加 250–300ms debounce，并只在（标题 + 预览串）上匹配；若要全文搜索，改用 SQLite FTS 或后台 isolate。
9. 列表项包一层 `RepaintBoundary`；`ListView.separated` 可考虑 `prototypeItem` 或固定高度以避免逐项测量。

---

## 四、复现与验证方式

```bash
dart run temp/perf_probe.dart
flutter test temp/text_layout_probe_test.dart
flutter test temp/autosize_probe_test.dart
```

改造后重跑同一组脚本对比即可。真机验证建议开 `flutter run --profile` + DevTools Performance，
重点看 `readAllNotes` 期间的 UI 线程长任务，以及滚动时 `AutoSizeText` 的 layout 帧。
