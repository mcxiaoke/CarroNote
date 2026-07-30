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
import 'package:easy_localization/easy_localization.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:safenotes_nord_theme/safenotes_nord_theme.dart';

// Project imports:
import 'package:safenotes/authwall.dart';
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/generic.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/sync/vault.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/footer.dart';
import 'package:safenotes/widgets/login_button.dart';

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
  GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final passPhraseController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool? _isKeyboardFocused;
  bool _isHidden = true;
  bool _isLocked = false;

  // 简化方案:登录验证改为 async(vault 解密 1-2 秒),需要防重入
  // _isLoggingIn=true 期间禁用登录按钮,避免 PBKDF2 期间连点触发并发验证
  bool _isLoggingIn = false;

  // 简化方案:限流计数从 validator(sync)迁移到 _login 失败分支(async)
  // 原本 validator 里 hash 比对失败时递减,现在 validator 只做长度检查
  int _noOfAllowedAttempts = PreferencesStorage.noOfLogginAttemptAllowed;

  @override
  void initState() {
    super.initState();
    _isKeyboardFocused = widget.isKeyboardFocused ?? true;

    // BiometricAuth:
    auth.isDeviceSupported().then(
      (bool isSupported) {
        setState(() => _supportState = isSupported
            ? _BiometricState.supported
            : _BiometricState.unsupported);
      },
    );
  }

  @override
  void dispose() {
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
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    scrollToBottomIfOnScreenKeyboard();

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: Text(
            'Login'.tr(),
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
                    _buildLoginWorkflow(context: context),
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

  void scrollToBottomIfOnScreenKeyboard() {
    try {
      if (MediaQuery.of(context).viewInsets.bottom > 0) {
        _scrollController.animateTo(_scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 500), curve: Curves.ease);
      }
    } catch (_) {}
  }

  Widget _buildTopLogo() {
    final double topPadding = MediaQuery.of(context).size.height * 0.050;
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
          child: Image.asset(
            SafeNotesConfig.appLogoPath,
          ),
        ),
      ),
    );
  }

  Widget _buildLoginWorkflow({required BuildContext context}) {
    const double padding = 16.0;

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
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
    );
  }

  Widget _buildTimeOut() {
    if (_isLocked) {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
      passPhraseController.clear();

      _startTimer(
        () {
          setState(
            () {
              _isLocked = false;
              _isKeyboardFocused = true;
              _formKey = GlobalKey<FormState>();
              // 简化方案:锁定超时后重置尝试次数(原为全局变量,现为实例字段)
              _noOfAllowedAttempts =
                  PreferencesStorage.noOfLogginAttemptAllowed;
            },
          );
        },
      );

      return StreamBuilder(
        stream: _controller.stream,
        builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
          String? timeLeft =
              snapshot.hasData ? snapshot.data : _lockoutTime.toString();
          return Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Align(
              alignment: Alignment.center,
              child: Text(
                'Exceeded number of attempts, try after {timeLeft} seconds'
                    .tr(namedArgs: {'timeLeft': timeLeft.toString()}),
                style: TextStyle(
                  color: NordColors.aurora.red,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          );
        },
      );
    }
    return const SizedBox(height: 20);
  }

  Widget _inputField() {
    const double inputBoxEdgeRadious = 10.0;

    return TextFormField(
      enabled: !_isLocked,
      enableIMEPersonalizedLearning: false,
      controller: passPhraseController,
      autofocus: _isKeyboardFocused!,
      obscureText: _isHidden,
      decoration: _inputFieldDecoration(inputBoxEdgeRadious),
      autofillHints: const [AutofillHints.password],
      keyboardType: TextInputType.visiblePassword,
      onEditingComplete: _loginController,
      validator: _passphraseValidator,
    );
  }

  /// 简化方案:validator 只做长度检查 + 锁定判断
  ///
  /// 密码正确性不在 validator 里判断(vault 解密是 async,1-2 秒),
  /// 改在 _login 里 async 处理,失败时在 _onLoginFailure 递减尝试次数。
  String? _passphraseValidator(String? passphrase) {
    final numberOfAttemptExceeded = 'Number of attempt exceeded'.tr();

    if (_noOfAllowedAttempts <= 1) {
      setState(() {
        _isLocked = true;
      });
      return numberOfAttemptExceeded;
    }

    if (passphrase == null || passphrase.isEmpty) {
      return 'Enter Passphrase'.tr();
    }

    return null;
  }

  InputDecoration _inputFieldDecoration(double inputBoxEdgeRadious) {
    final String hintText = 'Enter Passphrase'.tr();

    return InputDecoration(
      hintText: hintText,
      label: Text('Passphrase'.tr()),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(inputBoxEdgeRadious),
      ),
      prefixIcon: const Icon(Icons.lock),
      suffixIcon: IconButton(
        icon: !_isHidden
            ? const Icon(Icons.visibility_off)
            : const Icon(Icons.visibility),
        onPressed: _togglePasswordVisibility,
      ),
    );
  }

  void _togglePasswordVisibility() {
    setState(() => _isHidden = !_isHidden);
  }

  Widget _buildLoginButton() {
    // 简化方案:验证中(_isLoggingIn)或锁定(_isLocked)时禁用按钮防重入
    final String loginText =
        _isLoggingIn ? 'Verifying...'.tr() : 'Login'.tr();

    return ButtonWidget(
      text: loginText,
      onClicked: (_isLocked || _isLoggingIn) ? null : () async => _loginController(),
    );
  }

  Widget _buildBiometricAuthButton(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            'OR'.tr(),
            style: const TextStyle(fontSize: 15),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 20),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                shadowColor: PreferencesStorage.isThemeDark
                    ? NordColors.snowStorm.lightest
                    : NordColors.polarNight.darkest,
                minimumSize: const Size(200, 50), //Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                elevation: 5.0,
              ),
              onPressed: (PreferencesStorage.isBiometricAuthEnabled &&
                      !forcePassphraseInput &&
                      !_isLocked)
                  ? _authenticate
                  : null,
              child: Wrap(
                children: <Widget>[
                  const Icon(
                    Icons.fingerprint,
                    size: 30.0,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Biometric'.tr(),
                    style: const TextStyle(fontSize: 20),
                  ),
                ],
              ),
            ),
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
      showSnackBarMessage(context, snackMsgWrongEncryptionPhrase);
    }
  }

  /// 简化方案:统一 async 登录验证
  ///
  /// 流程:
  ///   1. 本地 vault 解锁(优先):Vault.unlockLocal 成功 = 密码正确
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
      final isInitialized = await Vault.isInitialized(database);

      // 1. 本地 vault 解锁(优先)
      if (isInitialized) {
        final result = await SyncService.instance.initVaultFromPassword(
          password: passphrase,
          database: database,
        );
        if (result.success) {
          await _onLoginSuccess(passphrase);
          return;
        }
        // result.success == false:密码错误或 vault 损坏,继续尝试远端
      }

      // 2. 仅在启用同步时尝试远端验证
      //    避免无条件触发远端(隐私泄露 + 离线暴力放大,评审 kk27c P1)
      await SyncConfig.init();
      if (SyncConfig.isSyncEnabled) {
        final remoteResult = await _tryVerifyPassphraseViaRemote(passphrase);
        if (remoteResult == RemoteVerifyResult.verified) {
          await _onLoginSuccess(passphrase);
          return;
        }
        if (remoteResult == RemoteVerifyResult.unreachable) {
          // 网络不可达:不算密码错误,不扣尝试次数
          if (mounted) {
            showSnackBarMessage(
              context,
              '无法验证密码(网络不可用),请检查网络后重试',
            );
          }
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
    if (mounted) {
      showSnackBarMessage(context, 'Decrypting your notes!'.tr());
    }
    Session.login(passphrase);

    // re-enable biometric auth
    if (forcePassphraseInput) {
      PreferencesStorage.incrementBiometricAttemptAllTimeCount();
    }

    // start listening for session inactivity on successful login
    widget.sessionStream.add(SessionState.startListening);

    // 初始化后端(如果已配置),失败不阻断进入 home
    await SyncConfig.init();
    if (SyncConfig.isSyncEnabled) {
      final backendResult = await SyncService.instance.initBackend(
        database: NotesDatabase.instance,
      );
      if (!backendResult.success && mounted) {
        showSnackBarMessage(
          context,
          '同步初始化失败:${backendResult.error ?? "未知错误"}',
        );
      }
      // 登录后执行一次初始同步,拉取远端最新数据
      SyncService.instance.autoSync();
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
    _noOfAllowedAttempts--;
    final numberOfAttemptExceeded = 'Number of attempt exceeded'.tr();

    if (_noOfAllowedAttempts <= 0) {
      setState(() => _isLocked = true);
      if (mounted) {
        showSnackBarMessage(context, numberOfAttemptExceeded);
      }
    } else {
      final wrongPhraseMsg =
          'Wrong passphrase {noOfAllowedAttempts} attempts left!'.tr(
              namedArgs: {
            'noOfAllowedAttempts': _noOfAllowedAttempts.toString()
          });
      if (mounted) {
        showSnackBarMessage(context, wrongPhraseMsg);
      }
    }
  }

  /// 远端验证三态结果(评审 hy3 A7)
  ///
  ///   - verified: 密码正确,已通过远端 manifest header 验证并解锁
  ///   - wrongPassword: fingerprint 不匹配,密码错误,扣尝试次数
  ///   - unreachable: 网络故障/后端不可达,不扣尝试次数
  Future<RemoteVerifyResult> _tryVerifyPassphraseViaRemote(
    String passphrase,
  ) async {
    try {
      final database = NotesDatabase.instance;
      // 创建后端实例(直接通过 SyncService 的公开工厂,避免污染单例状态)
      final backend = SyncService.instance.createBackendForVerification();
      if (backend == null) return RemoteVerifyResult.unreachable;

      await backend.init();
      final remoteResponse = await backend.getManifest();
      if (remoteResponse.ciphertext.isEmpty) {
        // 远端无 manifest:无法验证,视为密码错误(本地也解不开)
        await backend.close();
        return RemoteVerifyResult.wrongPassword;
      }

      // 仅解析 header(不需要 dataKey)
      final header =
          ManifestCrypto.deserializeHeaderOnly(remoteResponse.ciphertext);

      // 用输入密码 + 远端 salt 派生 MK,比对 fingerprint
      final mk = await SyncCrypto.deriveMasterKeyAsync(
        passphrase,
        salt: header.kdf.saltBytes,
      );
      final fp = SyncCrypto.computeKeyFingerprint(mk);
      if (fp != header.keyFingerprint) {
        // fingerprint 不匹配 → 密码错误
        await backend.close();
        return RemoteVerifyResult.wrongPassword;
      }

      // fingerprint 匹配 → 密码正确,用远端 encryptedDataKey 解锁
      await Vault.unlockFromRemoteManifest(
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

      await backend.close();

      // unlockFromRemoteManifest 内部已持久化 vault 元数据,
      // 但没有调用 database.setDataKey,需要补上
      // (用刚持久化的远端元数据重新 unlockLocal 拿到 dataKey)
      final vault = await Vault.unlockLocal(
        password: passphrase,
        database: database,
      );
      NotesDatabase.instance.setDataKey(vault.dataKey);
      await SyncService.instance.cacheVaultFromLogin(vault);
      return RemoteVerifyResult.verified;
    } on Exception {
      // 网络故障、后端不可达、解析失败等 → unreachable(不扣次数)
      return RemoteVerifyResult.unreachable;
    }
  }

  Widget _buildForgotPassphrase() {
    final String cantRecoverPassphraseMsg =
        "Can't decrypt without phrase!".tr();
    double fontSize = 10;

    return Container(
      alignment: Alignment.centerRight,
      child: TextButton(
        child: Text(
          cantRecoverPassphraseMsg,
          style: TextStyle(
            fontSize: fontSize,
          ),
        ),
        onPressed: () => _showForgotPassphraseDialog(),
      ),
    );
  }

  /// 忘记密码逃生通道(评审 hy3 第6节)
  ///
  /// 简化后 Vault.isInitialized==true → 一律进登录页,以下场景用户会被困住:
  ///   - 忘记密码
  ///   - 清除 SharedPreferences/重装但 db 残留
  ///
  /// 提供"清空本地数据重新开始"入口:
  ///   - 红色危险操作 + 二次确认
  ///   - 明确告知数据不可恢复
  ///   - 执行后删除 db 文件 + vault 元数据,重启走首次设置流程
  void _showForgotPassphraseDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Forgot Passphrase'.tr()),
        content: Column(
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
              'If you have a backup, you can reset the local data and re-import '
              'the backup after setting a new passphrase. This action cannot be '
              'undone.'
                  .tr(),
              style: TextStyle(
                color: NordColors.aurora.red,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('Cancel'.tr()),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: NordColors.aurora.red,
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _confirmResetLocalData();
            },
            child: Text('Reset Local Data'.tr()),
          ),
        ],
      ),
    );
  }

  /// 二次确认清空本地数据
  void _confirmResetLocalData() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Confirm Reset'.tr()),
        content: Text(
          'This will permanently delete all local notes and vault data. '
          'This action CANNOT be undone. Are you absolutely sure?'
              .tr(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('Cancel'.tr()),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: NordColors.aurora.red,
            ),
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await _performLocalDataReset();
            },
            child: Text('Delete Everything'.tr()),
          ),
        ],
      ),
    );
  }

  /// 执行本地数据清空
  ///
  /// 流程:
  ///   1. 关闭数据库连接
  ///   2. 删除 db 文件(包含 notes + sync_meta)
  ///   3. 清除 PreferencesStorage 中的 vault 相关 key
  ///   4. 重启应用(走首次设置流程)
  Future<void> _performLocalDataReset() async {
    try {
      await NotesDatabase.instance.close();
      await NotesDatabase.instance.deleteDbFile();

      // 清除 vault 相关 SharedPreferences key
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
        showSnackBarMessage(context, '重置失败:$e');
      }
    }
  }

  Future<bool> _authenticate() async {
    bool authenticated = false;

    if (_supportState == _BiometricState.unsupported) {
      showGenericDialog(
        context: context,
        icon: Icons.error_outline,
        message:
            "No biometrics found. Go to your device settings to enroll your biometric."
                .tr(),
      );
    } else if (forcePassphraseInput) {
      showGenericDialog(
        context: context,
        icon: Icons.info_outline,
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
      } catch (_) {}
      if (authenticated) await _login(await BiometricAuth.authKey);
    }
    setState(() {
      forcePassphraseInput =
          PreferencesStorage.biometricAttemptAllTimeCount % 5 == 0;
    });
    return authenticated;
  }
}

int _lockoutTime = PreferencesStorage.bruteforceLockOutTime;
int _counter = 0;

Timer? _timer;
StreamController<String> _controller = StreamController<String>.broadcast();

void _startTimer(VoidCallback callback) {
  _counter = _lockoutTime;

  if (_timer != null) _timer?.cancel();

  _timer = Timer.periodic(
    const Duration(seconds: 1),
    (timer) {
      (_counter > 0) ? _counter-- : _timer?.cancel();
      _controller.add(_counter.toString().padLeft(2, '0'));
      if (_counter <= 0) {
        callback();
      }
    },
  );
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
