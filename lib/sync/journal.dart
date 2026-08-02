/*
 * Journal 操作日志（P2 设计 §3）
 *
 * 双角色（docs/p2-keyring-journal-design-fixed.md §3.1）：
 *   1. 审计 / 可观测：记录"谁、何时、用哪个 dataKey 纪元"做了什么，
 *      冲突与自愈可诊断，替代 P0-2「blob 自描述」方案（不污染 blob 格式）。
 *   2. 可恢复：作为跨边界部分写的兜底、以及防服务端 manifest 单点故障的
 *      第二数据源。
 *
 * 职责边界（§3.1 / §3.6a，非常重要）：
 *   - **进程内崩溃原子性由 SQLite 事务负责，Journal 不替代它**。
 *     reEncryptAllNotes 等批量写已在单事务内（database_handler.dart），
 *     事务内崩溃自动回滚，Journal 不参与。
 *   - Journal 覆盖 SQLite 管不到的失效模式：
 *     跨边界部分写（blob 已重写但 manifest item 未更新）、本地库被清、
 *     服务端 manifest 损坏、坏纪元污染 key state。
 *
 * 写入约束（§3.6b）：
 *   - **不在 DB 事务内写**（事务回滚会让 journal 与 DB 不一致）；
 *     采用"记录意图(start) → DB 事务提交后记录完成(done)"两段式，
 *     恢复时以 DB 实际状态为准，journal 只提供事件序列。
 *   - 内存缓冲 + 批量异步 flush（累积 50 条或 100ms），不阻塞同步主流程。
 *
 * 存储（§3.3）：
 *   <baseDir>/journal/
 *   ├── log.json              # 当前日志（明文 JSON）
 *   ├── log-<seq>.json        # 归档（保留最近 3 个）
 *   └── .journal-state.json   # 远端上传水位等本地状态
 *   滚动阈值：1000 条 或 100KB（先到者），归档保留 3 份。
 *
 * 远端副本（§3.3-4 / §3.6c）：
 *   同步成功后把「未上传的归档 + 当前日志尾部」整体 AES-GCM(dataKey) 加密，
 *   经 SyncBackend 的 journal 资源接口写到远端 `journal/` 目录，
 *   作为防单点故障的第二数据源。**远端永不写明文。**
 *
 * 本地明文的安全边界：
 *   条目只含 uuid / contentHash / 纪元号 / 设备号，**不含笔记明文**；
 *   key.* 条目可携带 encryptedDataKey（MK 包裹态），其暴露面与本地
 *   sync_meta 的 `keyring` 键、以及远端 manifest 明文 header 完全一致，
 *   不引入新的泄露面。
 */

// Dart 原生导入
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// Package 导入
import 'package:path/path.dart' as p;

// Project 导入
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_backend.dart';
import 'package:safenotes/utils/app_logger.dart';

// ──────────────────────────────────────────────
// 常量
// ──────────────────────────────────────────────

/// Journal 文件格式版本（§3.2：预留版本号，避免未来迁移无版本可依）
const int kJournalSchemaVersion = 1;

/// 单个日志文件最大条目数（§3.3-3 首版默认值）
const int kJournalMaxEntries = 1000;

/// 单个日志文件最大字节数（§3.3-3 首版默认值：100KB）
const int kJournalMaxBytes = 100 * 1024;

/// 归档保留份数（§3.3-3：保留最近 3 个归档）
const int kJournalArchiveKeep = 3;

/// 批量 flush 的条目阈值（§3.6b：累积 50 条立即落盘）
const int kJournalFlushBatchSize = 50;

/// 批量 flush 的时间阈值（§3.6b：100ms 定时落盘）
const Duration kJournalFlushInterval = Duration(milliseconds: 100);

/// 远端副本加密 AAD（AES-GCM 附加认证数据）
const String kJournalAad = 'journal-archive';

// ──────────────────────────────────────────────
// 事件类型与阶段
// ──────────────────────────────────────────────

/// Journal 事件类型（§3.2 的 `type` 字段）
///
/// 命名沿用设计文档的点分命名空间，wire 值即文档中的字符串。
enum JournalEventType {
  /// 笔记新增/更新（上传 blob 或下载落库）
  noteUpsert('note.upsert'),

  /// 笔记删除（墓碑）
  noteDelete('note.delete'),

  /// LWW 冲突裁决（谁赢、是否保留败方副本）
  ///
  /// 设计 §3.2 的类型清单是示例性列举，未显式包含本项；但 §3.1 明确要求
  /// "冲突/自愈可诊断"，而"我的修改为什么不见了"正是最高频的用户问题——
  /// 没有冲突事件就无法回答。故按同一点分命名空间补充。
  noteConflict('note.conflict'),

