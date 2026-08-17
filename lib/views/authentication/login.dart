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
import 'package:after_layout/after_layout.dart';
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/authwall.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/generic.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/motion.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/spacing.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/utils/vault_backup.dart';
import 'package:safenotes/widgets/footer.dart';
import 'package:safenotes/widgets/shad_dialog.dart';

class EncryptionPhraseLoginPage extends StatefulWidget {
  final StreamController<SessionState> sessionStream;
  final bool? isKeyboardFocused;

  const EncryptionPhraseLoginPage({
    super.key,
    required this.sessionStream,
    this.isKeyboardFocused,
  });

  @override
  EncryptionPhraseLoginPageState createState() =>
      EncryptionPhraseLoginPageState();
}

class EncryptionPhraseLoginPageState extends State<EncryptionPhraseLoginPage>
    with AfterLayoutMixin<EncryptionPhraseLoginPage> {
  // BiometricAuth:
  final LocalAuthentication auth = LocalAuthentication();
  _BiometricState _supportState = _BiometricState.unknown;

  // Does the user still remember their passphrase?
  bool forcePassphraseInput = isPassphraseRememberChallenge();

  //ClassicLogin:
  final _formKey = GlobalKey<FormState>();
  final passPhraseController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool? _isKeyboardFocused;
  bool _isHidden = true;
  bool _isLocked = false;

  // 评审 #15（反向移植自 change_passphrase）：记录上次 viewInsets，
  // 只在键盘从无到有出现时才触发滚动，避免每次 build 重复执行滚动动画
  double _lastViewInset = 0;

  // 简化方案:登录验证改为 async(keyring 解密 1-2 秒),需要防重入
  // _isLoggingIn=true 期间禁用登录按钮,避免 PBKDF2 期间连点触发并发验证
  bool _isLoggingIn = false;

  // 登录错误提示改为页内联文本(不用全局 Toast,渲染在密码输入框 label 行右侧,
  // 见 _inputField/_showError):提示绑定本页生命周期,登录成功 pushReplacement 进
  // home 时随路由销毁,不会像 ShadSonner 那样悬停在 home 上方残留。
  String? _errorMessage;

  // 简化方案:限流计数从 validator(sync)迁移到 _login 失败分支(async)
  // 原本 validator 里 hash 比对失败时递减,现在 validator 只做长度检查
  int _noOfAllowedAttempts = PreferencesStorage.noOfLogginAttemptAllowed;

  // F-H09 修复:锁定倒计时状态从文件顶层移入 State,随 widget 生命周期创建/释放
  // 修复前这些是顶层全局变量 + 顶层 Timer,无法在路由销毁时取消,可能泄漏 Timer
  // 并持续向已释放的 StreamController 发事件(在 widget 销毁后 setState 报错)
  final int _lockoutTime = PreferencesStorage.bruteforceLockOutTime;
  int _counter = 0;
  Timer? _timer;
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  void _startTimer(VoidCallback callback) {
    _counter = _lockoutTime;

    // F-H09:每次重启前取消旧 Timer,避免多个周期叠加
    _timer?.cancel();

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      (_counter > 0) ? _counter-- : _timer?.cancel();
      if (!_controller.isClosed) {
        _controller.add(_counter.toString().padLeft(2, '0'));
      }
      if (_counter <= 0) {
        callback();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _isKeyboardFocused = widget.isKeyboardFocused ?? true;

    // BiometricAuth:
    auth.isDeviceSupported().then((bool isSupported) {
      // P-修复：设备支持检测是异步的，登录页可能在此期间被销毁
      // （如会话超时锁定触发登出并切换路由），未检查 mounted 直接
      // setState 会报 "setState() called after dispose()" 未捕获异常。
      if (!mounted) return;
      setState(
        () => _supportState = isSupported
            ? _BiometricState.supported
            : _BiometricState.unsupported,
      );
    });
  }

  @override
  void dispose() {
    // F-H09 修复:销毁时取消倒计时 Timer 并释放 StreamController,避免泄漏
    _timer?.cancel();
    _timer = null;
    _controller.close();
    // F-H11 修复:补齐 _scrollController 的 dispose
    _scrollController.dispose();
    passPhraseController.dispose();
    super.dispose();
  }

  @override
  Future<void> afterFirstLayout(BuildContext context) async {
    if (PreferencesStorage.isBiometricAuthEnabled &&
        (widget.isKeyboardFocused ?? true)) {
      await _authenticate();
    }
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
          title: Text('Login'.tr(), style: appBarTitle),
          centerTitle: true,
        ),
        body: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: bottom),
                child: Column(
                  children: [
                    _buildTopLogo(),
                    // 表单区域(含页内联错误提示)可能超出视口,用 Expanded 包裹
                    // 让内部 SingleChildScrollView 滚动,避免固定高度 Column +
                    // Spacer 在错误提示出现时 RenderFlex 溢出。
                    Expanded(child: _buildLoginWorkflow(context: context)),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
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

  void scrollToBottomIfOnScreenKeyboard() {
    try {
      if (MediaQuery.viewInsetsOf(context).bottom > 0) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          // P1-11：500ms → AppMotion.slow。
          duration: AppMotion.slow,
          curve: Curves.ease,
        );
      }
    } catch (_) {}
  }

  Widget _buildTopLogo() {
    // 固定尺寸，不随窗口缩放（此前用屏宽/屏高 40%，桌面大窗口下 logo 巨大）。
    // 顶部间距 24→8:让输入框/提示区整体上移,缓解软键盘弹出时按钮被遮挡。
    const double topPadding = 8;
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

  Widget _buildLoginWorkflow({required BuildContext context}) {
    const double padding = 16.0;

    return Form(
      key: _formKey,
      child: Center(
        // 宽屏/桌面限宽 420 居中，避免输入框与按钮撑满整个窗口
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kDialogMaxWidthCompact),
          child: SingleChildScrollView(
            // 绑定 _scrollController:键盘弹出时 scrollToBottomIfOnScreenKeyboard
            // 滚动本表单让登录按钮可见(外层 CustomScrollView 不可滚,maxScrollExtent 恒为 0)
            controller: _scrollController,
            padding: const EdgeInsets.all(padding),
            child: Column(
              children: [
                _buildTimeOut(),
                _inputField(),
                _buildForgotPassphrase(),
                _buildLoginButton(),
                _buildBiometricAuthButton(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimeOut() {
    // 评审 #3 修复：build 只读 stream，绝不在这里启动 Timer / 清输入框——
    // 否则锁定期内任何 setState（焦点变化、snackbar 等）都会把倒计时重置回满值、
    // 强制清空用户输入。倒计时只应在进入锁定的那一刻启动一次（见 _onLoginFailure）。
    if (!_isLocked) return const SizedBox(height: 20);

    // 锁定期：文本输入框已由锁定流程禁用（enabled: !_isLocked），
    // 无需在每次 build 时再次隐藏键盘 / 清空输入。
    return StreamBuilder(
      stream: _controller.stream,
      builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
        String? timeLeft = snapshot.hasData
            ? snapshot.data
            : _lockoutTime.toString();
        return Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Align(
            alignment: Alignment.center,
            child: Text(
              'Exceeded number of attempts, try after {timeLeft} seconds'.tr(
                namedArgs: {'timeLeft': timeLeft.toString()},
              ),
              style: TextStyle(
                color: ShadTheme.of(context).colorScheme.destructive,
                fontSize: AppTextSize.s12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _inputField() {
    return ShadInputFormField(
      key: const Key('passphraseInput'),
      enabled: !_isLocked,
      enableIMEPersonalizedLearning: false,
      controller: passPhraseController,
      autofocus: _isKeyboardFocused!,
      obscureText: _isHidden,
      padding: kInputPadding,
      leading: const Icon(LucideIcons.lock, size: kInputIconSize),
      trailing: kInputIconButton(
        icon: _isHidden
            ? const Icon(LucideIcons.eye, size: kInputIconSize)
            : const Icon(LucideIcons.eyeOff, size: kInputIconSize),
        onPressed: _togglePasswordVisibility,
      ),
      // label 行左侧为 "Passphrase",右侧为页内联错误提示(与输入框右缘对齐)。
      // 错误提示放在 label 行内,有/无错误不改变输入框与按钮的垂直间距,布局稳定。
      label: SizedBox(
        width: double.infinity,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Passphrase'.tr()),
            if (_errorMessage != null)
              Flexible(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Icon(
                      LucideIcons.circleAlert,
                      size: 12,
                      color: ShadTheme.of(context).colorScheme.destructive,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        _errorMessage!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          color: ShadTheme.of(context).colorScheme.destructive,
                          fontSize: AppTextSize.s12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      placeholder: Text('Enter Passphrase'.tr()),
      autofillHints: const [AutofillHints.password],
      keyboardType: TextInputType.visiblePassword,
      onEditingComplete: _loginController,
      // 重新输入时立即清除页内联错误提示,避免陈旧文案残留
      onChanged: (_) => _clearError(),
      validator: _passphraseValidator,
    );
  }

  /// 简化方案:validator 只做长度检查
  ///
  /// 密码正确性不在 validator 里判断(keyring 解密是 async,1-2 秒),
  /// 改在 _login 里 async 处理,失败时在 _onLoginFailure 递减尝试次数。
  ///
  /// 评审 #4 修复:validator 不再拦截最后 1 次尝试(此前 `_noOfAllowedAttempts <= 1`
  /// 时直接 setState 锁定,密码正确也进不了 `_login`,存在 off-by-one),也不得在
  /// validator 内调用 setState(反模式)。锁定判定统一收口到 _onLoginFailure。
  String? _passphraseValidator(String passphrase) {
    if (passphrase.isEmpty) {
      return 'Enter Passphrase'.tr();
    }
    return null;
  }

  void _togglePasswordVisibility() {
    setState(() => _isHidden = !_isHidden);
  }

  /// 页内联错误提示:替代全局 Toast,生命周期绑定本页,
  /// 路由切换(登录成功进 home)时随页面销毁,无残留。
  void _showError(String message) {
    if (!mounted) return;
    setState(() => _errorMessage = message);
  }

  /// 清除页内联错误提示(用户重新输入时调用)。
  void _clearError() {
    if (!mounted) return;
    if (_errorMessage != null) {
      setState(() => _errorMessage = null);
    }
  }

  Widget _buildLoginButton() {
    // 简化方案:验证中(_isLoggingIn)或锁定(_isLocked)时禁用按钮防重入
    final String loginText = _isLoggingIn ? 'Verifying...'.tr() : 'Login'.tr();

    return ShadButton(
      key: const Key('loginButton'),
      width: double.infinity,
      enabled: !(_isLocked || _isLoggingIn),
      onPressed: (_isLocked || _isLoggingIn) ? null : () => _loginController(),
      child: Text(loginText),
    );
  }

  Widget _buildBiometricAuthButton(BuildContext context) {
    // 设置里未启用生物识别时不显示该按钮（含「OR」分隔文字）。
    if (!PreferencesStorage.isBiometricAuthEnabled) {
      return const SizedBox.shrink();
    }
    final bool enabled = !forcePassphraseInput && !_isLocked;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            'OR'.tr(),
            style: const TextStyle(fontSize: AppTextSize.s14),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 20),
          child: ShadButton(
            width: double.infinity,
            // P1-20：图标走 AppIcon.lg，删除桌面/移动分支（22/28 不一致）。
            leading: Icon(LucideIcons.fingerprint, size: AppIcon.lg),
            onPressed: enabled ? _authenticate : null,
            child: Text('Biometric'.tr()),
          ),
        ),
      ],
    );
  }

  void _loginController() async {
    final form = _formKey.currentState!;
    final snackMsgWrongEncryptionPhrase = 'Wrong passphrase!'.tr();

    if (form.validate()) {
      final phrase = passPhraseController.text;
      await _login(phrase);
    } else {
      _showError(snackMsgWrongEncryptionPhrase);
    }
  }

  /// 简化方案:统一 async 登录验证
  ///
  /// 流程:
  ///   1. 本地 keyring 解锁(优先):Keyring.unlockLocal 成功 = 密码正确
  ///   2. 远端验证(仅启用同步时):拉 manifest header 比对 keyFingerprint
  ///      - verified: 密码正确(他端改密码后本端旧 MK 失效场景)
  ///      - wrongPassword: fingerprint 不匹配,扣尝试次数
  ///      - unreachable: 网络故障,不扣次数,提示用户检查网络
  ///   3. 都失败 = 密码错误,递减 _noOfAllowedAttempts
  ///
  /// 防重入:_isLoggingIn 标志 + 按钮禁用,避免 PBKDF2 1-2 秒内连点
  /// 限流:_noOfAllowedAttempts 从 validator(sync)迁移到 _onLoginFailure(async)
  Future<void> _login(String passphrase) async {
    // 防重入:PBKDF2 1-2 秒内防止重复提交
    if (_isLoggingIn) return;
    setState(() => _isLoggingIn = true);

    try {
      final database = NotesDatabase.instance;
      final isInitialized = await Keyring.isInitialized(database);

      // 1. 本地 keyring 解锁(优先)
      if (isInitialized) {
        final result = await SyncService.instance.initKeyringFromPassword(
          password: passphrase,
          database: database,
        );
        if (result.success) {
          await _onLoginSuccess(passphrase);
          return;
        }
        // result.success == false:密码错误或 keyring 损坏,继续尝试远端
      }

      // 2. 仅在启用同步时尝试远端验证
      //    避免无条件触发远端(隐私泄露 + 离线暴力放大,评审 kk27c P1)
      await SyncConfig.init();
      if (SyncConfig.isSyncReady) {
        final remoteResult = await _tryVerifyPassphraseViaRemote(passphrase);
        if (remoteResult == RemoteVerifyResult.verified) {
          await _onLoginSuccess(passphrase);
          return;
        }
        if (remoteResult == RemoteVerifyResult.unreachable) {
          // 网络不可达:不算密码错误,不扣尝试次数
          _showError(
            'Unable to verify password (network unavailable). Check your connection and try again.'
                .tr(),
          );
          return;
        }
        // remoteResult == wrongPassword:继续走失败流程
      }

      // 3. 密码错误
      _onLoginFailure();
    } finally {
      if (mounted) setState(() => _isLoggingIn = false);
    }
  }

  /// 登录成功后的统一处理
  Future<void> _onLoginSuccess(String passphrase) async {
    Session.login(passphrase);
    Log.auth.i('登录成功：进入主界面（密码登录）');

    // BUG 修复：登录成功即 keyring 已解锁，同步刷新 AuthWall 启动缓存，
    // 确保空闲锁定 logout 回 /authwall 时走登录页而非误进设置密码页。
    AppBootState.vaultInitialized = true;

    // re-enable biometric auth
    if (forcePassphraseInput) {
      PreferencesStorage.incrementBiometricAttemptAllTimeCount();
    }

    // start listening for session inactivity on successful login
    widget.sessionStream.add(SessionState.startListening);

    // 初始化后端(总开关已开且配置完整时),失败不阻断进入 home
    await SyncConfig.init();
    if (SyncConfig.isSyncReady) {
      // P-修复：登录路径绝不被网络等待阻塞。initBackend 在 WebDAV 后端不可达
      // 时会等待 _httpTimeout（见 webdav_backend.dart）才抛 BackendUnavailable，
      // 此前 await 会让用户卡在登录页"verifying"几十秒（局域网服务器出门不可达场景）。
      // 改为后台初始化：成功后再触发首次同步；失败仅记日志，由主界面
      // 同步状态 UI 展示"后端未就绪"，用户可正常使用本地笔记。
      unawaited(
        SyncService.instance.initBackend(database: NotesDatabase.instance).then(
          (backendResult) {
            if (!backendResult.success) {
              Log.sync.w(
                '登录后后端初始化失败（后台执行，不阻塞进入主界面）: '
                '${backendResult.error}',
              );
            } else {
              // 登录后执行一次初始同步,拉取远端最新数据
              SyncService.instance.autoSync();
            }
          },
        ),
      );
    }

    if (!mounted) return;
    await Navigator.pushReplacementNamed(
      context,
      '/home',
      arguments: widget.sessionStream,
    );
  }

  /// 登录失败处理:递减尝试次数 + 锁定判断
  ///
  /// 简化方案:限流计数从 validator(sync)迁移到这里(async)
  void _onLoginFailure() {
    Log.auth.w('登录失败：剩余尝试次数 $_noOfAllowedAttempts');
    _noOfAllowedAttempts--;
    final numberOfAttemptExceeded = 'Number of attempt exceeded'.tr();

    if (_noOfAllowedAttempts <= 0) {
      // 评审 #3/#4 修复：进入锁定的唯一入口。倒计时 Timer 只在这里启动一次
      // （build 只读 stream），并在此清空输入框、隐藏键盘、禁用输入。
      _startLockoutTimer();
      _showError(numberOfAttemptExceeded);
    } else {
      final wrongPhraseMsg =
          'Wrong passphrase {noOfAllowedAttempts} attempts left!'.tr(
            namedArgs: {'noOfAllowedAttempts': _noOfAllowedAttempts.toString()},
          );
      _showError(wrongPhraseMsg);
    }
  }

  /// 进入锁定状态：启动一次倒计时，超时后解除锁定并重置尝试次数
  void _startLockoutTimer() {
    setState(() => _isLocked = true);
    passPhraseController.clear();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    _startTimer(() {
      setState(() {
        _isLocked = false;
        _isKeyboardFocused = true;
        // 重置表单校验错误提示即可，无需重建 GlobalKey
        // （重建会强制整棵 Form 子树重建并丢失输入框状态）
        _formKey.currentState?.reset();
        // 简化方案:锁定超时后重置尝试次数(原为全局变量,现为实例字段)
        _noOfAllowedAttempts = PreferencesStorage.noOfLogginAttemptAllowed;
      });
    });
  }

  /// 远端验证三态结果(评审 hy3 A7)
  ///
  ///   - verified: 密码正确,已通过远端 manifest header 验证并解锁
  ///   - wrongPassword: fingerprint 不匹配,密码错误,扣尝试次数
  ///   - unreachable: 网络故障/后端不可达,不扣尝试次数
  Future<RemoteVerifyResult> _tryVerifyPassphraseViaRemote(
    String passphrase,
  ) async {
    final database = NotesDatabase.instance;
    // 创建后端实例(直接通过 SyncService 的公开工厂,避免污染单例状态)
    final backend = SyncService.instance.createBackendForVerification();
    if (backend == null) return RemoteVerifyResult.unreachable;
    try {
      await backend.init();
      final remoteResponse = await backend.getManifest();
      if (remoteResponse.ciphertext.isEmpty) {
        // 评审 #7 修复：远端无 manifest（从未同步 / 新后端）时**无法验证**，
        // 不再判定为密码错误扣尝试次数——否则从未同步过的用户改密码后
        // 本地 keyring 失效时会因"远端无 manifest"被误锁。
        Log.auth.w('远端验证: 无 manifest, 无法验证密码(不扣尝试次数)');
        return RemoteVerifyResult.unreachable;
      }

      // 仅解析 header(不需要 dataKey)
      final header = ManifestCrypto.deserializeHeaderOnly(
        remoteResponse.ciphertext,
      );

      // 用输入密码 + 远端 KDF 参数派生 MK,比对 fingerprint
      final mk = await SyncCrypto.deriveMasterKeyAsync(
        passphrase,
        kdf: header.kdf,
      );
      final fp = SyncCrypto.computeKeyFingerprint(mk);
      if (fp != header.keyFingerprint) {
        // fingerprint 不匹配 → 密码错误
        return RemoteVerifyResult.wrongPassword;
      }

      // fingerprint 匹配 → 密码正确,用远端 encryptedDataKey 解锁
      await Keyring.unlockFromRemoteManifest(
        password: passphrase,
        remoteVaultId: header.vaultId,
        remoteEncryptedDataKey: header.encryptedDataKey,
        remoteKdf: header.kdf,
        remoteKeyFingerprint: header.keyFingerprint,
        remoteKeyVersion: header.keyVersion,
        remoteDataKeyEpoch: header.dataKeyEpoch,
        remoteCreatedAt: header.createdAt,
        database: database,
      );

      // unlockFromRemoteManifest 内部已持久化 keyring 元数据,
      // 但没有调用 database.setDataKey,需要补上
      // (用刚持久化的远端元数据重新 unlockLocal 拿到 dataKey)
      final keyring = await Keyring.unlockLocal(
        password: passphrase,
        database: database,
      );
      NotesDatabase.instance.setDataKey(keyring.dataKey);
      await SyncService.instance.cacheKeyringFromLogin(keyring);
      return RemoteVerifyResult.verified;
    } on Exception catch (e, st) {
      // 网络故障、后端不可达、解析失败等 → unreachable(不扣次数)
      Log.auth.w('远端验证失败(网络/解析异常,不扣尝试次数)', error: e, stackTrace: st);
      return RemoteVerifyResult.unreachable;
    } finally {
      // 评审 #7 修复：backend 无论走哪条分支都必须 close，避免每次登录
      // 验证失败都泄漏一个 HTTP 连接/文件句柄。
      try {
        await backend.close();
      } on Exception catch (e) {
        Log.auth.d('远端验证 backend.close 失败(忽略): $e');
      }
    }
  }

  Widget _buildForgotPassphrase() {
    final String cantRecoverPassphraseMsg = "Can't decrypt without phrase!"
        .tr();
    // 桌面端字太小（原固定 10），按屏宽自适应放大（桌面窗口可 resize）
    final double fontSize =
        MediaQuery.sizeOf(context).width < kCompactBreakpoint
        ? AppTextSize.s12
        : AppTextSize.s14;

    return Container(
      alignment: Alignment.centerRight,
      child: ShadButton.raw(
        variant: ShadButtonVariant.link,
        padding: EdgeInsets.zero,
        child: Text(
          cantRecoverPassphraseMsg,
          style: TextStyle(fontSize: fontSize),
        ),
        onPressed: () => _showForgotPassphraseDialog(),
      ),
    );
  }

  /// 忘记密码逃生通道(评审 hy3 第6节)
  ///
  /// 简化后 Keyring.isInitialized==true → 一律进登录页,以下场景用户会被困住:
  ///   - 忘记密码
  ///   - 清除 SharedPreferences/重装但 db 残留
  ///
  /// 提供"清空本地数据重新开始"入口:
  ///   - 红色危险操作 + 二次确认
  ///   - 明确告知数据不可恢复
  ///   - 执行后删除 db 文件 + keyring 元数据,重启走首次设置流程
  void _showForgotPassphraseDialog() {
    showAppDialog(
      context: context,
      builder: (dialogContext) => ShadDialog(
        constraints: kAppDialogConstraints,
        title: Text('Forgot Passphrase'.tr()),
        actions: [
          shadDialogActionBar(
            actions: [
              ShadDialogAction(
                label: 'Cancel'.tr(),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
              ShadDialogAction(
                label: 'Reset Local Data'.tr(),
                destructive: true,
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  _confirmResetLocalData();
                },
              ),
            ],
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'There is no way to decrypt these notes without the passphrase. '
                      'With great security comes the great responsibility of '
                      'remembering the passphrase!'
                  .tr(),
            ),
            const SizedBox(height: 16),
            Text(
              'Before resetting, an encrypted snapshot of your local data will '
                      'be saved automatically to the app backups folder. If you '
                      'remember the passphrase later, the snapshot can be '
                      'recovered manually. This action cannot be undone.'
                  .tr(),
              style: TextStyle(
                color: ShadTheme.of(context).colorScheme.destructive,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 二次确认清空本地数据
  void _confirmResetLocalData() {
    showAppDialog(
      context: context,
      builder: (dialogContext) => ShadDialog(
        constraints: kAppDialogConstraints,
        title: Text('Confirm Reset'.tr()),
        actions: [
          shadDialogActionBar(
            actions: [
              ShadDialogAction(
                label: 'Cancel'.tr(),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
              ShadDialogAction(
                label: 'Delete Everything'.tr(),
                destructive: true,
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  _performLocalDataReset();
                },
              ),
            ],
          ),
        ],
        child: Text(
          'This will permanently delete all local notes and keyring data. '
                  'This action CANNOT be undone. Are you absolutely sure?'
              .tr(),
        ),
      ),
    );
  }

  /// 执行本地数据清空
  ///
  /// 流程:
  ///   1. 关闭数据库连接
  ///   2. 备份数据库文件 + 偏好快照到应用 backups/ 目录（安全网）
  ///   3. 删除 db 文件(包含 notes + sync_meta)
  ///   4. 清除 PreferencesStorage 中的 keyring 相关 key
  ///   5. 重启应用(走首次设置流程)
  ///
  /// 备份失败时中止重置：绝不允许「备份未完成但数据已删除」。
  Future<void> _performLocalDataReset() async {
    Log.auth.i('执行本地数据重置（清空 keyring 与 notes 数据库）');
    try {
      await NotesDatabase.instance.close();

      // 安全网：删除前把加密数据库 + 偏好快照保存到 backups/ 目录。
      // 若用户之后想起密码，快照仍可手动恢复。
      try {
        final backupDir = await backupVaultBeforeReset();
        if (mounted) {
          showSnackBarMessage(
            context,
            'Reset backup saved to: {path}'.tr(
              namedArgs: {'path': backupDir.path},
            ),
          );
        }
      } on Exception catch (e, st) {
        Log.auth.e('重置前备份失败，中止重置（原数据保留未删除）', error: e, stackTrace: st);
        if (mounted) {
          showErrorToast(
            context,
            'Reset aborted: backup failed: {error}'.tr(
              namedArgs: {'error': '$e'},
            ),
          );
        }
        return;
      }

      await NotesDatabase.instance.deleteDbFile();

      // 清除 keyring 相关 SharedPreferences key
      await PreferencesStorage.clearVaultRelatedKeys();

      // 重启应用:替换路由到 /authwall,会自动走 SetEncryptionPhrasePage
      if (mounted) {
        AppBootState.vaultInitialized = false;
        Navigator.pushNamedAndRemoveUntil(
          context,
          '/authwall',
          (route) => false,
          arguments: SessionArguments(
            sessionStream: widget.sessionStream,
            isKeyboardFocused: true,
          ),
        );
      }
    } on Exception catch (e) {
      if (mounted) {
        showErrorToast(
          context,
          'Reset failed: {error}'.tr(namedArgs: {'error': '$e'}),
        );
      }
    }
  }

  Future<bool> _authenticate() async {
    bool authenticated = false;

    if (_supportState == _BiometricState.unsupported) {
      showGenericDialog(
        context: context,
        message:
            "No biometrics found. Go to your device settings to enroll your biometric."
                .tr(),
      );
    } else if (forcePassphraseInput) {
      showGenericDialog(
        context: context,
        message:
            "Still remember your passphrase? Use passphrase to login this time."
                .tr(),
      );
    } else {
      PreferencesStorage.incrementBiometricAttemptAllTimeCount();
      try {
        authenticated = await auth.authenticate(
          localizedReason: 'Login using your biometric credential',
          persistAcrossBackgrounding: true,
        );
      } catch (e, st) {
        // F-M16：生物识别失败原因必须留痕，否则静默失败后只能靠"指纹不灵"猜
        Log.auth.w('生物识别认证失败', error: e, stackTrace: st);
      }
      if (authenticated) await _login(await BiometricAuth.authKey);
      if (authenticated) Log.auth.i('生物识别认证通过');
    }
    // _login 内部会 pushReplacement 跳转主界面并销毁本页，await 返回后可能已
    // unmounted；不判空直接 setState 会触发 "setState() called after dispose"
    // 的 FATAL。Argon2id 为纯 Dart 派生（无原生加速），移动端耗时更长，该竞态
    // 窗口被放大，故必须守卫 mounted（生物识别登录路径专属修复）。
    if (!mounted) return authenticated;
    setState(() {
      forcePassphraseInput =
          PreferencesStorage.biometricAttemptAllTimeCount % 5 == 0;
    });
    return authenticated;
  }
}

bool isPassphraseRememberChallenge() {
  return PreferencesStorage.biometricAttemptAllTimeCount == 0
      ? false
      : PreferencesStorage.biometricAttemptAllTimeCount %
                PreferencesStorage
                    .noOfLoginsBeforeNextPassphraseRememberChallenge ==
            0;
}

/// 远端验证三态结果(简化方案,评审 hy3 A7)
///
///   - verified: 密码正确,已通过远端 manifest header 验证并解锁
///   - wrongPassword: fingerprint 不匹配,密码错误,扣尝试次数
///   - unreachable: 网络故障/后端不可达,不扣尝试次数
enum RemoteVerifyResult { verified, wrongPassword, unreachable }

enum _BiometricState { unknown, supported, unsupported }
