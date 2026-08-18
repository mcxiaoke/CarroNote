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

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/models/session.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/motion.dart';
import 'package:safenotes/utils/passphrase_util.dart';
import 'package:safenotes/utils/scheduled_task.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/widgets/app_dialogs.dart';
import 'package:safenotes/widgets/shad_dialog.dart';

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

  // 改密码防重入：流程含 PBKDF2 派生、备份、网络 ping、密钥轮换等异步步骤，
  // 期间连点会并发触发密钥轮换，必须禁用按钮（与 login._isLoggingIn 同模式）
  bool _isChanging = false;

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
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    // 评审 #15：只在键盘从无到有出现时才触发滚动，避免每次 build
    // （如 setState、主题切换）都重复执行滚动动画
    if (bottom > 0 && _lastViewInset == 0) {
      scrollToBottomIfOnScreenKeyboard();
    }
    _lastViewInset = bottom;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SingleChildScrollView(
        //reverse: true,
        controller: _scrollController,
        child: Center(
          // 宽屏/桌面限宽 420 居中，与登录/设置密码界面一致
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kDialogMaxWidthCompact),
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
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        // P1-11：300ms → AppMotion.normal。
        duration: AppMotion.normal,
        curve: Curves.ease,
      );
    }
  }

  Widget _buildPassphraseChangeWorkflow(BuildContext context) {
    final String pageTitleName = 'Change Passphrase'.tr();
    const double paddingBetweenInputBox = 26.0;

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
                  fontSize: AppTextSize.s20,
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
    // 旧密码正确性在 _finalSubmitChange 里通过 keyring.changePassword 内部验证
    // (keyring.changePassword 会用旧密码派生 MK 解 dataKey,失败抛 WrongPasswordException)
    return ShadInputFormField(
      enableIMEPersonalizedLearning: false,
      enableInteractiveSelection: false,
      controller: _oldPassphraseController,
      autofocus: true,
      focusNode: _focusOld,
      obscureText: _isHiddenOld,
      padding: kInputPadding,
      leading: const Icon(LucideIcons.lock, size: kInputIconSize),
      trailing: _passToggle(_isHiddenOld, _toggleOldPasswordVisibility),
      label: Text(inputHintOld),
      placeholder: Text(inputHintOld),
      autofillHints: const [AutofillHints.password],
      keyboardType: TextInputType.visiblePassword,
      onSubmitted: (v) {
        FocusScope.of(context).requestFocus(_focusNew);
      },
      textInputAction: TextInputAction.next,
      validator: (passphrase) {
        if (passphrase.isEmpty) {
          return 'Enter Passphrase'.tr();
        }
        return null;
      },
    );
  }

  Widget _buildNewPassField() {
    final String inputHintNew = 'New Passphrase'.tr();

    return ShadInputFormField(
      enableIMEPersonalizedLearning: false,
      enableInteractiveSelection: false,
      controller: _newPassphraseController,
      focusNode: _focusNew,
      obscureText: _isHiddenNew,
      padding: kInputPadding,
      leading: const Icon(LucideIcons.lock, size: kInputIconSize),
      trailing: _passToggle(_isHiddenNew, _toggleNewPasswordVisibility),
      label: Text(inputHintNew),
      placeholder: Text(inputHintNew),
      autofillHints: const [AutofillHints.password],
      keyboardType: TextInputType.visiblePassword,
      onSubmitted: (v) {
        FocusScope.of(context).requestFocus(_focusNewConfirm);
      },
      textInputAction: TextInputAction.next,
      validator: _firstInputValidator,
    );
  }

  String? _firstInputValidator(String passphrase) {
    const int minPassphraseLength = 8;
    const double minPassphraseStrength = 0.5;
    final String minpCharacterMsg = 'Minimum 8 characters long!'.tr();
    final String tooWeakMsg = 'Passphrase is too weak!'.tr();

    return passphrase.length < minPassphraseLength
        ? minpCharacterMsg
        : (estimateBruteforceStrength(passphrase) < minPassphraseStrength)
        ? tooWeakMsg
        : null;
  }

  Widget _buildNewConfirmPassField() {
    final String inputHintConfirm = 'Confirm New Passphrase'.tr();
    final String passPhraseMismatchMsg = 'Passphrase Mismatch!'.tr();

    return ShadInputFormField(
      enableIMEPersonalizedLearning: false,
      enableInteractiveSelection: false,
      controller: _newConfirmPassphraseController,
      focusNode: _focusNewConfirm,
      obscureText: _isHiddenNewConfirm,
      padding: kInputPadding,
      leading: const Icon(LucideIcons.lock, size: kInputIconSize),
      trailing: _passToggle(
        _isHiddenNewConfirm,
        _toggleNewConfirmPasswordVisibility,
      ),
      label: Text(inputHintConfirm),
      placeholder: Text(inputHintConfirm),
      autofillHints: const [AutofillHints.password],
      keyboardType: TextInputType.visiblePassword,
      textInputAction: TextInputAction.done,
      onEditingComplete: _finalSubmitChange,
      validator: (password) => password != _newPassphraseController.text
          ? passPhraseMismatchMsg
          : null,
    );
  }

  void _toggleOldPasswordVisibility() =>
      setState(() => _isHiddenOld = !_isHiddenOld);
  void _toggleNewPasswordVisibility() =>
      setState(() => _isHiddenNew = !_isHiddenNew);
  void _toggleNewConfirmPasswordVisibility() =>
      setState(() => _isHiddenNewConfirm = !_isHiddenNewConfirm);

  /// 紧凑的密码显隐切换按钮：压制默认 48px 触控区，
  /// 避免把输入框撑得过高（各平台一致）。
  Widget _passToggle(bool hidden, VoidCallback onToggle) {
    return kInputIconButton(
      icon: hidden
          ? const Icon(LucideIcons.eye, size: kInputIconSize)
          : const Icon(LucideIcons.eyeOff, size: kInputIconSize),
      onPressed: onToggle,
    );
  }

  Widget _buildButtons(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 26, bottom: 20),
      // 改密码防重入：流程期间禁用按钮，避免并发触发密钥轮换
      child: ShadButton(
        width: double.infinity,
        leading: const Icon(LucideIcons.key, size: 20),
        onPressed: _isChanging ? null : _finalSubmitChange,
        child: Text(_isChanging ? 'Processing...'.tr() : 'Confirm'.tr()),
      ),
    );
  }

  void _finalSubmitChange() async {
    Log.auth.i('用户发起修改密码请求');
    final startedAt = DateTime.now();
    final form = formKey.currentState!;
    // final String passChangedSnackMsg = 'Passphrase changed!'.tr();
    final String wrongOldPassMsg = 'Wrong passphrase!'.tr();

    // 防重入：改密流程进行中（含确认框/备份/ping/密钥轮换）时忽略重复提交
    if (_isChanging) return;

    // 注意：validate() 有副作用（刷新错误提示），只能调用一次
    final isFormValid = form.validate();
    if (!isFormValid) {
      // 表单校验未过（新密码太短/太弱/两次不一致），不进入变更流程
      Log.auth.w('改密码中止：新密码表单校验未通过');
      return;
    }

    // 在任何 async gap 前捕获 navigator，避免 use_build_context_synchronously 警告
    final navigator = Navigator.of(context);

    // 防重入：进入异步流程（二次确认/验证/备份/轮换/同步）前置位
    setState(() => _isChanging = true);
    try {
      // 二次确认：表单校验通过后弹确认框，避免用户误触「确认」按钮直接改密码
      final confirmed = await showAppConfirm(
        context,
        title: 'Change Passphrase'.tr(),
        message: 'Are you sure you want to change your passphrase?'.tr(),
        confirmLabel: 'Confirm'.tr(),
        cancelLabel: 'Cancel'.tr(),
      );
      if (confirmed != true) {
        Log.auth.i('改密码中止：用户未确认二次确认框');
        return;
      }

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
          showErrorToast(
            context,
            'Keyring not initialized. Please log in again.'.tr(),
          );
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
          showErrorToast(context, wrongOldPassMsg);
        }
        return;
      } on Exception catch (e, st) {
        // 其他异常(简化方案:失败必须中止)
        Log.auth.e('改密码中止：校验旧密码时发生异常', error: e, stackTrace: st);
        if (mounted) {
          showErrorToast(
            context,
            'Failed to verify old passphrase: {error}'.tr(
              namedArgs: {'error': '$e'},
            ),
          );
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
          showErrorToast(
            context,
            'Failed to change passphrase: {error}'.tr(
              namedArgs: {'error': '$e'},
            ),
          );
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
      // showSnackBarMessage(context, passChangedSnackMsg);
      navigator.pop();
    } finally {
      // 复位防重入（成功路径 pop 后页面已销毁，跳过 setState）
      if (mounted) setState(() => _isChanging = false);
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
    return await showAppDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext dialogContext) {
            return ShadDialog(
              constraints: kAppDialogConstraints,
              title: Text(title),
              actions: [
                shadDialogActionBar(
                  actions: [
                    ShadDialogAction(
                      label: cancelText,
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                    ),
                    ShadDialogAction(
                      label: confirmText,
                      primary: true,
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                    ),
                  ],
                ),
              ],
              child: Text(content),
            );
          },
        ) ??
        false;
  }
}