  /// 自愈：用历史密钥解密并重新上传
  noteHeal('note.heal'),

  /// blob 重传（纪元变化后的重新加密上传）
  blobReupload('blob.reupload'),

  /// 改密码（MK 变化，dataKey 不变）
  keyChangePassword('key.changePassword'),

  /// dataKey 迁移（scenario-c/d，dataKey 真的变了）
  keyMigrate('key.migrate'),

  /// 采纳远端纪元（他端改密码后本端同步纪元三元组）
  keyAdoptEpoch('key.adoptEpoch'),

  /// 孤儿 blob 垃圾回收
  syncGcOrphan('sync.gcOrphan'),

  /// 远端 manifest 损坏并重建（第二数据源价值最高的事件）
  syncManifestRebuild('sync.manifestRebuild'),

  /// manifest PUT 成功/失败（P3-c，同步流程关键节点）
  ///
  /// 记录每次 manifest 落地的结果（phase=done 成功 / failed 失败），
  /// note 携带 version、attempt、是否备份了旧 manifest 等上下文。
  /// 与 [syncManifestRebuild] 区分：后者是「损坏后用本地数据重建」的异常
  /// 路径，本项是「正常合并后写回远端」的常规路径。
  syncManifestPut('sync.manifestPut'),

  /// 乐观锁冲突重试（P3-c，ETag 不匹配触发的回退重试）
  ///
  /// PUT manifest 时 ETag 不匹配（他端先 PUT 了）会抛 ConflictException，
  /// 引擎回到 Step 1 重新拉取并重试。记录重试次数与最终是否成功，便于
  /// 诊断「频繁冲突重试」类问题（多设备高并发写入竞争）。
  syncOptimisticLockRetry('sync.optimisticLockRetry');

  const JournalEventType(this.wire);

  /// 序列化字符串
  final String wire;

  /// 从 wire 字符串解析；未知值返回 null（健壮性：无法识别的类型跳过而非崩溃）
  static JournalEventType? fromWire(String value) {
    for (final t in JournalEventType.values) {
      if (t.wire == value) return t;
    }
    return null;
  }

  /// 是否为密钥状态相关事件（用于 replayKeyState 过滤）
  bool get isKeyEvent =>
      this == keyChangePassword ||
      this == keyMigrate ||
      this == keyAdoptEpoch;
}

/// 事件阶段（对设计 §3.6b「两段式记录」的机器可读实现）
///
/// 设计文档用 `key.migrate(start)` / `sync.gcOrphan(isolated)` 这种括号写法
/// 表达阶段。实现上**不把阶段塞进人类可读的 `note` 字段**——重放逻辑依赖
/// 自然语言字符串是脆弱的。这里提升为独立的机器可读字段 `phase`，
/// `type` 保持与文档完全一致。
enum JournalPhase {
  /// 无阶段（一次性事件）
  none('none'),

  /// 意图已记录，副作用尚未确认完成
  start('start'),

  /// 副作用已完成（DB 事务已提交）
  done('done'),

  /// 操作失败/放弃（避免 start 悬挂被误判为需要重放）
  failed('failed'),

  /// GC：已移入隔离区（软删除）
  isolated('isolated'),

  /// GC：隔离区超期结算，物理删除
  purged('purged');

  const JournalPhase(this.wire);

  final String wire;

  static JournalPhase fromWire(String? value) {
    if (value == null) return JournalPhase.none;
    for (final t in JournalPhase.values) {
      if (t.wire == value) return t;
    }
    return JournalPhase.none;
  }
}

// ──────────────────────────────────────────────
// 密钥状态快照
// ──────────────────────────────────────────────

/// key.* 事件携带的密钥状态三元组（§3.6c 重放 key state 所需）
///
/// 只含**包裹态** encryptedDataKey（AES-GCM(MK, dataKey)），
/// 不含 raw dataKey / MK，泄露面与 manifest 明文 header 一致。
class JournalKeyState {
  final int keyVersion;
  final int dataKeyEpoch;
  final String keyFingerprint;
  final String encryptedDataKey;

  const JournalKeyState({
    required this.keyVersion,
    required this.dataKeyEpoch,
    required this.keyFingerprint,
    required this.encryptedDataKey,
  });

  Map<String, Object?> toJson() => {
        'keyVersion': keyVersion,
        'dataKeyEpoch': dataKeyEpoch,
        'keyFingerprint': keyFingerprint,
        'encryptedDataKey': encryptedDataKey,
      };

