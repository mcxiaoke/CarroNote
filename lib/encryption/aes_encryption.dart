/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* You should have received a copy of the GNU General Public License v3.0 with
* this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
*
* See https://safenotes.dev for support or download.
*/

// Dart imports:
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

// Package imports:
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:tuple/tuple.dart';

// Project imports:
import 'package:safenotes/utils/app_logger.dart';

String generateRandString(int len) {
  var randomNumber = Random.secure(); // cryptographically secure number random
  return String.fromCharCodes(
      List.generate(len, (index) => randomNumber.nextInt(33) + 89));
}

/// AES-256-CBC + PKCS7 加密（OpenSSL EVP_BytesToKey 风格 salt 派生）
///
/// 信封格式：randomString(8) ‖ salt(8) ‖ ciphertext
/// 密钥/IV 通过 OpenSSL EVP_BytesToKey 风格的迭代 SHA256 派生。
///
/// 注：保留此格式以兼容已加密的旧笔记数据，不可更改。
String encryptAES(String plainText, String passphrase) {
  try {
    final salt = generateRandomNonZero(8);
    var keyndIV = deriveKeyAndIV(passphrase, salt);
    String randomString = generateRandString(8);

    final ciphertext = _aesCbcEncrypt(
      key: keyndIV.item1,
      iv: keyndIV.item2,
      plainText: Uint8List.fromList(utf8.encode(plainText)),
    );

    Uint8List encryptedBytesWithSalt = Uint8List.fromList(
        createUint8ListFromString(randomString) + salt + ciphertext);
    return base64.encode(encryptedBytesWithSalt);
  } catch (error) {
    // 旧格式（AES-CBC）加密失败极为罕见，属于严重错误
    Log.crypto.e('旧格式 AES-CBC 加密失败: 明文 ${plainText.length} 字符: $error');
    rethrow;
  }
}

String decryptAES(String encrypted, String passphrase) {
  try {
    Uint8List encryptedBytesWithSalt = base64.decode(encrypted);

    Uint8List encryptedBytes =
        encryptedBytesWithSalt.sublist(16, encryptedBytesWithSalt.length);
    final salt = encryptedBytesWithSalt.sublist(8, 16);
    var keyndIV = deriveKeyAndIV(passphrase, salt);

    final plainBytes = _aesCbcDecrypt(
      key: keyndIV.item1,
      iv: keyndIV.item2,
      cipherText: encryptedBytes,
    );
    return utf8.decode(plainBytes);
  } catch (error) {
    // 批量导入旧备份时可能连续失败，用 debug 避免刷屏（上层会聚合成 warning）
    Log.crypto.d('旧格式 AES-CBC 解密失败(密码错误或数据损坏): '
        '密文 ${encrypted.length} 字符: $error');
    rethrow;
  }
}

/// AES 块大小（字节）
const int _aesBlockSize = 16;

/// PKCS7 填充：在明文末尾追加 N 个值为 N 的字节，使总长度为块大小的整数倍。
///   - 明文长度刚好是块大小整数倍时，追加一个完整块（N=16）。
///   - N ∈ [1, 16]，N=0 非法（PKCS7 规范）。
Uint8List _pkcs7Pad(Uint8List data) {
  final padLen = _aesBlockSize - (data.length % _aesBlockSize);
  final padded = Uint8List(data.length + padLen);
  padded.setRange(0, data.length, data);
  padded.fillRange(data.length, padded.length, padLen);
  return padded;
}

/// PKCS7 去填充：根据末字节移除对应长度的填充。
///   - 填充非法（末字节为 0 或大于块大小、或末 N 字节不全等于 N）时抛 ArgumentError。
Uint8List _pkcs7Unpad(Uint8List data) {
  if (data.isEmpty) {
    throw ArgumentError('Invalid PKCS7 padding: empty data');
  }
  final padLen = data.last;
  if (padLen == 0 || padLen > _aesBlockSize || padLen > data.length) {
    throw ArgumentError('Invalid PKCS7 padding: bad pad length $padLen');
  }
  // 校验末尾 padLen 个字节全部等于 padLen
  for (var i = data.length - padLen; i < data.length; i++) {
    if (data[i] != padLen) {
      throw ArgumentError('Invalid PKCS7 padding: inconsistent pad bytes');
    }
  }
  return Uint8List.fromList(data.sublist(0, data.length - padLen));
}

/// AES-256-CBC 加密（pointycastle 4.x 直接实现，替代 encrypt 包）
///
/// 手动 PKCS7 填充 + CBCBlockCipher，避免 PaddedBlockCipherImpl 在空输入时的 bug。
Uint8List _aesCbcEncrypt({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List plainText,
}) {
  final cipher = CBCBlockCipher(AESEngine());
  cipher.init(true, ParametersWithIV(KeyParameter(key), iv));

  final padded = _pkcs7Pad(plainText);
  final output = Uint8List(padded.length);
  var offset = 0;
  while (offset < padded.length) {
    offset += cipher.processBlock(padded, offset, output, offset);
  }
  return output;
}

/// AES-256-CBC 解密（pointycastle 4.x 直接实现，替代 encrypt 包）
Uint8List _aesCbcDecrypt({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List cipherText,
}) {
  final cipher = CBCBlockCipher(AESEngine());
  cipher.init(false, ParametersWithIV(KeyParameter(key), iv));

  final output = Uint8List(cipherText.length);
  var offset = 0;
  while (offset < cipherText.length) {
    offset += cipher.processBlock(cipherText, offset, output, offset);
  }
  return _pkcs7Unpad(output);
}

Tuple2<Uint8List, Uint8List> deriveKeyAndIV(String passphrase, Uint8List salt) {
  var password = createUint8ListFromString(passphrase);
  Uint8List concatenatedHashes = Uint8List(0);
  Uint8List currentHash = Uint8List(0);
  bool enoughBytesForKey = false;
  Uint8List preHash = Uint8List(0);

  while (!enoughBytesForKey) {
    if (currentHash.isNotEmpty) {
      preHash = Uint8List.fromList(currentHash + password + salt);
    } else {
      preHash = Uint8List.fromList(password + salt);
    }
    currentHash = Uint8List.fromList(sha256.convert(preHash).bytes);
    concatenatedHashes = Uint8List.fromList(concatenatedHashes + currentHash);
    if (concatenatedHashes.length >= 48) enoughBytesForKey = true;
  }

  var keyBytes = concatenatedHashes.sublist(
      0, 32); //32 Byte key length => 256 bit key for AES-256
  var ivBytes = concatenatedHashes.sublist(32, 48);
  return Tuple2(keyBytes, ivBytes);
}

Uint8List createUint8ListFromString(String s) {
  var ret = Uint8List(s.length);
  for (var i = 0; i < s.length; i++) {
    ret[i] = s.codeUnitAt(i);
  }
  return ret;
}

Uint8List generateRandomNonZero(int seedLength) {
  final random = Random.secure(); //cryptographically secure number random
  const int randomMax = 245;
  final Uint8List uint8list = Uint8List(seedLength);
  for (int i = 0; i < seedLength; i++) {
    uint8list[i] = random.nextInt(randomMax) + 1;
  }
  return uint8list;
}
