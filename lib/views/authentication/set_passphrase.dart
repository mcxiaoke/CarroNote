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
import 'dart:async';

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:local_session_timeout/local_session_timeout.dart';

// Project imports:
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/generic.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/sync/keyring.dart';
import 'package:safenotes/utils/passphrase_util.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/footer.dart';
import 'package:safenotes/widgets/login_button.dart';

class SetEncryptionPhrasePage extends StatefulWidget {
  final StreamController<SessionState> sessionStream;
  final bool? isKeyboardFocused;

  const SetEncryptionPhrasePage({
    super.key,
    required this.sessionStream,
    this.isKeyboardFocused,
  });

  @override
  SetEncryptionPhrasePageState createState() => SetEncryptionPhrasePageState();
}

class SetEncryptionPhrasePageState extends State<SetEncryptionPhrasePage> {
  final _formKey = GlobalKey<FormState>();
  final _passPhraseController = TextEditingController();
  final _passPhraseControllerConfirm = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final _focusFirst = FocusNode();
  final _focusSecond = FocusNode();
  bool _isHiddenFirst = true;
  bool _isHiddenConfirm = true;

  @override
  void dispose() {
    _passPhraseController.dispose();
    _passPhraseControllerConfirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    scrollToBottomIfOnScreenKeyboard();

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: Text(
            'Set Passphrase'.tr(),
            style: appBarTitle,
          ),
          centerTitle: true,
        ),
        body: CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: bottom),
                child: Column(
                  children: [
                    _buildTopLogo(),
                    _buildPassphraseSetWorkflow(context),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: footer(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopLogo() {
    final double topPadding = MediaQuery.of(context).size.height * 0.070;
    final double dimensions =
        MediaQuery.of(context).orientation == Orientation.portrait
            ? MediaQuery.of(context).size.width * 0.40
            : MediaQuery.of(context).size.height * 0.40;

    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Center(
        child: SizedBox(
          width: dimensions,
          height: dimensions,
          child: Image.asset(SafeNotesConfig.appLogoPath),
        ),
      ),
    );
  }

  Widget _buildPassphraseSetWorkflow(BuildContext context) {
    const double padding = 16.0;
    const double inputBoxSeparation = 10.0;

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(padding),
        child: Column(
          children: [
            AutofillGroup(
              child: Column(
                children: [
                  _inputFieldFirst(),
                  const SizedBox(height: inputBoxSeparation),
                  _inputFieldConfirm(context),
                ],
              ),
            ),
            _buildForgotPassphrase(),
            _buildLoginButton(),
          ],
        ),
      ),
    );
  }

  void scrollToBottomIfOnScreenKeyboard() {
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      _scrollController.animateTo(_scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 500), curve: Curves.ease);
    }
  }

  Widget _inputFieldFirst() {
    const double inputBoxEdgeRadius = 10.0;
    final String firstHintText = 'New Passphrase'.tr();

    return TextFormField(
      enableIMEPersonalizedLearning: false,
      controller: _passPhraseController,
      autofocus: widget.isKeyboardFocused ?? true, //true,
      obscureText: _isHiddenFirst,
      focusNode: _focusFirst,
      decoration: _inputBoxDecoration(
        inputFieldID: 'first',
        inputHintText: firstHintText,
        label: firstHintText,
        inputBoxEdgeRadius: inputBoxEdgeRadius,
      ),
      autofillHints: const [AutofillHints.password],

      keyboardType: TextInputType.visiblePassword,
      textInputAction: TextInputAction.next,
      onFieldSubmitted: (v) {
        FocusScope.of(context).requestFocus(_focusSecond);
      },
      validator: _firstInputValidator,
    );
  }

  Widget _inputFieldConfirm(BuildContext context) {
    const double inputBoxEdgeRadius = 10.0;
    const double padding = 10.0;
    final String confirmHintText = 'Re-enter Passphrase'.tr();

    return Padding(
      padding: const EdgeInsets.only(top: padding),
      child: TextFormField(
        enableIMEPersonalizedLearning: false,
        controller: _passPhraseControllerConfirm,
        focusNode: _focusSecond,
        obscureText: _isHiddenConfirm,
        decoration: _inputBoxDecoration(
          inputFieldID: 'confirm',
          inputHintText: confirmHintText,
          label: confirmHintText,
          inputBoxEdgeRadius: inputBoxEdgeRadius,
        ),
        autofillHints: const [AutofillHints.password],
        keyboardType: TextInputType.visiblePassword,
        textInputAction: TextInputAction.done,
        onEditingComplete: _loginController,
        validator: _confirmInputValidator,
      ),
    );
  }

  InputDecoration _inputBoxDecoration({
    required String inputFieldID,
    required String inputHintText,
    required String label,
    required double inputBoxEdgeRadius,
  }) {
    bool? visibility;

    if (inputFieldID == 'first') {
      visibility = _isHiddenFirst;
    } else {
      visibility = _isHiddenConfirm;
    }

    return InputDecoration(
      hintText: inputHintText,
      label: Text(label),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(inputBoxEdgeRadius),
      ),
      prefixIcon: const Icon(Icons.lock),
      suffixIcon: IconButton(
        icon: !visibility
            ? const Icon(Icons.visibility_off)
            : const Icon(Icons.visibility),
        onPressed: () {
          if (inputFieldID == 'first') {
            return setState(() => _isHiddenFirst = !_isHiddenFirst);
          } else {
            return setState(() => _isHiddenConfirm = !_isHiddenConfirm);
          }
        },
      ),
    );
  }

  String? _firstInputValidator(String? passphrase) {
    const int minPassphraseLength = 8;
    const double minPassphraseStrength = 0.5;

    return passphrase == null || passphrase.length < minPassphraseLength
        ? 'Must be at least 8 characters long!'.tr()
        : (estimateBruteforceStrength(passphrase) < minPassphraseStrength)
            ? 'Passphrase is too weak!'.tr()
            : null;
  }

  String? _confirmInputValidator(String? passphraseConfirm) {
    return passphraseConfirm == null ||
            passphraseConfirm != _passPhraseController.text
        ? 'Passphrase mismatch!'.tr()
        : null;
  }

  Widget _buildLoginButton() {
    return ButtonWidget(
      text: 'Confirm'.tr(),
      onClicked: () async {
        _loginController();
      },
    );
  }

  Widget _buildForgotPassphrase() {
    return Container(
      alignment: Alignment.centerRight,
      child: TextButton(
        child: Text('What is passphrase?'.tr()),
        onPressed: () {
          showGenericDialog(
            context: context,
            icon: Icons.info_outline,
            message:
                'Passphrase is similar to password but generally longer, it will be used to encrypt and decrypt your notes. Use strong passphrase and make sure to remember it. It is impossible to decrypt your notes without the passphrase. With great security comes the great responsibility of remembering the passphrase!'
                    .tr(),
          );
        },
      ),
    );
  }

  void _loginController() async {
    final form = _formKey.currentState!;

    if (form.validate()) {
      final enteredPassphrase = _passPhraseController.text;
      final enteredPassphraseConfirm = _passPhraseControllerConfirm.text;

      if (enteredPassphrase == enteredPassphraseConfirm) {
        showSnackBarMessage(context, 'Passphrase set!'.tr());

        // start listening for session inactivity on successful login
        widget.sessionStream.add(SessionState.startListening);

        // 初始化 Keyring：生成 dataKey 并注入 database（本地加密存储）
        // 这是 B1 方案的核心——无论是否启用同步，都要初始化 dataKey
        //
        // D1 修复（与 login.dart 一致）：_initKeyring 返回 bool，失败时停留
        // 在设置密码页不导航到 /home。否则 database._dataKey 仍为 null，
        // home 页 refreshNotes 会抛 DataKeyNotSetException，异常未捕获导致
        // isLoading 永远为 true，UI 一直转圈。
        // 触发场景：卸载/清除 SharedPreferences 但 db 文件还在，用户输入
        // 新密码时 Keyring.unlockLocal 用新密码解旧 encryptedDataKey 失败。
        //
        // 简化方案：不再调 Session.setOrChangePassphrase（已删 hash 写入），
        // 改为 _initKeyring 成功后调 Session.onPasswordSet（仅 PhraseHandler +
        // biometric 副作用）。PhraseHandler.getPass 为空会导致 biometric 存空
        // 字符串 → 指纹登录必失败（评审 hy3/mmm3 A1）。
        final ok = await _initKeyring(enteredPassphrase);
        if (!ok) return;
        if (!mounted) return;
        Session.onPasswordSet(enteredPassphrase);

        TextInput.finishAutofillContext();
        await Navigator.pushReplacementNamed(
          context,
          '/home',
          arguments: widget.sessionStream,
        );
      } else {
        showSnackBarMessage(context, 'Passphrase mismatch!'.tr());
      }
    }
  }

  /// 初始化 Keyring：生成 dataKey + encryptedDataKey，注入 database
  ///
  /// 首次设置密码时调用。PBKDF2 200k 迭代会耗时 1-2 秒，
  /// 显示 loading 不阻塞 UI。
  ///
  /// 返回 true 表示 keyring 已就绪（可导航到 /home）；
  /// 返回 false 表示 keyring 初始化失败（dataKey 未注入 database），
  /// 调用方不应导航到 /home，否则 home 页读取笔记会抛
  /// DataKeyNotSetException 且 UI 一直转圈。
  ///
  /// 安全守卫（评审 ds4p P1）：若检测到 keyring 已初始化，拒绝 createNew，
  /// 防止异常路由下覆盖旧 keyring → 静默数据丢失。
  Future<bool> _initKeyring(String passphrase) async {
    // 守卫：keyring 已初始化说明路由错误（应走 login 而非 set_passphrase），
    // 直接拒绝 createNew，避免覆盖已有 keyring 元数据导致数据丢失。
    if (await Keyring.isInitialized(NotesDatabase.instance)) {
      if (mounted) {
        showSnackBarMessage(context, '检测到已有加密数据,请返回登录');
      }
      return false;
    }

    final result = await SyncService.instance.initKeyringFromPassword(
      password: passphrase,
      database: NotesDatabase.instance,
    );

    if (!result.success) {
      if (mounted) {
        showSnackBarMessage(
          context,
          '加密初始化失败：${result.error ?? "未知错误"}',
        );
      }
      return false;
    }

    // 如果已配置同步后端，顺带初始化后端
    await SyncConfig.init();
    if (SyncConfig.isSyncEnabled) {
      final backendResult = await SyncService.instance.initBackend(
        database: NotesDatabase.instance,
      );
      if (!backendResult.success && mounted) {
        showSnackBarMessage(
          context,
          '同步初始化失败：${backendResult.error ?? "未知错误"}',
        );
      }
      // 后端失败不阻断进入 home——keyring 已就绪，用户可在设置页修复后端
    }
    return true;
  }
}
