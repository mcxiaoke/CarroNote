// 测试用密码学替身（正式化，从 test_helpers.dart 提升而来）
//
// 背景：`cryptography` 的 `DartCryptography.argon2id` 在底层用后台 isolate
// 做内存硬化填充；而 `flutter test` 的子进程在本机沙箱里**无法 spawn isolate**
// （Isolate.run 会永久挂起），导致 Keyring 派生 MK 卡死、90s 超时。
// 集成测试只关心「登录/设置密码」这条 UI 主流程是否走得通，并不验证 Argon2id
// 的密码学强度，因此这里把 argon2id 替换成**纯 Dart、同进程、确定性**的
// PBKDF2-HMAC-SHA256（用 package:crypto）。派生结果与真实 Argon2id 不同，但
// create 与 unlock 自洽——正确密码能解出 dataKey、错误密码抛异常，足以驱动
// 整条认证流程。AES-GCM 仍走 DartCryptography 的纯 Dart 实现（无 isolate）。

// Dart imports:
import 'dart:math';
import 'dart:typed_data';

// Package imports:
import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:cryptography/cryptography.dart'
    show
        AesGcm,
        Argon2id,
        Mac,
        SecretBox,
        SecretBoxAuthenticationError,
        SecretKey;
import 'package:cryptography/src/dart/cryptography.dart' show DartCryptography;

/// 纯 Dart PBKDF2-HMAC-SHA256（package:crypto 的 Hmac），同步、无 isolate。
Uint8List pbkdf2HmacSha256({
  required List<int> password,
  required List<int> salt,
  required int iterations,
  required int length,
}) {
  const hlen = 32; // SHA-256 输出长度
  final hmac = Hmac(sha256, password);
  final blocks = (length + hlen - 1) ~/ hlen;
  final out = Uint8List(blocks * hlen);
  for (var block = 1; block <= blocks; block++) {
    final inner = Uint8List(salt.length + 4);
    inner.setRange(0, salt.length, salt);
    inner[salt.length] = (block >> 24) & 0xff;
    inner[salt.length + 1] = (block >> 16) & 0xff;
    inner[salt.length + 2] = (block >> 8) & 0xff;
    inner[salt.length + 3] = block & 0xff;
    var u = hmac.convert(inner).bytes;
    final t = Uint8List.fromList(u);
    for (var i = 2; i <= iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.setRange((block - 1) * hlen, (block - 1) * hlen + hlen, t);
  }
  return out.sublist(0, length);
}

/// HMAC-SHA256（返回 32 字节）。
Uint8List _hmac(List<int> key, List<int> data) =>
    Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

/// 常数时间比较两个字节序列（防止时序侧信道；此处用于测试替身的 MAC 校验）。
bool _constantTimeEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// 用 HMAC-SHA256(key, nonce ‖ blockIndex) 派生密钥流，与 data 做 XOR。
/// blockIndex 为 4 字节大端，按 32 字节分块；加密解密同运算（对称）。
Uint8List _xorKeystream({
  required List<int> key,
  required List<int> nonce,
  required List<int> data,
}) {
  const blockSize = 32;
  final out = Uint8List(data.length);
  final counter = Uint8List(4);
  final input = Uint8List(nonce.length + 4);
  input.setRange(0, nonce.length, nonce);
  for (var i = 0; i < data.length; i += blockSize) {
    final blockIndex = i ~/ blockSize;
    counter[0] = (blockIndex >> 24) & 0xff;
    counter[1] = (blockIndex >> 16) & 0xff;
    counter[2] = (blockIndex >> 8) & 0xff;
    counter[3] = blockIndex & 0xff;
    input.setRange(nonce.length, nonce.length + 4, counter);
    final ks = _hmac(key, input);
    final end = data.length - i < blockSize ? data.length - i : blockSize;
    for (var j = 0; j < end; j++) {
      out[i + j] = data[i + j] ^ ks[j];
    }
  }
  return out;
}

/// 安全随机字节（nonce 用）。
Uint8List _randomBytes(int length) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => r.nextInt(256)));
}

