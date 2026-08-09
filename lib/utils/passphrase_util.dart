/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* You should have received a copy of the GNU General Public License v3.0 with
* this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
*
* See https://safenotes.dev for support or download.
*/

// Package imports:
import 'package:zxcvbnm/languages/en.dart' as en;
import 'package:zxcvbnm/zxcvbnm.dart';

/// 使用 zxcvbnm（基于 Dropbox zxcvbn 算法）评估密码强度。
///
/// 返回 0.0~1.0 之间的归一化分数，兼容旧接口：
///   - < 0.5 视为弱密码（对应 zxcvbnm score 0-1）
///   - >= 0.5 视为合格（对应 zxcvbnm score 2-4）
///
/// zxcvbnm 的原始 score 为 0-4 整数：
///   0: 太容易猜（如常见密码）
///   1: 非常弱
///   2: 中等强度
///   3: 强
///   4: 非常强
///
/// 归一化公式：normalized = (score + 1) / 5，将 [0,4] 映射到 [0.2, 1.0]
double estimateBruteforceStrength(String passphrase) {

  // 使用英语字典（包含常见密码、常见人名、Wikipedia 常用词）
  final zxcvbnm = Zxcvbnm(dictionaries: en.dictionaries);
  final result = zxcvbnm(passphrase);

  // 将 0-4 的整数 score 归一化到 0.0-1.0
  // score=0 → 0.2, score=1 → 0.4, score=2 → 0.6, score=3 → 0.8, score=4 → 1.0
  return (result.score + 1) / 5.0;
}