  static JournalKeyState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final keyVersion = raw['keyVersion'];
    final dataKeyEpoch = raw['dataKeyEpoch'];
    final fp = raw['keyFingerprint'];
    final edk = raw['encryptedDataKey'];
    if (keyVersion is! int ||
        dataKeyEpoch is! int ||
        fp is! String ||
        edk is! String) {
      return null;
    }
    return JournalKeyState(
      keyVersion: keyVersion,
      dataKeyEpoch: dataKeyEpoch,
      keyFingerprint: fp,
      encryptedDataKey: edk,
    );
  }

  @override
  String toString() =>
      'JournalKeyState(v=$keyVersion, epoch=$dataKeyEpoch, '
      'fp=${keyFingerprint.length > 8 ? keyFingerprint.substring(0, 8) : keyFingerprint}…)';
}

// ──────────────────────────────────────────────
// 条目
// ──────────────────────────────────────────────

/// 单条 Journal 条目（§3.2）
class JournalEntry {
  /// 设备内全局单调递增序号（跨归档文件连续，不 per-file 重置）
  final int seq;

  /// 事件时间戳（epoch ms）
  final int ts;

  /// 事件类型
  final JournalEventType type;

  /// 事件阶段（两段式记录用）
  final JournalPhase phase;

  /// 相关笔记 uuid（笔记类事件）
  final String? uuid;

  /// 相关 blob 内容 hash
  final String? hash;

  /// 事件发生时所用的 dataKey 纪元
  ///
  /// **语义澄清（§3.2 / 评审 A-P2#6）**：该字段仅记录"当时用的是哪个纪元"，
  /// **不参与 journal 内部时序判断**。纪元推进以 key.* 事件顺序为准。
  final int? dataKeyEpoch;

  /// 记录者设备 id
  final String by;

  /// 跨步操作关联 id（start / done 配对用）
  final String? opId;

  /// 密钥状态（仅 key.* 事件）
  final JournalKeyState? keyState;

  /// 可选人类可读说明（**不参与任何机器判定**）
  final String? note;

  const JournalEntry({
    required this.seq,
    required this.ts,
    required this.type,
    this.phase = JournalPhase.none,
    this.uuid,
    this.hash,
    this.dataKeyEpoch,
    required this.by,
    this.opId,
    this.keyState,
    this.note,
  });

  Map<String, Object?> toJson() => {
        'seq': seq,
        'ts': ts,
        'type': type.wire,
        if (phase != JournalPhase.none) 'phase': phase.wire,
        if (uuid != null) 'uuid': uuid,
        if (hash != null) 'hash': hash,
        if (dataKeyEpoch != null) 'dataKeyEpoch': dataKeyEpoch,
        'by': by,
        if (opId != null) 'opId': opId,
        if (keyState != null) 'keyState': keyState!.toJson(),
        if (note != null) 'note': note,
      };

  /// 反序列化；格式不合法或类型未知时返回 null（跳过坏条目而非整体失败）
  static JournalEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final seq = raw['seq'];
    final ts = raw['ts'];
    final typeWire = raw['type'];
    final by = raw['by'];
    if (seq is! int || ts is! int || typeWire is! String || by is! String) {
      return null;
    }
    final type = JournalEventType.fromWire(typeWire);
    if (type == null) return null;
    final epoch = raw['dataKeyEpoch'];
    return JournalEntry(
      seq: seq,
      ts: ts,
      type: type,
      phase: JournalPhase.fromWire(raw['phase'] as String?),
      uuid: raw['uuid'] as String?,
      hash: raw['hash'] as String?,
      dataKeyEpoch: epoch is int ? epoch : null,
      by: by,
      opId: raw['opId'] as String?,
      keyState: JournalKeyState.fromJson(raw['keyState']),
      note: raw['note'] as String?,
    );
  }

  @override
  String toString() => 'JournalEntry(#$seq ${type.wire}'
      '${phase == JournalPhase.none ? '' : '/${phase.wire}'}'
      '${uuid == null ? '' : ' uuid=$uuid'}'
      '${dataKeyEpoch == null ? '' : ' epoch=$dataKeyEpoch'} by=$by)';
}

/// 未完成的跨步操作（start 无匹配 done/failed）
class IncompleteOperation {
  final JournalEntry start;

  /// 距今时长（用于判断是"正在进行"还是"确已中断"）
  final Duration age;

  const IncompleteOperation({required this.start, required this.age});

  @override
  String toString() =>
      'IncompleteOperation(${start.type.wire} opId=${start.opId} '
      'age=${age.inSeconds}s)';
}

// ──────────────────────────────────────────────
// Journal 主体
// ──────────────────────────────────────────────

