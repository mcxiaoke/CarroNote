/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'package:cryptography/cryptography.dart' show Argon2id;
import 'package:cryptography/dart.dart' show DartArgon2id, DartCryptography;

// 测试用「无 isolate / 无 yield」真实加密实现。
//
// 背景：`cryptography` 的 `DartArgon2id` 默认会有两个行为，在 `flutter test`
// （`testWidgets` 的 FakeAsync zone）里都会造成永久死锁：
//   1. 按 `parallelism` 派生 `maxIsolates` 个后台 isolate 并行计算
//      （argon2_impl_default.dart 里 `Isolate.spawn`）；
//   2. 内存填充循环中每 500 blocks 执行一次 `await Future.delayed(1µs)`
//      （argon2.dart:695）让出事件循环——该 timer 只有 `tester.pump()` 才推进，
//      而调用方正卡在 `await deriveKey` 上，永远不会 pump。
//
// 实测：单独 `maxIsolates: 0` 仍会挂（因为 yield 的 `Future.delayed` 还在）；
// 必须同时 `blocksPerProcessingChunk: 0`（跳过 yield）。这样 Argon2id 以
// **真实算法**、纯主 isolate、无 timer 让出完成派生（32MiB/t3/p2 约 300ms）。
// AES-GCM / PBKDF2 等其余原语一律沿用真实 `DartCryptography` 实现。
class NoIsolateDartCryptography extends DartCryptography {
  @override
  Argon2id argon2id({
    required int memory,
    required int parallelism,
    required int iterations,
    required int hashLength,
  }) {
    return DartArgon2id(
      memory: memory,
      parallelism: parallelism,
      iterations: iterations,
      hashLength: hashLength,
      maxIsolates: 0,
      blocksPerProcessingChunk: 0,
    );
  }
}
