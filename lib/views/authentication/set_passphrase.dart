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
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/authwall.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/generic.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/motion.dart';
import 'package:safenotes/utils/passphrase_util.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/footer.dart';

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

  // 防重入：初始化含 PBKDF2 派生（1-2 秒）与可选后端网络请求，
  // 期间连点会并发触发 initKeyringFromPassword（与 login._isLoggingIn 同模式）
  bool _isSettingUp = false;

  // 评审 #15（反向移植自 change_passphrase）：记录上次 viewInsets，
  // 只在键盘从无到有出现时才触发滚动，避免每次 build 重复执行滚动动画
  double _lastViewInset = 0;

  @override
  void initState() {
    super.initState();
    // 界面切换埋点：首次设置密码页
    Log.ui.i('进入设置密码页面 (首次初始化保险库)');
  }

  @override
  void dispose() {
    // F-H11 修复：补齐 _scrollController 与焦点节点的 dispose，避免资源泄漏
    _passPhraseController.dispose();
    _passPhraseControllerConfirm.dispose();
    _scrollController.dispose();
    _focusFirst.dispose();
    _focusSecond.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // viewInsetsOf 只订阅 viewInsets 细分依赖，重建范围比 MediaQuery.of 小
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    // 只在键盘从无到有出现时才触发滚动，避免每次 build（setState 等）重复滚动
    if (bottom > 0 && _lastViewInset == 0) {
      scrollToBottomIfOnScreenKeyboard();
    }
    _lastViewInset = bottom;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: Text('Set Passphrase'.tr(), style: appBarTitle),
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
                      child: footer(context),
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
    // 固定尺寸，不随窗口缩放（此前用屏宽/屏高 40%，桌面大窗口下 logo 巨大）。
    const double topPadding = 24;
    const double logoSize = 180;

    return Padding(
      padding: const EdgeInsets.only(top: topPadding),
      child: Center(
        child: SizedBox(
          width: logoSize,
          height: logoSize,
          child: Image.asset(
            SafeNotesConfig.appLogoPath,
            semanticLabel: SafeNotesConfig.appName,
          ),
        ),
      ),
    );
  }

  Widget _buildPassphraseSetWorkflow(BuildContext context) {
    const double padding = 16.0;
    const double inputBoxSeparation = 10.0;

    return Form(
      key: _formKey,
      child: Center(
        // 宽屏/桌面限宽 420 居中，避免输入框与按钮撑满整个窗口
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kDialogMaxWidthCompact),
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
        ),
      ),
    );
  }

  void scrollToBottomIfOnScreenKeyboard() {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        // P1-11：500ms → AppMotion.slow。
        duration: AppMotion.slow,
        curve: Curves.ease,
      );
    }
  }

  Widget _inputFieldFirst() {
    final String firstHintText = 'New Passphrase'.tr();

    return ShadInputFormField(
      enableIMEPersonalizedLearning: false,
      controller: _passPhraseController,
      autofocus: widget.isKeyboardFocused ?? true,
      obscureText: _isHiddenFirst,
      focusNode: _focusFirst,
      padding: kInputPadding,
      leading: const Icon(LucideIcons.lock, size: kInputIconSize),
      trailing: _passToggle(
        _isHiddenFirst,
        () => setState(() => _isHiddenFirst = !_isHiddenFirst),
      ),
      label: Text(firstHintText),
      placeholder: Text(firstHintText),
      autofillHints: const [AutofillHints.password],
      keyboardType: TextInputType.visiblePassword,
      textInputAction: TextInputAction.next,
      onSubmitted: (v) {
        FocusScope.of(context).requestFocus(_focusSecond);
      },
      validator: _firstInputValidator,
    );
  }

  Widget _inputFieldConfirm(BuildContext context) {
    const double padding = 10.0;
    final String confirmHintText = 'Re-enter Passphrase'.tr();

    return Padding(
      padding: const EdgeInsets.only(top: padding),
      child: ShadInputFormField(
        enableIMEPersonalizedLearning: false,
        controller: _passPhraseControllerConfirm,
        focusNode: _focusSecond,
        obscureText: _isHiddenConfirm,
        padding: kInputPadding,
        leading: const Icon(LucideIcons.lock, size: kInputIconSize),
        trailing: _passToggle(
          _isHiddenConfirm,
          () => setState(() => _isHiddenConfirm = !_isHiddenConfirm),
        ),
        label: Text(confirmHintText),
        placeholder: Text(confirmHintText),
        autofillHints: const [AutofillHints.password],
        keyboardType: TextInputType.visiblePassword,
        textInputAction: TextInputAction.done,
        onEditingComplete: _loginController,
        validator: _confirmInputValidator,
      ),
    );
  }

  String? _firstInputValidator(String passphrase) {
    const int minPassphraseLength = 8;
    const double minPassphraseStrength = 0.5;

    return passphrase.length < minPassphraseLength
        ? 'Must be at least 8 characters long!'.tr()
        : (estimateBruteforceStrength(passphrase) < minPassphraseStrength)
        ? 'Passphrase is too weak!'.tr()
        : null;
  }

  String? _confirmInputValidator(String passphraseConfirm) {
    return passphraseConfirm != _passPhraseController.text
        ? 'Passphrase mismatch!'.tr()
        : null;
  }

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

  Widget _buildLoginButton() {
    // 防重入：PBKDF2 派生期间禁用按钮
    return ShadButton(
      key: const Key('setupConfirmButton'),
      width: double.infinity,
      onPressed: _isSettingUp ? null : _loginController,
      child: Text(_isSettingUp ? 'Processing...'.tr() : 'Confirm'.tr()),
    );
  }

  Widget _buildForgotPassphrase() {
    return Container(
      alignment: Alignment.centerRight,
      child: ShadButton.link(
        onPressed: () {
          showGenericDialog(
            context: context,
            message:
                'Passphrase is similar to password but generally longer, it will be used to encrypt and decrypt your notes. Use strong passphrase and make sure to remember it. It is impossible to decrypt your notes without the passphrase. With great security comes the great responsibility of remembering the passphrase!'
                    .tr(),
          );
        },
        child: Text('What is passphrase?'.tr()),
      ),
    );
  }

  void _loginController() async {
    // 防重入：初始化流程进行中时忽略重复提交（按钮/键盘完成键共用入口）
    if (_isSettingUp) return;

    final form = _formKey.currentState!;
    final sw = Stopwatch()..start();
    Log.auth.i('用户提交首次密码设置请求');

    if (form.validate()) {
      final enteredPassphrase = _passPhraseController.text;
      final enteredPassphraseConfirm = _passPhraseControllerConfirm.text;
      Log.auth.d('设置密码步骤 1/4：表单校验通过 (长度=${enteredPassphrase.length})');

      if (enteredPassphrase == enteredPassphraseConfirm) {
        // 评审 #14 修复：成功提示不再前置——原实现先弹 "Passphrase set!" 再
        // _initKeyring，keyring 失败（如旧 db 残留导致 createNew 被拒）时已误报
        // 成功。现在 keyring 初始化成功、会话副作用完成后才正式提示成功。

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
        // 防重入：进入异步初始化流程（PBKDF2 + 可选后端）前置位
        setState(() => _isSettingUp = true);
        try {
          final ok = await _initKeyring(enteredPassphrase);
          if (!ok) {
            Log.auth.w('设置密码中止：Keyring 初始化失败, 停留在设置密码页');
            return;
          }
          if (!mounted) {
            Log.auth.w('设置密码中止：页面已卸载, 不再继续导航');
            return;
          }
          Session.onPasswordSet(enteredPassphrase);

          // BUG 修复：keyring 已创建成功，必须同步刷新 AuthWall 的启动缓存。
          // 否则本进程内空闲锁定 logout 回 /authwall 时仍读到启动时的 false，
          // 会误走"输入两次密码"的设置页而不是登录页。
          AppBootState.vaultInitialized = true;
          Log.auth.i('设置密码步骤 4/4：保险库初始化标记已刷新 (vaultInitialized=true)');

          // 评审 #14 修复：此处才提示成功——keyring 初始化与所有副作用都成功，
          // 不会再有"误报成功"。
          showSnackBarMessage(context, 'Passphrase set!'.tr());
          // start listening for session inactivity on successful login
          widget.sessionStream.add(SessionState.startListening);

          TextInput.finishAutofillContext();
          Log.auth.i('首次密码设置完成, 总耗时 ${sw.elapsedMilliseconds}ms');
          Log.ui.i('界面切换: 设置密码页 → 主界面(/home)');
          await Navigator.pushReplacementNamed(
            context,
            '/home',
            arguments: widget.sessionStream,
          );
        } finally {
          // 复位防重入（成功路径导航后页面已销毁，跳过 setState）
          if (mounted) setState(() => _isSettingUp = false);
        }
      } else {
        Log.auth.w('设置密码失败：两次输入的密码不一致');
        showErrorToast(context, 'Passphrase mismatch!'.tr());
      }
    } else {
      Log.auth.w('设置密码中止：密码表单校验未通过(长度不足/强度过低/不匹配)');
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
    Log.crypto.d('设置密码步骤 2/4：检查 Keyring 是否已初始化');
    if (await Keyring.isInitialized(NotesDatabase.instance)) {
      // 路由异常场景：已有 keyring 却走到设置页，拒绝覆盖以防数据丢失
      Log.crypto.e('拒绝创建新 Keyring：检测到已存在的加密元数据(应走登录流程)');
      if (mounted) {
        showErrorToast(
          context,
          'Encrypted data detected. Please go back and log in.'.tr(),
        );
      }
      return false;
    }

    final swKeyring = Stopwatch()..start();
    Log.crypto.i('设置密码步骤 3/4：开始生成 dataKey 并派生主密钥 (PBKDF2)');
    final result = await SyncService.instance.initKeyringFromPassword(
      password: passphrase,
      database: NotesDatabase.instance,
    );

    if (!result.success) {
      Log.crypto.e(
        '新建 Keyring 失败: ${result.error ?? "未知错误"} '
        '(耗时 ${swKeyring.elapsedMilliseconds}ms)',
      );
      if (mounted) {
        showErrorToast(
          context,
          'Encryption initialization failed: {error}'.tr(
            namedArgs: {'error': result.error ?? 'Unknown error'.tr()},
          ),
        );
      }
      return false;
    }
    Log.crypto.i(
      '新建 Keyring 成功, dataKey 已注入数据库 '
      '(耗时 ${swKeyring.elapsedMilliseconds}ms)',
    );

    // 如果同步开关已开且后端配置完整，顺带初始化后端
    await SyncConfig.init();
    if (SyncConfig.isSyncReady) {
      Log.sync.i('同步已启用, 开始初始化后端 (type=${SyncConfig.backendType})');
      final backendResult = await SyncService.instance.initBackend(
        database: NotesDatabase.instance,
      );
      if (!backendResult.success) {
        Log.sync.w('同步后端初始化失败: ${backendResult.error ?? "未知错误"} (不阻断进入主界面)');
      } else {
        Log.sync.i('同步后端初始化成功');
      }
      if (!backendResult.success && mounted) {
        showErrorToast(
          context,
          'Sync initialization failed: {error}'.tr(
            namedArgs: {'error': backendResult.error ?? 'Unknown error'.tr()},
          ),
        );
      }
      // 后端失败不阻断进入 home——keyring 已就绪，用户可在设置页修复后端
    } else {
      Log.sync.d(
        '同步未启用或后端未配置, 跳过后端初始化 '
        '(enabled=${SyncConfig.isSyncEnabled}, '
        'configured=${SyncConfig.hasBackendConfig})',
      );
    }
    return true;
  }
}
