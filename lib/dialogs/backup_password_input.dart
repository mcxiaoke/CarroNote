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

// Dart imports:
import 'dart:ui';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';

// Project imports:
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/app_button.dart';

/// 加密备份导入时的密码输入框（docs/backup-encryption-design-20260810.md §7）
///
/// 与旧 ImportPassPhraseDialog 的区别：不做密码哈希校验（密码是否正确由
/// 解密结果决定），仅收集用户输入。解密失败时由调用方带 [errorText] 重开
/// 本弹框让用户重输。
/// 返回：输入密码字符串（提交）；null（取消）。
class BackupPasswordInputDialog extends StatefulWidget {
  /// 上轮解密失败的提示（如「密码错误或文件损坏」），非空时展示
  final String? errorText;

  const BackupPasswordInputDialog({super.key, this.errorText});

  @override
  BackupPasswordInputDialogState createState() =>
      BackupPasswordInputDialogState();
}

class BackupPasswordInputDialogState extends State<BackupPasswordInputDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _hidden = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const double radius = 10.0;

    return BackdropFilter(
      filter: ImageFilter.blur(),
      child: Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Import Data is Encrypted'.tr(), style: dialogHeadTextStyle),
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 10),
                child: Text(
                  'Enter the passphrase of the device that generated this file.',
                  style: dialogBodyTextStyle,
                ),
              ),
              if (widget.errorText != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    widget.errorText!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 13,
                    ),
                  ),
                ),
              TextField(
                controller: _controller,
                autofocus: true,
                obscureText: _hidden,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                  hintText: 'Encryption Phrase'.tr(),
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _hidden ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () =>
                        setState(() => _hidden = !_hidden),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              DialogActionBar(
                actions: [
                  DialogButton(
                    label: 'Cancel'.tr(),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  DialogButton(
                    label: 'Submit'.tr(),
                    isPrimary: true,
                    onPressed: _submit,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    final text = _controller.text;
    // 空密码直接返回空串：由解密失败分支处理（等价密码错误）
    Navigator.of(context).pop(text);
  }
}