/// 操作日志（本地优先 + 远端加密副本）
///
/// 生命周期：由 [Journal.open] 创建（读入当前日志、恢复 seq 水位），
/// 由 [SyncEngine] 持有并在关键节点 [append]，应用退出时 [close]。
class Journal {
  /// journal 目录绝对路径（`<baseDir>/journal`）
  final String dirPath;

  /// 所属 vault（用于校验 journal 与库匹配，防串库）
  final String vaultId;

  /// 本机设备 id
  final String deviceId;

  /// 当前日志文件中已落盘的条目
  final List<JournalEntry> _entries;

  /// 待落盘缓冲（未 flush）
  final List<JournalEntry> _pending = [];

  /// 下一个 seq
  int _nextSeq;

  /// 已上传到远端的最大 seq（远端副本水位）
  int _uploadedSeq;

  Timer? _flushTimer;

  /// 串行化写盘的 future 链（避免并发写同一文件）
  Future<void> _writeChain = Future<void>.value();

  bool _closed = false;

  /// 内存模式：不做任何文件 I/O
  ///
  /// 用途：单元测试免去临时目录管理（[Journal.inMemory]）。
  final bool _memoryOnly;

  // 说明：Dart 不允许**私有**命名参数（`this._entries` 形式非法），
  // 因此这里只能用普通命名参数 + 初始化列表赋值，无法采用 initializing formal。
  // ignore_for_file: prefer_initializing_formals
  Journal._({
    required this.dirPath,
    required this.vaultId,
    required this.deviceId,
    required List<JournalEntry> entries,
    required int nextSeq,
    required int uploadedSeq,
    bool memoryOnly = false,
  })  : _entries = entries,
        _nextSeq = nextSeq,
        _uploadedSeq = uploadedSeq,
        _memoryOnly = memoryOnly;

  /// 内存 journal（无文件 I/O）
  ///
  /// 用于单元测试。语义与文件模式一致，只是不落盘、不归档、不上传远端。
  factory Journal.inMemory({
    String vaultId = '',
    String deviceId = 'memory',
  }) =>
      Journal._(
        dirPath: '',
        vaultId: vaultId,
        deviceId: deviceId,
        entries: [],
        nextSeq: 1,
        uploadedSeq: 0,
        memoryOnly: true,
      );

  // ──────────────────────────────────────────────
  // 路径
  // ──────────────────────────────────────────────

  String get _logPath => p.join(dirPath, 'log.json');
  String get _statePath => p.join(dirPath, '.journal-state.json');
  String _archivePath(int seq) => p.join(dirPath, 'log-$seq.json');

  /// 远端当前日志副本对象名（按设备隔离，避免多端互相覆盖）
  String get remoteCurrentName => '$deviceId-current.json';

  /// 远端归档副本对象名
  String remoteArchiveName(int seq) => '$deviceId-archive-$seq.json';

  // ──────────────────────────────────────────────
  // 打开 / 关闭
  // ──────────────────────────────────────────────