/// 测试用「无 isolate」Argon2id 替身。
///
/// 用 PBKDF2-HMAC-SHA256 替代 Argon2id 的内存硬化派生。低迭代次数（4096）足矣：
/// 测试追求的是「快且确定性」，而非抗暴力破解。
class FakeArgon2id extends Argon2id {
  FakeArgon2id({
    required this.parallelism,
    required this.memory,
    required this.iterations,
    required this.hashLength,
  }) : super.constructor();

  @override
  final int parallelism;
  @override
  final int memory;
  @override
  final int iterations;
  @override
  final int hashLength;

  @override
  Future<SecretKey> deriveKey({
    required SecretKey secretKey,
    required List<int> nonce,
    List<int> optionalSecret = const <int>[],
    List<int> associatedData = const <int>[],
  }) async {
    final pw = await secretKey.extractBytes();
    final out = pbkdf2HmacSha256(
      password: pw,
      salt: nonce,
      iterations: 4096,
      length: hashLength,
    );
    return SecretKey(out);
  }
}

/// 仅替换 argon2id / aesGcm 的 Cryptography 实现；其余沿用纯 Dart 实现。
class FakeCryptography extends DartCryptography {
  @override
  Argon2id argon2id({
    required int memory,
    required int parallelism,
    required int iterations,
    required int hashLength,
  }) {
    return FakeArgon2id(
      memory: memory,
      parallelism: parallelism,
      iterations: iterations,
      hashLength: hashLength,
    );
  }

  @override
  AesGcm aesGcm({int secretKeyLength = 32, int nonceLength = 12}) {
    return FakeAesGcm(
      secretKeyLength: secretKeyLength,
      nonceLength: nonceLength,
    );
  }
}

/// 测试用「无 isolate」AES-GCM 替身。
///
/// 不实现真正的 AES/GCM，而是用 HMAC-SHA256 派生密钥流做 XOR 流加密
/// （package:crypto 的 Hmac，纯 Dart、同进程）。只要 encrypt/decrypt 互为逆运算、
/// 且 wrap/unwrapDataKey 用同一把 MK，密钥环就能正确落盘与还原。集成测试只验证
/// 认证主流程是否走得通，不验证密码学强度。
class FakeAesGcm extends AesGcm {
  FakeAesGcm({this.secretKeyLength = 32, this.nonceLength = 12})
    : super.constructor();

  @override
  final int secretKeyLength;
  @override
  final int nonceLength;

  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const <int>[],
    Uint8List? possibleBuffer,
  }) async {
    final key = await secretKey.extractBytes();
    final usedNonce = nonce ?? _randomBytes(nonceLength);
    final cipherText = _xorKeystream(
      key: key,
      nonce: usedNonce,
      data: clearText,
    );
    // mac 长度需与 macAlgorithm.macLength 一致（GCM 为 16），这里填 16 字节。
    final mac = _hmac(key, cipherText).sublist(0, 16);
    return SecretBox(cipherText, nonce: usedNonce, mac: Mac(mac));
  }

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const <int>[],
    Uint8List? possibleBuffer,
  }) async {
    final key = await secretKey.extractBytes();
    // 认证：复算 encrypt 时写入的 MAC（HMAC-SHA256(key, cipherText) 前 16 字节），
    // 并与 SecretBox 携带的 mac 做常数时间比较。主密钥（由密码派生）错误时，
    // 错误 key 复算出的 MAC 与落盘 MAC 不匹配 → 抛 SecretBoxAuthenticationError，
    // 被 SyncCrypto._aesGcmDecrypt 的 on Object 捕获并包装为 SyncDecryptionException，
    // 最终由 keyring._unwrapOrThrow 转成 WrongPasswordException——与真实 AES-GCM
    // 的 tag 校验失败行为一致，使「错误密码」路径能被正确识别（否则 XOR 对称可
    // 逆，任何密码都会「解密成功」从而登录成功，错误密码分支永远触发不了）。
    final expectedMac = _hmac(key, secretBox.cipherText).sublist(0, 16);
    final storedMac = secretBox.mac.bytes;
    if (!_constantTimeEqual(expectedMac, storedMac)) {
      throw SecretBoxAuthenticationError();
    }
    final usedNonce = nonce ?? secretBox.nonce;
    final out = _xorKeystream(
      key: key,
      nonce: usedNonce,
      data: secretBox.cipherText,
    );
    return out;
  }
}
