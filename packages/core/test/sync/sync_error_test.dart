/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  group('SyncError 异常模型与边界测试', () {
    test('DecryptionError: toDisplayString 全字段与短 hash 防御', () {
      // 1. 正常长 hash
      final err1 = DecryptionError(
        operation: 'decryptBlob',
        noteUuid: 'uuid-1',
        blobHash: '0123456789abcdef',
        attemptedEpoch: 1,
        cause: 'tag mismatch',
      );
      final display1 = err1.toDisplayString();
      expect(display1, contains('解密失败（decryptBlob）'));
      expect(display1, contains('uuid=uuid-1'));
      expect(display1, contains('hash=01234567…'));
      expect(display1, contains('epoch=1'));
      expect(display1, contains('cause=tag mismatch'));

      // 2. 短 hash (<8 字符) 防御：不能抛 RangeError
      final errShort = DecryptionError(
        operation: 'decryptBlob',
        blobHash: 'abc',
      );
      expect(() => errShort.toDisplayString(), returnsNormally);
      expect(errShort.toDisplayString(), contains('hash=abc'));

      // 3. 空 hash 防御
      final errEmpty = DecryptionError(operation: 'decryptBlob', blobHash: '');
      expect(() => errEmpty.toDisplayString(), returnsNormally);

      // 4. toJson
      final json = err1.toJson();
      expect(json['type'], equals('DecryptionError'));
      expect(json['operation'], equals('decryptBlob'));
      expect(json['blobHash'], equals('0123456789abcdef'));
      expect(json['attemptedEpoch'], equals(1));
    });

    test('BlobMissingError: toDisplayString 短 hash 与全字段测试', () {
      // 1. 正常 hash
      const normalHash = '0123456789abcdef0123456789abcdef';
      final err1 = BlobMissingError(
        blobHash: normalHash,
        noteUuid: 'uuid-2',
        operation: 'getBlob',
      );
      final display1 = err1.toDisplayString();
      expect(display1, contains('blob 缺失（getBlob'));
      expect(display1, contains('hash=01234567…'));
      expect(display1, contains('uuid=uuid-2'));

      // 2. 短 hash (<8 字符)
      final errShort = BlobMissingError(blobHash: 'short');
      expect(() => errShort.toDisplayString(), returnsNormally);
      expect(errShort.toDisplayString(), contains('hash=short'));
    });

    test('ManifestCorruptError: toDisplayString 与 toJson', () {
      final err = ManifestCorruptError(
        operation: 'deserializeHeader',
        subtype: 'magic_mismatch',
        cause: 'Invalid magic header: 0x1234',
      );
      expect(err.label, equals('manifest 损坏'));
      expect(
        err.toDisplayString(),
        contains('manifest 损坏（deserializeHeader, magic_mismatch）'),
      );
      expect(
        err.toDisplayString(),
        contains('cause=Invalid magic header: 0x1234'),
      );
      expect(err.toJson()['subtype'], equals('magic_mismatch'));
    });

    test('NetworkError: retryable 分支与 HTTP 状态码展示', () {
      final errRetry = NetworkError(
        operation: 'putBlob',
        statusCode: 503,
        retryable: true,
        cause: 'Service Unavailable',
      );
      expect(errRetry.toDisplayString(), contains('HTTP 503'));
      expect(errRetry.toDisplayString(), contains('可重试'));

      final errNonRetry = NetworkError(
        operation: 'putManifest',
        statusCode: 400,
        retryable: false,
      );
      expect(errNonRetry.toDisplayString(), contains('不可重试'));
      expect(errNonRetry.toJson()['statusCode'], equals(400));
      expect(errNonRetry.toJson()['retryable'], isFalse);
    });

    test('KeyMismatchError: keyVersion 与 epoch 对比展示', () {
      final err = KeyMismatchError(
        operation: 'checkKeyVersion',
        localKeyVersion: 1,
        remoteKeyVersion: 2,
        localEpoch: 10,
        remoteEpoch: 20,
      );
      final display = err.toDisplayString();
      expect(display, contains('keyVersion: 1 vs 2'));
      expect(display, contains('epoch: 10 vs 20'));
      expect(err.toJson()['localKeyVersion'], equals(1));
      expect(err.toJson()['remoteKeyVersion'], equals(2));
    });

    test('UnexpectedError: toString 与 toDisplayString 截断超长 cause', () {
      final longCause = 'A' * 300;
      final err = UnexpectedError(
        operation: 'unknownOp',
        noteUuid: 'note-err-1',
        cause: longCause,
        stackTrace: StackTrace.current,
      );
      final display = err.toDisplayString();
      expect(display, contains('未预期错误（unknownOp, uuid=note-err-1）'));
      expect(display.length, lessThan(260));
      expect(display.endsWith('…'), isTrue);
      expect(err.toString(), contains('op=unknownOp, uuid=note-err-1'));
    });

    test('wrapDecryptionError: isTagError 分流与 aadId 携带', () {
      // 1. isTagError == true
      final tagErr = wrapDecryptionError(
        Exception('invalid auth tag'),
        aadId: 'manifest-items',
        isTagError: true,
      );
      expect(tagErr, isA<SyncDecryptionException>());
      expect(tagErr.message, contains('GCM 认证标签验证失败'));
      expect(tagErr.aadId, equals('manifest-items'));
      expect(tagErr.toString(), contains('(aad=manifest-items)'));

      // 2. isTagError == false
      final genericErr = wrapDecryptionError(
        FormatException('bad payload'),
        aadId: 'blob-hash-1',
        isTagError: false,
      );
      expect(genericErr.message, contains('AES-GCM 解密失败: FormatException'));
      expect(genericErr.aadId, equals('blob-hash-1'));
    });

    test('ManifestAuthException 与 ManifestKeyMismatchException toString', () {
      final authEx = ManifestAuthException(
        'pubHash mismatch',
        cause: 'bad bit',
      );
      expect(
        authEx.toString(),
        contains('ManifestAuthException: pubHash mismatch (cause: bad bit)'),
      );

      final keyEx = ManifestKeyMismatchException(
        'dataKey cannot decrypt items',
        cause: 'InvalidTag',
      );
      expect(
        keyEx.toString(),
        contains(
          'ManifestKeyMismatchException: dataKey cannot decrypt items (cause: InvalidTag)',
        ),
      );
    });
  });
}
