/*
 * 同步层测试公共支撑
 *
 * 存在理由：P2 收敛（Keyring 取代 Vault、SyncEngine 强制注入 Journal）之后，
 * 每个测试文件都要重复写一遍「造 Keyring / 造 Journal / 给 FakeBackend 补
 * journal 三件套」。把这些搬到一处，好处有三：
 *   1. 测试文件只关心自己要验证的行为，不被样板噪音淹没
 *   2. 以后 Keyring/Journal 再演进，只改这一个文件，不用扫 8 个测试
 *   3. FakeBackend 的 journal 存储是**真存**（不是 no-op），因此测试可以
 *      直接断言「远端 journal 副本确实写上去了」——这正是设计 §3.3-4
 *      「第二数据源」承诺的可验证点
 *
 * 使用：
 *   import 'sync_test_support.dart';
 *   final keyring = makeTestKeyring(dataKey: dk);
 *   final engine = SyncEngine(..., journal: makeTestJournal());
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:typed_data';

// Package 导入
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/journal.dart';
import 'package:safenotes/sync/keyring.dart';
import 'package:safenotes/sync/sync_models.dart';

// ──────────────────────────────────────────────
// Keyring 构造
// ──────────────────────────────────────────────

/// 造一个测试用 Keyring（P2 之前各测试里那坨 `Vault(...)` 的替代品）
///
/// 默认行为对齐旧 `Vault(...)` 测试语义：
///   - [encryptedDataKey] 省略时用 dataKey **自包装**（wrapDataKey(dk, dk)）。
///     这不是生产语义（生产是 MK 包裹），但测试里多设备共用同一
///     encryptedDataKey 时 checkMigrationNeeded 会直接比对字符串相等而返回
///     "无需迁移"，因此不需要真 MK，省掉每个测试跑 20 万轮 PBKDF2。
///   - [keyFingerprint] 默认空串，与旧测试一致（空指纹 = 不参与指纹校验分支）。
///
/// [mk] 需要走改密码/迁移真实路径的测试才传。
///
/// 注意：Keyring 已移除 history（密钥历史归档），本函数不再接受该参数。
Keyring makeTestKeyring({
  Uint8List? dataKey,
  String? vaultId,
  String? encryptedDataKey,
  String keyFingerprint = '',
  int keyVersion = 1,
  int dataKeyEpoch = 1,
  String reason = KeyringReason.create,
  KdfParams? kdf,
  int? createdAt,
  Uint8List? mk,
}) {
  final dk = dataKey ?? SyncCrypto.generateDataKey();
  // wrapDataKey 已是异步 API。这里默认用一个稳定的假信封（60 字节 = 12+32+16）
  // 作为 encryptedDataKey：测试语义不变——多设备共用同一 edk 时
  // checkMigrationNeeded 按字符串相等直接判定「无需迁移」，不真正解包。
  final edk = encryptedDataKey ??
      base64Encode(Uint8List(60)..fillRange(0, 60, 0xAB));
  return Keyring(
    vaultId: vaultId ?? 'test-keyring-id',
    kdf: kdf ?? KdfParams.create(salt: SyncCrypto.generateSalt()),
    createdAt: createdAt ?? DateTime.now().millisecondsSinceEpoch,
    current: KeyringEntry(
      keyFingerprint: keyFingerprint,
      encryptedDataKey: edk,
      keyVersion: keyVersion,
      dataKeyEpoch: dataKeyEpoch,
      reason: reason,
    ),
    dataKey: dk,
    mk: mk,
  );
}

// ──────────────────────────────────────────────
// Journal 构造
// ──────────────────────────────────────────────

/// 造一个内存模式 Journal
///
/// 绝大多数测试不关心 journal 落盘，只需要 SyncEngine 能跑起来。内存模式
/// 不碰文件系统 → 不需要临时目录、不需要清理、并行跑测试也不会互相踩。
///
/// 真正要验证滚动/归档/远端副本的测试请用 [Journal.open] 配临时目录。
Journal makeTestJournal({
  String vaultId = 'test-keyring-id',
  String deviceId = 'test-device',
}) =>
    Journal.inMemory(vaultId: vaultId, deviceId: deviceId);

// ──────────────────────────────────────────────
// 持久化断言辅助
// ──────────────────────────────────────────────

/// 读回落盘的 Keyring 账本
///
/// P2 之前测试是逐个 `getMeta(MetaKeys.encryptedDataKey)` 断言散落键；
/// P2 起密钥态只写 `MetaKeys.keyring` 一个 JSON 键（单键 setMeta 原子，
/// 杜绝多键双写半成功），旧断言全部会读到 null。用这组 helper 替换。
Future<KeyringLedger?> readPersistedKeyring(NotesDatabase database) =>
    KeyringLedger.load(database);

/// 读回落盘的 current.encryptedDataKey（账本不存在返回 null）
Future<String?> persistedEncryptedDataKey(NotesDatabase database) async =>
    (await readPersistedKeyring(database))?.current.encryptedDataKey;

/// 把测试用 Keyring 账本写落到数据库（P2 单键 `keyring` JSON）
///
/// 替代旧测试里 `setMeta(MetaKeys.encryptedDataKey, ...)` + `setMeta(
/// MetaKeys.vaultId, ...)` 的散落键写法——P2 起密钥态只落单键，且
/// `createNew`/`migrateToRemote`/`adoptRemoteEpoch` 之外引擎不会自动落盘，
/// 需要在建引擎前把初始账本持久化，后续断言 `persistedXxx` 才有意义。
Future<void> persistTestKeyring(
  NotesDatabase database, {
  required String encryptedDataKey,
  String vaultId = 'test-keyring-id',
  String keyFingerprint = '',
  int keyVersion = 1,
  int dataKeyEpoch = 1,
  String reason = KeyringReason.create,
  KdfParams? kdf,
  int? createdAt,
}) async {
  await KeyringLedger(
    vaultId: vaultId,
    kdf: kdf ?? KdfParams.create(salt: SyncCrypto.generateSalt()),
    createdAt: createdAt ?? DateTime.now().millisecondsSinceEpoch,
    current: KeyringEntry(
      keyFingerprint: keyFingerprint,
      encryptedDataKey: encryptedDataKey,
      keyVersion: keyVersion,
      dataKeyEpoch: dataKeyEpoch,
      reason: reason,
    ),
  ).persist(database);
}

/// 读回落盘的 current.keyVersion（账本不存在返回 null）
Future<int?> persistedKeyVersion(NotesDatabase database) async =>
    (await readPersistedKeyring(database))?.current.keyVersion;

/// 读回落盘的 current.keyFingerprint（账本不存在返回 null）
Future<String?> persistedKeyFingerprint(NotesDatabase database) async =>
    (await readPersistedKeyring(database))?.current.keyFingerprint;

/// 读回落盘的 current.dataKeyEpoch（账本不存在返回 null）
Future<int?> persistedDataKeyEpoch(NotesDatabase database) async =>
    (await readPersistedKeyring(database))?.current.dataKeyEpoch;

// ──────────────────────────────────────────────
// FakeBackend 的 journal 能力
// ──────────────────────────────────────────────

/// 给 `implements SyncBackend` 的测试替身补齐 journal 三件套
///
/// 为什么是 mixin 而不是让 FakeBackend `extends` 某个基类：现有 4 个
/// FakeBackend 都是 `implements SyncBackend`（各自有完全不同的内部结构和
/// 故障注入开关），改成继承会牵动一大片。mixin 只加不改，风险最小。
///
/// 存储是真实的内存 Map：测试可以直接读 [journalObjects] 断言远端副本内容，
/// 也可以手动塞进去模拟「他端上传过 journal」。
mixin FakeJournalStore {
  /// 远端 journal 对象（name → 密文），密文由 Journal 层用 dataKey 加密
  final Map<String, Uint8List> journalObjects = <String, Uint8List>{};

  Future<void> putJournalObject(String name, Uint8List ciphertext) async {
    journalObjects[name] = ciphertext;
  }

  Future<Uint8List?> getJournalObject(String name) async =>
      journalObjects[name];

  Future<List<String>> listJournalObjects() async =>
      journalObjects.keys.toList()..sort();
}
