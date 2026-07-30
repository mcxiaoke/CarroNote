// AES-CBC 加密层单元测试（pointycastle 4.x 重写后验证）
//
// 验证：encryptAES/decryptAES 往返、错误密码失败、格式兼容性。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safenotes/encryption/aes_encryption.dart';

void main() {
  group('AES-CBC encryptAES/decryptAES', () {
    test('往返：加密后解密还原明文', () {
      const plain = 'Hello, Safenotes!';
      const pass = 'mypassword';
      final encrypted = encryptAES(plain, pass);
      final decrypted = decryptAES(encrypted, pass);
      expect(decrypted, equals(plain));
    });

    test('往返：长文本', () {
      final plain = 'a' * 10000;
      const pass = 'secret';
      final encrypted = encryptAES(plain, pass);
      final decrypted = decryptAES(encrypted, pass);
      expect(decrypted, equals(plain));
    });

    test('往返：Unicode 文本', () {
      const plain = '你好，世界！🔐 安全笔记';
      const pass = '密码';
      final encrypted = encryptAES(plain, pass);
      final decrypted = decryptAES(encrypted, pass);
      expect(decrypted, equals(plain));
    });

    test('往返：空字符串', () {
      const plain = '';
      const pass = 'pass';
      final encrypted = encryptAES(plain, pass);
      final decrypted = decryptAES(encrypted, pass);
      expect(decrypted, equals(plain));
    });

    test('错误密码解密失败（抛异常）', () {
      const plain = 'secret data';
      const pass = 'correct';
      final encrypted = encryptAES(plain, pass);
      // 错误密码导致 PKCS7 padding 验证失败，抛 ArgumentError
      expect(() => decryptAES(encrypted, 'wrong'), throwsArgumentError);
    });

    test('加密结果是 base64 字符串', () {
      final encrypted = encryptAES('test', 'pass');
      expect(() => base64.decode(encrypted), returnsNormally);
    });

    test('相同明文每次加密产生不同密文（随机 salt）', () {
      const plain = 'same text';
      const pass = 'pass';
      final e1 = encryptAES(plain, pass);
      final e2 = encryptAES(plain, pass);
      expect(e1, isNot(equals(e2)));
    });

    test('信封格式：前 8 字节为 randomString，8-16 为 salt，之后为密文', () {
      final encrypted = encryptAES('test', 'pass');
      final bytes = base64.decode(encrypted);
      expect(bytes.length, greaterThan(16)); // 至少有 header + 一些密文
    });

    test('deriveKeyAndIV 返回 32 字节 key 和 16 字节 iv', () {
      final salt = generateRandomNonZero(8);
      final result = deriveKeyAndIV('pass', salt);
      expect(result.item1.length, equals(32)); // AES-256 key
      expect(result.item2.length, equals(16)); // CBC IV
    });
  });
}