  /// 打开（或创建）journal
  ///
  /// [baseDir] App 沙盒基础目录（生产用 path_provider 解析，测试传临时目录）。
  /// journal 实际落在 `<baseDir>/journal/`。
  ///
  /// 读取失败（文件损坏 / JSON 非法）时**不抛异常**：损坏文件被重命名为
  /// `log.json.corrupt-<ts>` 保留取证，journal 以空日志继续工作。
  /// 理由：journal 是辅助设施，它自身的损坏绝不能阻断同步主流程。
  static Future<Journal> open({
    required String baseDir,
    required String vaultId,
    required String deviceId,
  }) async {
    final dirPath = p.join(baseDir, 'journal');
    await Directory(dirPath).create(recursive: true);

    final journal = Journal._(
      dirPath: dirPath,
      vaultId: vaultId,
      deviceId: deviceId,
      entries: [],
      nextSeq: 1,
      uploadedSeq: 0,
    );

    // 1. 读当前日志
    final file = File(journal._logPath);
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        final parsed = _parseLogMap(decoded, expectVaultId: vaultId);
        journal._entries.addAll(parsed.entries);
        if (parsed.vaultMismatch) {
          // 串库保护：journal 属于别的 vault → 归档隔离，重新开始
          Log.sync.w('[Journal] vaultId 不匹配（file=${parsed.vaultId}, '
              'expect=$vaultId），隔离旧 journal 并重新开始');
          journal._entries.clear();
          await journal._quarantineCurrentLog('vault-mismatch');
        }
      } on Exception catch (e) {
        Log.sync.w('[Journal] 当前日志解析失败，隔离后以空日志继续', error: e);
        journal._entries.clear();
        await journal._quarantineCurrentLog('corrupt');
      } on Error catch (e) {
        // jsonDecode 对某些坏输入抛 Error 而非 Exception
        Log.sync.w('[Journal] 当前日志解析异常，隔离后以空日志继续',
            error: StateError('$e'));
        journal._entries.clear();
        await journal._quarantineCurrentLog('corrupt');
      }
    }

    // 2. seq 水位 = max(当前日志最大 seq, 归档最大 seq) + 1
    var maxSeq = 0;
    for (final e in journal._entries) {
      if (e.seq > maxSeq) maxSeq = e.seq;
    }
    for (final seq in await journal._listArchiveSeqs()) {
      if (seq > maxSeq) maxSeq = seq;
    }
    journal._nextSeq = maxSeq + 1;

    // 3. 本地状态（远端上传水位）
    try {
      final stateFile = File(journal._statePath);
      if (await stateFile.exists()) {
        final raw = jsonDecode(await stateFile.readAsString());
        if (raw is Map && raw['uploadedSeq'] is int) {
          journal._uploadedSeq = raw['uploadedSeq'] as int;
        }
      }
    } on Exception catch (e) {
      Log.sync.d('[Journal] 状态文件读取失败，上传水位归零', error: e);
    } on Error {
      journal._uploadedSeq = 0;
    }

    Log.sync.d('[Journal] 打开 dir=$dirPath entries=${journal._entries.length} '
        'nextSeq=${journal._nextSeq} uploadedSeq=${journal._uploadedSeq}');
    return journal;
  }

  /// 关闭：flush 残留缓冲并停掉定时器
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
  }

  // ──────────────────────────────────────────────
  // 追加
  // ──────────────────────────────────────────────

  /// 追加一条日志（**非阻塞**：只入内存缓冲，落盘由批量 flush 完成）
  ///
  /// 返回本条的 seq（供调用方在 done 阶段引用；跨步操作请用 [opId] 配对）。
  ///
  /// **绝不抛异常**：journal 失败不能影响同步主流程。
  int append({
    required JournalEventType type,
    JournalPhase phase = JournalPhase.none,
    String? uuid,
    String? hash,
    int? dataKeyEpoch,
    String? opId,
    JournalKeyState? keyState,
    String? note,
  }) {
    if (_closed) return -1;
    final seq = _nextSeq++;
    _pending.add(JournalEntry(
      seq: seq,
      ts: DateTime.now().millisecondsSinceEpoch,
      type: type,
      phase: phase,
      uuid: uuid,
      hash: hash,
      dataKeyEpoch: dataKeyEpoch,
      by: deviceId,
      opId: opId,
      keyState: keyState,
      note: note,
    ));
    _scheduleFlush();
    return seq;
  }

  /// 生成一个跨步操作 id（start/done 配对用）
  String newOpId() {
    final rnd = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}-$rnd';
  }

  void _scheduleFlush() {
    if (_pending.length >= kJournalFlushBatchSize) {
      // 累积够一批：立即落盘（不 await，不阻塞调用方）
      _flushTimer?.cancel();
      _flushTimer = null;
      unawaited(flush());
      return;
    }
    _flushTimer ??= Timer(kJournalFlushInterval, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  /// 立即把缓冲写盘（幂等）
  ///
  /// 写盘串行化：多次并发调用会排队执行，不会产生交错写。
  ///
  /// **即使缓冲为空也要等待已排队的写盘完成**：批量 flush 是
  /// `unawaited(flush())` 触发的，缓冲可能已被前一个 `_doFlush` 取走但尚未
  /// 落盘。此时若直接返回，调用方（readAll / syncToRemote / close）会读到
  /// 不完整的文件内容。这是"看起来无害的快速返回"埋的真实竞态。
  Future<void> flush() async {
    if (_pending.isEmpty) {
      await _writeChain;
      return;
    }
    final chained = _writeChain.then((_) => _doFlush());
    // 单点吞掉异常，保证 _writeChain 永不进入 error 状态导致后续全挂
    _writeChain = chained.catchError((Object e) {
      Log.sync.w('[Journal] flush 失败（已忽略，不影响同步）',
          error: e is Exception ? e : StateError('$e'));
    });
    await _writeChain;
  }

  Future<void> _doFlush() async {
    if (_pending.isEmpty) return;
    final batch = List<JournalEntry>.from(_pending);
    _pending.clear();
    _entries.addAll(batch);
    await _writeLogFile();
    await _rollIfNeeded();
  }

  /// 原子写当前日志（先写 .tmp 再 rename，避免半写损坏）
  Future<void> _writeLogFile() async {
    if (_memoryOnly) return;
    final payload = jsonEncode({
      'schemaVersion': kJournalSchemaVersion,
      'vaultId': vaultId,
      'deviceId': deviceId,
      'entries': _entries.map((e) => e.toJson()).toList(),
    });
    final tmp = File('$_logPath.tmp');
    await tmp.writeAsString(payload, flush: true);
    await tmp.rename(_logPath);
  }

  // ──────────────────────────────────────────────
  // 滚动归档
  // ──────────────────────────────────────────────

  /// 达到阈值（1000 条 或 100KB）则归档当前日志
  Future<void> _rollIfNeeded() async {
    if (_memoryOnly) {
      // 内存模式无归档概念，但仍需限制内存占用：保留最近 kJournalMaxEntries 条
      if (_entries.length > kJournalMaxEntries) {
        _entries.removeRange(0, _entries.length - kJournalMaxEntries);
      }
      return;
    }
    if (_entries.isEmpty) return;
    var shouldRoll = _entries.length >= kJournalMaxEntries;
    if (!shouldRoll) {
      try {
        final size = await File(_logPath).length();
        shouldRoll = size >= kJournalMaxBytes;
      } on Exception {
        return;
      }
    }
    if (!shouldRoll) return;

    final lastSeq = _entries.last.seq;
    try {
      await File(_logPath).rename(_archivePath(lastSeq));
    } on Exception catch (e) {
      Log.sync.w('[Journal] 归档重命名失败，继续沿用当前日志', error: e);
      return;
    }
    _entries.clear();
    await _writeLogFile(); // 立即建立空的新日志，保证文件恒存在
    await _pruneArchives();
    Log.sync.d('[Journal] 已归档 log-$lastSeq.json');
  }

  /// 保留最近 [kJournalArchiveKeep] 个归档，其余删除
  ///
  /// 删除**尚未上传远端**的归档时打警告：这意味着这段历史将只存在于
  /// 已被覆盖的本地文件中（即彻底丢失），是可恢复能力的缺口。
  Future<void> _pruneArchives() async {
    final seqs = await _listArchiveSeqs();
    if (seqs.length <= kJournalArchiveKeep) return;
    seqs.sort();
    final toDelete = seqs.sublist(0, seqs.length - kJournalArchiveKeep);
    for (final seq in toDelete) {
      if (seq > _uploadedSeq) {
        Log.sync.w('[Journal] 归档 log-$seq.json 尚未上传远端即被淘汰，'
            '该段历史将不可恢复（uploadedSeq=$_uploadedSeq）');
      }
      try {
        await File(_archivePath(seq)).delete();
      } on Exception catch (e) {
        Log.sync.d('[Journal] 删除归档 log-$seq.json 失败', error: e);
      }
    }
  }

  Future<List<int>> _listArchiveSeqs() async {
    if (_memoryOnly) return [];
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];
    final re = RegExp(r'^log-(\d+)\.json$');
    final result = <int>[];
    await for (final entity in dir.list()) {
      if (entity is File) {
        final m = re.firstMatch(p.basename(entity.path));
        if (m != null) {
          final v = int.tryParse(m.group(1)!);
          if (v != null) result.add(v);
        }
      }
    }
    return result;
  }

  /// 把当前日志隔离为 `log.json.<reason>-<ts>`，用于取证
  Future<void> _quarantineCurrentLog(String reason) async {
    try {
      final file = File(_logPath);
      if (await file.exists()) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        await file.rename('$_logPath.$reason-$ts');
      }
    } on Exception catch (e) {
      Log.sync.d('[Journal] 隔离损坏日志失败', error: e);
    }
  }

  // ──────────────────────────────────────────────
  // 读取 / 查询
  // ──────────────────────────────────────────────

  /// 当前日志中已落盘的条目（不含未 flush 的缓冲）
  List<JournalEntry> get entries => List.unmodifiable(_entries);

  /// 待落盘条目数（诊断用）
  int get pendingCount => _pending.length;

  /// 下一个 seq（诊断/测试用）
  int get nextSeq => _nextSeq;

  /// 远端已上传水位
  int get uploadedSeq => _uploadedSeq;

  /// 读取全部条目（归档 + 当前日志），按 seq 升序
  ///
  /// [sinceSeq] 只返回 seq > sinceSeq 的条目。
  Future<List<JournalEntry>> readAll({int sinceSeq = 0}) async {
    await flush();
    final all = <JournalEntry>[];
    final seqs = await _listArchiveSeqs()
      ..sort();
    for (final seq in seqs) {
      try {
        final raw = jsonDecode(await File(_archivePath(seq)).readAsString());
        all.addAll(_parseLogMap(raw, expectVaultId: vaultId).entries);
      } on Exception catch (e) {
        Log.sync.w('[Journal] 归档 log-$seq.json 解析失败，跳过', error: e);
      } on Error catch (e) {
        Log.sync.w('[Journal] 归档 log-$seq.json 解析异常，跳过',
            error: StateError('$e'));
      }
    }
    all.addAll(_entries);
    final filtered = all.where((e) => e.seq > sinceSeq).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return filtered;
  }

  // ──────────────────────────────────────────────
  // 恢复：可重放 + 第二数据源（§3.6）
  // ──────────────────────────────────────────────

  /// 找出未完成的跨步操作（有 start，无对应 done/failed）
  ///
  /// **恢复语义（§3.6b，务必理解）**：本方法只回答"哪些跨步操作没有记录完成"，
  /// **不自动执行任何补偿动作**。恢复始终**以 DB 实际状态为准**，journal 只是
  /// 线索。理由：journal 不在事务内写，"start 无 done"既可能是真的中断，
  /// 也可能是 done 条目未来得及落盘——盲目重放会把"恢复"变成"二次损坏"。
  ///
  /// [minAge] 只返回早于该时长的 start（默认 30s），过滤掉正在进行的操作。
  Future<List<IncompleteOperation>> findIncompleteOperations({
    Duration minAge = const Duration(seconds: 30),
  }) async {
    final all = await readAll();
    final now = DateTime.now().millisecondsSinceEpoch;

    // 已完成/已失败的 opId 集合
    final settled = <String>{};
    for (final e in all) {
      if (e.opId == null) continue;
      if (e.phase == JournalPhase.done || e.phase == JournalPhase.failed) {
        settled.add(e.opId!);
      }
    }

    final result = <IncompleteOperation>[];
    for (final e in all) {
      if (e.phase != JournalPhase.start) continue;
      if (e.opId != null && settled.contains(e.opId)) continue;
      final age = Duration(milliseconds: now - e.ts);
      if (age < minAge) continue;
      result.add(IncompleteOperation(start: e, age: age));
    }
    return result;
  }

  /// 从事件序列重放出最新的密钥状态（§3.6c：坏纪元污染时的取真来源）
  ///
  /// 取所有 key.* 事件中携带 keyState 的最新一条（按 seq）。
  /// 返回 null 表示 journal 中没有可用的密钥状态记录。
  ///
  /// **用途**：当 `keyring.current` 被坏纪元覆盖时，用本结果 + 本地 history
  /// 中的旧 wrappedDataKey 还原正确 key state。**调用方必须验证**还原出的
  /// encryptedDataKey 能被当前 MK 解开，再决定是否采纳。
  Future<JournalKeyState?> replayKeyState() async {
    final all = await readAll();
    JournalKeyState? latest;
    var latestSeq = -1;
    for (final e in all) {
      if (!e.type.isKeyEvent) continue;
      if (e.phase == JournalPhase.start || e.phase == JournalPhase.failed) {
        continue; // 只采纳已完成的密钥变更
      }
      final ks = e.keyState;
      if (ks == null) continue;
      if (e.seq > latestSeq) {
        latest = ks;
        latestSeq = e.seq;
      }
    }
    return latest;
  }

  /// 统计摘要（诊断页 / 测试断言用）
  Future<Map<String, Object?>> stats() async {
    final all = await readAll();
    final byType = <String, int>{};
    for (final e in all) {
      byType[e.type.wire] = (byType[e.type.wire] ?? 0) + 1;
    }
    return {
      'total': all.length,
      'current': _entries.length,
      'pending': _pending.length,
      'nextSeq': _nextSeq,
      'uploadedSeq': _uploadedSeq,
      'archives': (await _listArchiveSeqs()).length,
      'byType': byType,
    };
  }

  // ──────────────────────────────────────────────
  // 远端加密副本（§3.3-4 / §3.6c）
  // ──────────────────────────────────────────────

  /// 把未上传的日志内容加密上传到远端（防单点故障的第二数据源）
  ///
  /// 上传两类对象：
  ///   1. 所有未上传的归档 → `<deviceId>-archive-<seq>.json`
  ///   2. 当前日志（若有新条目）→ `<deviceId>-current.json`（整体覆盖）
  ///
  /// **为什么当前日志也要传**（对设计 §3.3-4「只传归档」的补强）：
  /// key.* 事件极其稀少，等攒够 1000 条才归档意味着关键密钥事件可能几个月
  /// 都不会离开本机——那 §3.6c 承诺的"服务端 manifest 损坏时可从远端 journal
  /// 重建 key state"就是空头支票。代价只是每次同步一个小 PUT。
  ///
  /// 整体 `AES-GCM(dataKey)` 加密，**远端不落明文**。
  /// 后端不支持 journal 资源接口时静默降级（journal 保持本地-only）。
  ///
  /// **绝不抛异常**：失败只记日志，不影响同步结果。
  Future<void> syncToRemote(SyncBackend backend, Uint8List dataKey) async {
    if (_closed || _memoryOnly) return;
    try {
      await flush();

      // 1. 未上传的归档
      final seqs = await _listArchiveSeqs()
        ..sort();
      for (final seq in seqs) {
        if (seq <= _uploadedSeq) continue;
        final bytes = await File(_archivePath(seq)).readAsBytes();
        await backend.putJournalObject(
          remoteArchiveName(seq),
          await SyncCrypto.seal(dataKey, kJournalAad, bytes),
        );
        _uploadedSeq = seq;
      }

      // 2. 当前日志（有新增才传）
      if (_entries.isNotEmpty && _entries.last.seq > _uploadedSeq) {
        final bytes = await File(_logPath).readAsBytes();
        await backend.putJournalObject(
          remoteCurrentName,
          await SyncCrypto.seal(dataKey, kJournalAad, bytes),
        );
        _uploadedSeq = _entries.last.seq;
      }

      await _persistState();
    } on Exception catch (e) {
      Log.sync.d('[Journal] 远端副本上传失败（降级为本地-only）', error: e);
    } on Error catch (e) {
      Log.sync.d('[Journal] 远端副本上传异常（降级为本地-only）',
          error: StateError('$e'));
    }
  }

  Future<void> _persistState() async {
    if (_memoryOnly) return;
    try {
      await File(_statePath).writeAsString(
        jsonEncode({'uploadedSeq': _uploadedSeq}),
        flush: true,
      );
    } on Exception catch (e) {
      Log.sync.d('[Journal] 状态持久化失败', error: e);
    }
  }

  /// 从远端拉取**所有设备**的 journal 副本并解密合并（§3.6c 第二数据源）
  ///
  /// 用于本地库与本地 journal 均丢失（重装 App）且服务端 manifest 不可信时，
  /// 重建 key state 与近期变更序列。
  ///
  /// 返回按 (by, seq) 去重后、按 ts 升序的条目列表。
  /// 解密失败的对象被跳过（可能是别的 vault / 旧 dataKey 纪元的副本）。
  static Future<List<JournalEntry>> fetchRemoteEntries(
    SyncBackend backend,
    Uint8List dataKey,
  ) async {
    final result = <String, JournalEntry>{};
    List<String> names;
    try {
      names = await backend.listJournalObjects();
    } on Exception catch (e) {
      Log.sync.w('[Journal] 列举远端副本失败', error: e);
      return [];
    }
    for (final name in names) {
      try {
        final sealed = await backend.getJournalObject(name);
        if (sealed == null || sealed.isEmpty) continue;
        final plain = await SyncCrypto.open(dataKey, kJournalAad, sealed);
        final raw = jsonDecode(utf8.decode(plain));
        final parsed = _parseLogMap(raw, expectVaultId: null);
        for (final e in parsed.entries) {
          result['${e.by}#${e.seq}'] = e;
        }
      } on Exception catch (e) {
        Log.sync.d('[Journal] 远端副本 $name 解密/解析失败，跳过', error: e);
      } on Error catch (e) {
        Log.sync.d('[Journal] 远端副本 $name 解析异常，跳过',
            error: StateError('$e'));
      }
    }
    final list = result.values.toList()..sort((a, b) => a.ts.compareTo(b.ts));
    return list;
  }

  // ──────────────────────────────────────────────
  // 解析工具
  // ──────────────────────────────────────────────

  static _ParsedLog _parseLogMap(Object? raw, {required String? expectVaultId}) {
    if (raw is! Map) {
      throw const FormatException('journal 根节点不是对象');
    }
    final fileVaultId = raw['vaultId'];
    final entriesRaw = raw['entries'];
    if (entriesRaw is! List) {
      throw const FormatException('journal entries 字段缺失或非数组');
    }
    final entries = <JournalEntry>[];
    for (final item in entriesRaw) {
      final e = JournalEntry.fromJson(item);
      if (e != null) entries.add(e); // 坏条目跳过，不整体失败
    }
    final mismatch = expectVaultId != null &&
        fileVaultId is String &&
        fileVaultId.isNotEmpty &&
        fileVaultId != expectVaultId;
    return _ParsedLog(
      entries: entries,
      vaultId: fileVaultId is String ? fileVaultId : '',
      vaultMismatch: mismatch,
    );
  }
}

class _ParsedLog {
  final List<JournalEntry> entries;
  final String vaultId;
  final bool vaultMismatch;

  const _ParsedLog({
    required this.entries,
    required this.vaultId,
    required this.vaultMismatch,
  });
}
