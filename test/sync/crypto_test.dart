// 加密层单元测试
//
// 验证：PBKDF2 确定性、AES-GCM 往返、dataKey wrap/unwrap、
//       错误密码/AAD 失败、contentHash 确定性。
// 这些测试纯 Windows 可跑，秒级反馈。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:safenotes/sync/crypto.dart';

void main() {
  group('SyncCrypto - PBKDF2 密钥派生', () {
    test('相同密码+salt 派生出相同 MK（确定性）', () async {
      final salt = Uint8List.fromList(List.filled(16, 42));
      final mk1 = await SyncCrypto.deriveMasterKey('mypassword', salt: salt);
      final mk2 = await SyncCrypto.deriveMasterKey('mypassword', salt: salt);
      expect(mk1.length, 32);
      expect(listEquals(mk1, mk2), isTrue);
    });

    test('不同密码派生出不同 MK', () async {
      final salt = Uint8List.fromList(List.filled(16, 42));
      final mk1 = await SyncCrypto.deriveMasterKey('password1', salt: salt);
      final mk2 = await SyncCrypto.deriveMasterKey('password2', salt: salt);
      expect(listEquals(mk1, mk2), isFalse);
    });

    test('不同 salt 派生出不同 MK', () async {
      final salt1 = Uint8List.fromList(List.filled(16, 1));
      final salt2 = Uint8List.fromList(List.filled(16, 2));
      final mk1 = await SyncCrypto.deriveMasterKey('samepassword', salt: salt1);
      final mk2 = await SyncCrypto.deriveMasterKey('samepassword', salt: salt2);
      expect(listEquals(mk1, mk2), isFalse);
    });

    test('MK 长度为 32 字节（AES-256）', () async {
      final salt = SyncCrypto.generateSalt();
      final mk = await SyncCrypto.deriveMasterKey('test', salt: salt);
      expect(mk.length, 32);
    });

    test('自定义迭代次数生效（低迭代用于加速测试）', () async {
      final salt = Uint8List.fromList(List.filled(16, 0));
      final mk = await SyncCrypto.deriveMasterKey('test', salt: salt, iterations: 1000);
      expect(mk.length, 32);
      // 1000 迭代的结果应与 200000 默认值不同
      final mkDefault = await SyncCrypto.deriveMasterKey('test', salt: salt);
      expect(listEquals(mk, mkDefault), isFalse);
    });

    test('相同密码+salt 派生出相同 MK（多端一致性）', () async {
      // 相同密码 + 相同 salt 必定派生出相同 MK（per-vault salt 多端一致性）
      final salt = SyncCrypto.generateSalt();
      final mk1 = await SyncCrypto.deriveMasterKey('samepassword', salt: salt);
      final mk2 = await SyncCrypto.deriveMasterKey('samepassword', salt: salt);
      expect(listEquals(mk1, mk2), isTrue);
    });
  });

  group('SyncCrypto - AES-256-GCM 笔记加密', () {
    test('seal/open 往返：加密后解密还原明文', () async {
      final dataKey = SyncCrypto.generateDataKey();
      const id = 'note-uuid-123';
      final plaintext =
          Uint8List.fromList(utf8.encode('这是一条测试笔记 hello world'));
      final envelope = await SyncCrypto.seal(dataKey, id, plaintext);
      final decrypted = await SyncCrypto.open(dataKey, id, envelope);
      expect(listEquals(decrypted, plaintext), isTrue);
    });

    test('信封格式：nonce(12) ‖ ciphertext ‖ tag(16)', () async {
      final dataKey = SyncCrypto.generateDataKey();
      const id = 'note-uuid';
      final plaintext = Uint8List.fromList(utf8.encode('test'));
      final envelope = await SyncCrypto.seal(dataKey, id, plaintext);
      // 信封长度 = 12 (nonce) + len(plaintext) + 16 (tag)
      expect(envelope.length, 12 + plaintext.length + 16);
    });

    test('相同明文每次加密产生不同信封（随机 nonce）', () async {
      final dataKey = SyncCrypto.generateDataKey();
      const id = 'note-uuid';
      final plaintext = Uint8List.fromList(utf8.encode('same content'));
      final env1 = await SyncCrypto.seal(dataKey, id, plaintext);
      final env2 = await SyncCrypto.seal(dataKey, id, plaintext);
      // 信封不同（nonce 不同）
      expect(listEquals(env1, env2), isFalse);
      // 但都能解出相同明文
      expect(listEquals(await SyncCrypto.open(dataKey, id, env1), plaintext), isTrue);
      expect(listEquals(await SyncCrypto.open(dataKey, id, env2), plaintext), isTrue);
    });

    test('错误密码（错误 dataKey）解密失败抛异常', () async {
      final correctKey = SyncCrypto.generateDataKey();
      final wrongKey = SyncCrypto.generateDataKey();
      const id = 'note-uuid';
      final plaintext = Uint8List.fromList(utf8.encode('secret'));
      final envelope = await SyncCrypto.seal(correctKey, id, plaintext);
      // 用错误 key 解密应抛异常（GCM tag 验证失败）
      await expectLater(
        SyncCrypto.open(wrongKey, id, envelope),
        throwsA(anything),
      );
    });

    test('错误 AAD（笔记 id 不匹配）解密失败抛异常', () async {
      final dataKey = SyncCrypto.generateDataKey();
      final plaintext = Uint8List.fromList(utf8.encode('note content'));
      final envelope =
          await SyncCrypto.seal(dataKey, 'note-id-A', plaintext);
      // 用错误的 id 解密应失败（AAD 绑定）
      await expectLater(
        SyncCrypto.open(dataKey, 'note-id-B', envelope),
        throwsA(anything),
      );
    });

    test('空明文也能正确加密解密', () async {
      final dataKey = SyncCrypto.generateDataKey();
      const id = 'empty-note';
      final plaintext = Uint8List(0);
      final envelope = await SyncCrypto.seal(dataKey, id, plaintext);
      final decrypted = await SyncCrypto.open(dataKey, id, envelope);
      expect(listEquals(decrypted, plaintext), isTrue);
    });

    test('大文本加密解密（10KB）', () async {
      final dataKey = SyncCrypto.generateDataKey();
      const id = 'large-note';
      final plaintext = Uint8List.fromList(
        utf8.encode('A' * 10240), // 10KB
      );
      final envelope = await SyncCrypto.seal(dataKey, id, plaintext);
      final decrypted = await SyncCrypto.open(dataKey, id, envelope);
      expect(listEquals(decrypted, plaintext), isTrue);
    });
  });

  group('SyncCrypto - dataKey wrap/unwrap', () {
    test('wrap/unwrap 往返：还原原始 dataKey', () async {
      final mk = await SyncCrypto.deriveMasterKey(
        'masterpassword',
        salt: SyncCrypto.generateSalt(),
      );
      final dataKey = SyncCrypto.generateDataKey();
      final wrapped = await SyncCrypto.wrapDataKey(mk, dataKey);
      final unwrapped = await SyncCrypto.unwrapDataKey(mk, wrapped);
      expect(listEquals(unwrapped, dataKey), isTrue);
    });

    test('wrap 后信封长度 = 12 + 32 + 16 = 60 字节', () async {
      final mk = await SyncCrypto.deriveMasterKey(
        'pw',
        salt: Uint8List.fromList(List.filled(16, 1)),
        iterations: 1000,
      );
      final dataKey = SyncCrypto.generateDataKey();
      final wrapped = await SyncCrypto.wrapDataKey(mk, dataKey);
      expect(wrapped.length, 60); // nonce(12) + ct(32) + tag(16)
    });

    test('错误 MK 解 unwrap 失败（模拟密码错误）', () async {
      final salt = SyncCrypto.generateSalt();
      final mk1 = await SyncCrypto.deriveMasterKey('correct', salt: salt, iterations: 1000);
      final mk2 = await SyncCrypto.deriveMasterKey('wrong', salt: salt, iterations: 1000);
      final dataKey = SyncCrypto.generateDataKey();
      final wrapped = await SyncCrypto.wrapDataKey(mk1, dataKey);
      await expectLater(
        SyncCrypto.unwrapDataKey(mk2, wrapped),
        throwsA(anything),
      );    });

    test('改密码场景：旧 MK 解 dataKey → 新 MK 重新 wrap → 仍能解出同一 dataKey', () async {
      // 这是改密码的核心流程测试
      final salt = SyncCrypto.generateSalt();
      final oldMk =
          await SyncCrypto.deriveMasterKey('oldpassword', salt: salt, iterations: 1000);
      final newMk =
          await SyncCrypto.deriveMasterKey('newpassword', salt: salt, iterations: 1000);

      // 1. 生成 dataKey 并用旧 MK wrap
      final dataKey = SyncCrypto.generateDataKey();
      final oldWrapped = await SyncCrypto.wrapDataKey(oldMk, dataKey);

      // 2. 改密码：旧 MK 解开 dataKey，新 MK 重新 wrap
      final recoveredDataKey = await SyncCrypto.unwrapDataKey(oldMk, oldWrapped);
      final newWrapped = await SyncCrypto.wrapDataKey(newMk, recoveredDataKey);

      // 3. 新 MK 能解出新 wrapped 里的同一个 dataKey
      final finalDataKey = await SyncCrypto.unwrapDataKey(newMk, newWrapped);
      expect(listEquals(finalDataKey, dataKey), isTrue);
    });
  });

  group('SyncCrypto - 内容哈希', () {
    test('相同明文产生相同 hash', () async {
      final h1 = SyncCrypto.hashString('hello');
      final h2 = SyncCrypto.hashString('hello');
      expect(h1, h2);
    });

    test('不同明文产生不同 hash', () async {
      final h1 = SyncCrypto.hashString('hello');
      final h2 = SyncCrypto.hashString('world');
      expect(h1 != h2, isTrue);
    });

    test('hash 长度为 64 字符（SHA-256 十六进制）', () async {
      final hash = SyncCrypto.hashString('test');
      expect(hash.length, 64);
    });

    test('空字符串也有 hash', () async {
      final hash = SyncCrypto.hashString('');
      expect(hash.length, 64);
      // SHA-256('') 的已知值
      expect(hash, 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });

    test('contentHash 与 hashString 一致（相同输入）', () async {
      final text = 'test content';
      final h1 = SyncCrypto.hashString(text);
      final h2 = SyncCrypto.contentHash(Uint8List.fromList(utf8.encode(text)));
      expect(h1, h2);
    });
  });

  group('SyncCrypto - 随机数生成', () {
    test('generateDataKey 返回 32 字节', () async {
      final key = SyncCrypto.generateDataKey();
      expect(key.length, 32);
    });

    test('generateSalt 返回 16 字节', () async {
      final salt = SyncCrypto.generateSalt();
      expect(salt.length, 16);
    });

    test('generateNonce 返回 12 字节', () async {
      final nonce = SyncCrypto.generateNonce();
      expect(nonce.length, 12);
    });

    test('两次生成的随机数不同（极大概率）', () async {
      final k1 = SyncCrypto.generateDataKey();
      final k2 = SyncCrypto.generateDataKey();
      expect(listEquals(k1, k2), isFalse);
    });
  });
}
