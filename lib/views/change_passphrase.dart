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

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';

// Project imports:
import 'package:core/core.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/passphrase_util.dart';
import 'package:safenotes/utils/scheduled_task.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/app_button.dart';

class ChangePassphrase extends StatefulWidget {
  const ChangePassphrase({super.key});
  @override
  ChangePassphraseState createState() => ChangePassphraseState();
}

class ChangePassphraseState extends State<ChangePassphrase> {
  final formKey = GlobalKey<FormState>();
  bool _isHiddenOld = true;
  bool _isHiddenNew = true;
  bool _isHiddenNewConfirm = true;
  final _oldPassphraseController = TextEditingController();
  final _newPassphraseController = TextEditingController();
  final _newConfirmPassphraseController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusOld = FocusNode();
  final _focusNew = FocusNode();
  final _focusNewConfirm = FocusNode();

  // 评审 #15：记录上次 viewInsets，避免 build() 里每次都触发滚动动画
  double _lastViewInset = 0;

  @override
  void dispose() {
    // F-H11 修复：补齐 TextEditingController 与 ScrollController 的 dispose
    _oldPassphraseController.dispose();
    _newPassphraseController.dispose();
    _newConfirmPassphraseController.dispose();
    _scrollController.dispose();
    _focusOld.dispose();
    _focusNew.dispose();
    _focusNewConfirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    // 评审 #15：只在键盘从无到有出现时才触发滚动，避免每次 build
    // （如 setState、主题切换）都重复执行滚动动画
    if (bottom > 0 && _lastViewInset == 0) {
      scrollToBottomIfOnScreenKeyboard();
    }
    _lastViewInset = bottom;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(),
      body: SingleChildScrollView(
        //reverse: true,
        controller: _scrollController,
        child: Center(
          // 宽屏/桌面限宽 420 居中，与登录/设置密码界面一致
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: EdgeInsets.only(bottom: bottom),
              child: _buildPassphraseChangeWorkflow(context),
            ),
          ),
        ),
      ),
    );
  }

  void scrollToBottomIfOnScreenKeyboard() {
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.ease,
      );
    }
  }

  Widget _buildPassphraseChangeWorkflow(BuildContext context) {
    final String pageTitleName = 'Change Passphrase'.tr();
    const double paddingBetweenInputBox = 25.0;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: formKey,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Padding(
              padding: const EdgeInsets.only(
                top: paddingBetweenInputBox,
                bottom: 10,
              ),
              child: Text(
                pageTitleName,
                style: dialogHeadTextStyle.copyWith(
                  fontSize: 22,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: paddingBetweenInputBox),
              child: _buildCurrentPassField(),
            ),
            AutofillGroup(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: paddingBetweenInputBox),
                    child: _buildNewPassField(),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(
                      top: paddingBetweenInputBox,
                      bottom: paddingBetweenInputBox,
                    ),
                    child: _buildNewConfirmPassField(),
                  ),
                ],
              ),
            ),
            _buildButtons(context),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentPassField() {
    final String inputHintOld = 'Current Passphrase'.tr();

    // 简化方案:validator 只做长度检查
    // 旧密码正确性在 _finalSublmitChange 里通过 keyring.changePassword 内部验证
    // (keyring.changePassword 会用旧密码派生 MK 解 dataKey,失败抛 WrongPasswordException)
    return TextFormField(
      enableIMEPersonalizedLearning: false,
      controller: _oldPassphraseController,
      autofocus: true,
      focusNode: _focusOld,
      enableInteractiveSelection: false,
      obscureText: _isHiddenOld,
      decoration: _inputBoxDecoration(
        context,
        'first',
        inputHintOld,
      ),
      autofillHints: const [AutofillHints.password],
      keyboardType: TextInputType.visiblePassword,
      onFieldSubmitted: (v) {
        FocusScope.of(context).requestFocus(_focusNew);
      },
      textInputAction: TextInputAction.next,
      validator: (passphrase) {
        if (passphrase == null || passphrase.isEmpty) {
          return 'Enter Passphrase'.tr();
        }
        return null;
      },
    );
  }

  Widget _buildNewPassField() {
    final String inputHintNew = 'New Passphrase'.tr();

    return TextFormField(
      enableIMEPersonalizedLearning: false,
      controller: _newPassphraseController,
      focusNode: _focusNew,
      enableInteractiveSelection: false,
      obscureText: _isHiddenNew,
      decoration: _inputBoxDecoration(
        context,
        'second',
        inputHintNew,
      ),
      autofillHints: const [AutofillHints.password],
      keyboardType: TextInputType.visiblePassword,
      onFieldSubmitted: (v) {
        FocusScope.of(context).requestFocus(_focusNewConfirm);
      },
      textInputAction: TextInputAction.next,
      validator: _firstInputValidator,
    );
  }

  String? _firstInputValidator(String? passphrase) {
    const int minPassphraseLength = 8;
    const double minPassphraseStrength = 0.5;
    final String minpCharacterMsg = 'Minimum 8 characters long!'.tr();
    final String tooWeakMsg = 'Passphrase is too weak!'.tr();

    return passphrase == null || passphrase.length < minPassphraseLength
        ? minpCharacterMsg
        : (estimateBruteforceStrength(passphrase) < minPassphraseStrength)
        ? tooWeakMsg
        : null;
  }

  Widget _buildNewConfirmPassField() {
    final String inputHintConfirm = 'Confirm New Passphrase'.tr();
    final String passPhraseMismatchMsg = 'Passphrase Mismatch!'.tr();

    return TextFormField(
      enableIMEPersonalizedLearning: false,
      controller: _newConfirmPassphraseController,
      focusNode: _focusNewConfirm,
      enableInteractiveSelection: false,
      obscureText: _isHiddenNewConfirm,
      decoration: _inputBoxDecoration(
        context,
        'third',
        inputHintConfirm,
      ),
      autofillHints: const [AutofillHints.password],
      keyboardType: TextInputType.visiblePassword,
      textInputAction: TextInputAction.done,
      onEditingComplete: _finalSublmitChange,
      validator: (password) => password != _newPassphraseController.text
          ? passPhraseMismatchMsg
          : null,
    );
  }

  InputDecoration _inputBoxDecoration(
    BuildContext context,
    String inputFieldID,
    String inputHintText,
  ) {
    bool? visibility;

    if (inputFieldID == 'first') {
      visibility = _isHiddenOld;
    } else if (inputFieldID == 'second') {
      visibility = _isHiddenNew;
    } else {
      visibility = _isHiddenNewConfirm;
    }

    return InputDecoration(
      hintText: inputHintText,
      prefixIcon: const Icon(Icons.lock),
      suffixIcon: IconButton(
        icon: !visibility
            ? const Icon(Icons.visibility_off)
            : const Icon(Icons.visibility),
        onPressed: () {
          if (inputFieldID == 'first') {
            return _toggleOldPasswordVisibility();
          } else if (inputFieldID == 'second') {
            return _toggleNewPasswordVisibility();
          } else {
            return _toggleNewConfirmPasswordVisibility();
          }
        },
      ),
    );
  }

  void _toggleOldPasswordVisibility() =>
      setState(() => _isHiddenOld = !_isHiddenOld);
  void _toggleNewPasswordVisibility() =>
      setState(() => _isHiddenNew = !_isHiddenNew);
  void _toggleNewConfirmPasswordVisibility() =>
      setState(() => _isHiddenNewConfirm = !_isHiddenNewConfirm);

  Widget _buildButtons(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 10, top: 25, bottom: 20),
        child: AppButton(
          text: 'Confirm'.tr(),
          icon: const Icon(Icons.key, size: 20),
          onPressed: _finalSublmitChange,
        ),
      ),
    );
  }

  void _finalSublmitChange() async {
    Log.auth.i('用户发起修改密码请求');
    final startedAt = DateTime.now();
    final form = formKey.currentState!;
    final String passChangedSnackMsg = 'Passphrase changed!'.tr();
    final String wrongOldPassMsg = 'Wrong passphrase!'.tr();

    // 注意：validate() 有副作用（刷新错误提示），只能调用一次
    final isFormValid = form.validate();
    if (!isFormValid) {
      // 表单校验未过（新密码太短/太弱/两次不一致），不进入变更流程
      Log.auth.w('改密码中止：新密码表单校验未通过');
    }
    if (isFormValid) {
      // 在任何 async gap 前捕获 navigator，避免 use_build_context_synchronously 警告
      final navigator = Navigator.of(context);

      final oldPassword = _oldPassphraseController.text;
      final newPassword = _newConfirmPassphraseController.text;

      // 简化方案:旧密码验证前置(评审 kk27c P3)
      // 用 keyring.verifyPassword 只验证不持久化,避免先做备份/同步再发现旧密码错
      // 验证通过后再做 _preChangeCheck(备份/同步/ping),最后调 keyring.changePassword 持久化
      final keyring = SyncService.instance.keyring;
      if (keyring == null) {
        // keyring 为 null 说明未登录或状态异常,中止
        Log.auth.e('改密码中止：Keyring 未初始化（未登录或状态异常）');
        if (mounted) {
          showSnackBarMessage(context, 'Keyring not initialized. Please log in again.'.tr());
        }
        return;
      }

      try {
        Log.auth.d('改密码步骤 1/5：校验旧密码 (新密码 len=${newPassword.length})');
        await keyring.verifyPassword(oldPassword);
        Log.auth.i('改密码步骤 1/5：旧密码校验通过');
      } on WrongPasswordException {
        // 旧密码错误(简化方案:keyring 是唯一凭证,失败必须中止)
        Log.auth.w('改密码中止：旧密码错误');
        if (mounted) {
          showSnackBarMessage(context, wrongOldPassMsg);
        }
        return;
      } on Exception catch (e, st) {
        // 其他异常(简化方案:失败必须中止)
        Log.auth.e('改密码中止：校验旧密码时发生异常', error: e, stackTrace: st);
        if (mounted) {
          showSnackBarMessage(context, 'Failed to verify old passphrase: {error}'
              .tr(namedArgs: {'error': '$e'}));
        }
        return;
      }

      // 旧密码验证通过,继续前置检查(备份/同步/ping)
      // 返回 false 表示用户取消或检查未通过,中止改密码
      Log.auth.d('改密码步骤 2/5：执行前置检查（强制备份 / 同步 / ping）');
      final proceed = await _preChangeCheck();
      if (!proceed) {
        Log.auth.w('改密码中止：前置检查未通过或用户取消');
        return;
      }
      Log.auth.i('改密码步骤 2/5：前置检查通过');

      // 前置检查通过,执行改密码(验证+持久化)
      // 注意:verifyPassword 已验证过旧密码,changePassword 内部会再次验证(幂等)
      Keyring newKeyring;
      try {
        Log.auth.i('改密码步骤 3/5：重新包裹 dataKey 并持久化新 keyring');
        newKeyring = await keyring.changePassword(
          oldPassword: oldPassword,
          newPassword: newPassword,
          database: NotesDatabase.instance,
        );
        // 密钥版本号推进是多端识别「他端已改密码」的依据，必须留痕
        Log.crypto.i(
          '主密钥已轮换: keyVersion=${newKeyring.keyVersion} '
          'fingerprint=${newKeyring.keyFingerprint}',
        );
      } on Exception catch (e, st) {
        // 改密码失败(简化方案:失败必须中止,不再静默吞掉)
        Log.auth.e('改密码失败：持久化新 keyring 时异常', error: e, stackTrace: st);
        if (mounted) {
          showSnackBarMessage(context, 'Failed to change passphrase: {error}'
              .tr(namedArgs: {'error': '$e'}));
        }
        return;
      }

      // 更新 SyncService 中的 Keyring(重建 SyncEngine 使用新 encryptedDataKey)
      Log.auth.d('改密码步骤 4/5：刷新 SyncService 的 keyring 与同步引擎');
      await SyncService.instance.updateKeyring(
        keyring: newKeyring,
        database: NotesDatabase.instance,
      );

      // 简化方案(评审 hy3/mmm3 A2):改密码成功后必须更新 PhraseHandler + biometric
      // 否则 biometric secure storage 保留旧密码 → 指纹登录用旧密码解 keyring 失败
      Session.onPasswordSet(newPassword);

      // 改密码后立即同步:把新 encryptedDataKey 推送到远端
      // 避免他端在本地推送前拉到旧 encryptedDataKey,触发不必要的 dataKey 迁移逻辑
      // 同步失败不阻断改密码流程(本地密码已变更成功),仅提示用户
      try {
        Log.auth.d('改密码步骤 5/5：推送新密钥到远端');
        await SyncService.instance.sync();
        Log.auth.i('改密码步骤 5/5：新密钥已推送到远端');
      } on Exception catch (e) {
        // 同步失败:本地 encryptedDataKey 已更新,下次 sync 会自动推送
        Log.auth.w('改密码后推送新密钥失败（本地已生效，下次同步会重试）', error: e);
      }

      final ms = DateTime.now().difference(startedAt).inMilliseconds;
      Log.auth.i('修改密码完成, 总耗时 ${ms}ms');

      // 使用 if (!mounted) return; 模式,让 analyzer 识别 mounted 守卫
      if (!mounted) return;
      showSnackBarMessage(context, passChangedSnackMsg);
      navigator.pop();
    }
  }

  /// 改密码前置检查：强制同步 + 强制备份 + 服务器在线检测
  ///
  /// 流程：
  ///   1. 强制本地完整备份（绕过开关），失败则警告用户是否继续
  ///   2. 若启用同步：强制 sync 一次，检查本地是否 clean
  ///   3. 若启用同步：ping 服务器确认在线，不在线则警告用户
  ///
  /// 返回 true 表示可以继续改密码，false 表示用户取消或检查未通过。
  Future<bool> _preChangeCheck() async {
    // 1. 强制本地完整备份（绕过 isBackupOn 开关）
    final backupOk = await ScheduledTask.forceBackup();
    if (!backupOk && mounted) {
      final errMsg = ScheduledTask.lastBackupError;
      final proceed = await _showWarningDialog(
        title: 'Backup Failed'.tr(),
        content: errMsg != null
            ? 'Local backup write failed before passphrase change: {error}\n\nContinue changing the passphrase anyway?'
                .tr(namedArgs: {'error': errMsg})
            : 'Local backup write failed before passphrase change. It is recommended to fix the backup issue first.\n\nContinue changing the passphrase anyway?'
                .tr(),
        confirmText: 'Continue Changing Passphrase'.tr(),
        cancelText: 'Cancel'.tr(),
      );
      if (!proceed) return false;
    }

    // 2. 若启用同步：强制 sync + 检查 clean + ping 服务器
    final backend = SyncService.instance.backend;
    final keyring = SyncService.instance.keyring;
    if (keyring != null && backend != null) {
      // 2a. ping 服务器确认在线
      final online = await backend.ping();
      if (!online && mounted) {
        final proceed = await _showWarningDialog(
          title: 'Sync Server Unavailable'.tr(),
          content:
              'Cannot reach the sync server; the new key cannot be pushed immediately.\nOther devices may trigger key migration on next sync and cannot sync normally during that period.\n\nContinue changing the passphrase anyway?'
                  .tr(),
          confirmText: 'Continue Changing Passphrase'.tr(),
          cancelText: 'Cancel'.tr(),
        );
        if (!proceed) return false;
      }

      // 2b. 强制同步一次，把本地未推送的变更先推到远端
      if (online) {
        await SyncService.instance.sync();
        // 2c. 检查本地是否 clean（同步后仍可能有 blob missing 等情况）
        final unsynced = await NotesDatabase.instance.readUnsyncedNotes();
        if (unsynced.isNotEmpty && mounted) {
          final proceed = await _showWarningDialog(
            title: 'Unsynchronized Notes Remain'.tr(),
            content:
                '{count} notes are not yet synced (the remote may be temporarily unreachable).\nThey will remain local and be pushed on the next sync.\n\nContinue changing the passphrase anyway?'
                    .tr(namedArgs: {'count': '${unsynced.length}'}),
            confirmText: 'Continue Changing Passphrase'.tr(),
            cancelText: 'Cancel'.tr(),
          );
          if (!proceed) return false;
        }
      }
    }

    return true;
  }

  /// 显示警告对话框，让用户选择是否继续
  ///
  /// 返回 true 表示用户选择继续，false 表示取消。
  Future<bool> _showWarningDialog({
    required String title,
    required String content,
    required String confirmText,
    required String cancelText,
  }) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext dialogContext) {
            return AlertDialog(
              title: Text(title),
              content: Text(content),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(cancelText),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(confirmText),
                ),
              ],
            );
          },
        ) ??
        false;
  }
}
