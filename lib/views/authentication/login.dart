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
import 'dart:convert';

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Package imports:
import 'package:after_layout/after_layout.dart';
import 'package:crypto/crypto.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:safenotes_nord_theme/safenotes_nord_theme.dart';

// Project imports:
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
    Key? key,
    required this.sessionStream,
    this.isKeyboardFocused,
  }) : super(key: key);

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

  @override
  void initState() {
    super.initState();
    _noOfAllowedAttempts = PreferencesStorage.noOfLogginAttemptAllowed;
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

  _buildTimeOut() {
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

  String? _passphraseValidator(String? passphrase) {
    final numberOfAttemptExceeded = 'Number of attempt exceeded'.tr();

    if (_noOfAllowedAttempts <= 1) {
      setState(() {
        _isLocked = true;
      });
      return numberOfAttemptExceeded;
    }

    if (sha256.convert(utf8.encode(passphrase!)).toString() !=
        PreferencesStorage.passPhraseHash) {
      _noOfAllowedAttempts--;
      final wrongPhraseMsg =
          'Wrong passphrase {noOfAllowedAttempts} attempts left!'.tr(
              namedArgs: {
            'noOfAllowedAttempts': _noOfAllowedAttempts.toString()
          });

      return _noOfAllowedAttempts == 0
          ? numberOfAttemptExceeded
          : wrongPhraseMsg;
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
    final String loginText = 'Login'.tr();

    return ButtonWidget(
      text: loginText,
      onClicked: _isLocked ? null : () async => _loginController(),
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

  Future<void> _login(String passphrase) async {
    final snackMsgDecryptingNotes = 'Decrypting your notes!'.tr();
    final snackMsgWrongEncryptionPhrase = 'Wrong passphrase!'.tr();

    // B2 修复：本地 hash 不再是登录的唯一凭证。
    // 他端改密码后，本端 PreferencesStorage.passPhraseHash 仍是旧值，
    // 用户输入新密码时 hash 不匹配，但密码其实是正确的（远端已生效）。
    // 流程：
    //   1. 本地 hash 匹配 → 走原版快速路径
    //   2. hash 不匹配 → 尝试 Vault 解锁（本地 vault 元数据 + 远端 manifest header）
    //      - 本地 vault 已初始化 → Vault.unlockLocal（验证本地 encryptedDataKey）
    //      - 本地 vault 未初始化 或 unlockLocal 失败 → 从远端拉 manifest header，
    //        用输入密码派生 MK，比对 keyFingerprint，匹配则 unlockFromRemoteManifest
    //   3. 上述都失败 → 密码真的错误
    final isLocalHashMatch =
        sha256.convert(utf8.encode(passphrase)).toString() ==
            PreferencesStorage.passPhraseHash;

    if (!isLocalHashMatch) {
      // 尝试用 vault 验证密码（B2 修复）
      final verified = await _tryVerifyPassphraseViaVault(passphrase);
      if (!verified) {
        // vault 也解不开 → 密码错误
        if (mounted) {
          showSnackBarMessage(context, snackMsgWrongEncryptionPhrase);
        }
        return;
      }
      // verified=true：密码正确但本地 hash 过时，下面走正常登录流程
      // _initVault 会通过 Vault API 更新本地 hash
    }

    if (mounted) {
      showSnackBarMessage(context, snackMsgDecryptingNotes);
    }
    Session.login(passphrase);

    // re-enable biometric auth
    if (forcePassphraseInput) {
      PreferencesStorage.incrementBiometricAttemptAllTimeCount();
    }

    // start listening for session inactivity on successful login
    widget.sessionStream.add(SessionState.startListening);

    // D1 修复：_initVault 返回 bool，失败时停留在登录页不导航到 /home
    final ok = await _initVault(passphrase);
    if (!ok) return;

    if (!mounted) return;
    await Navigator.pushReplacementNamed(
      context,
      '/home',
      arguments: widget.sessionStream,
    );
  }

  /// B2 修复：本地 hash 不匹配时，用 Vault 验证密码
  ///
  /// 尝试顺序：
  ///   1. 本地 vault 已初始化 → Vault.unlockLocal
  ///      - 成功：密码与本地 encryptedDataKey 匹配（本端密码未变，仅 hash 过时）
  ///      - 失败：本地密码可能已变（他端改密码并同步了新 encryptedDataKey 到远端）
  ///   2. 本地 vault 未初始化 或 unlockLocal 失败 → 从远端拉 manifest header
  ///      - 用输入密码 + header.kdf.salt 派生 MK
  ///      - 比对 MK 的 fingerprint 与 header.keyFingerprint
  ///      - 匹配 → 调用 Vault.unlockFromRemoteManifest 持久化并解锁
  ///      - 不匹配 → 密码真的错误，返回 false
  ///
  /// 返回 true 表示密码已通过 vault 验证（本地或远端）。
  /// 返回 false 表示密码错误，应提示用户。
  /// 任何异常（网络故障、远端不可达）都视为验证失败，回退到密码错误提示。
  Future<bool> _tryVerifyPassphraseViaVault(String passphrase) async {
    final database = NotesDatabase.instance;

    // 1. 尝试本地 vault 解锁
    final isInitialized = await Vault.isInitialized(database);
    if (isInitialized) {
      try {
        final vault = await Vault.unlockLocal(
          password: passphrase,
          database: database,
        );
        // 本地解锁成功：密码正确，与本地 encryptedDataKey 匹配
        // 更新本地 hash（passPhraseHash 过时了），并注入 dataKey
        await _updateLocalHashAndDataKey(passphrase, vault);
        return true;
      } on Exception {
        // 本地解锁失败，继续尝试远端
      }
    }

    // 2. 从远端拉 manifest header 验证
    return _tryVerifyPassphraseViaRemote(passphrase, database, isInitialized);
  }

  /// 从远端 manifest header 验证密码（B2 子流程）
  ///
  /// 流程：
  ///   - 创建后端实例（基于 SyncConfig），init + getManifest
  ///   - 仅解析 header（明文），拿到 kdf.salt + keyFingerprint + encryptedDataKey
  ///   - 用输入密码 + salt 派生 MK，计算 fingerprint 比对
  ///   - 匹配 → Vault.unlockFromRemoteManifest 持久化并解锁
  ///
  /// [localVaultInitialized] 用于日志诊断，不影响流程
  Future<bool> _tryVerifyPassphraseViaRemote(
    String passphrase,
    NotesDatabase database,
    bool localVaultInitialized,
  ) async {
    // 确保 SyncConfig 已加载
    await SyncConfig.init();
    if (!SyncConfig.isSyncEnabled) {
      // 未配置同步后端：无法从远端验证，密码错误
      return false;
    }

    try {
      // 创建后端实例（直接通过 SyncService 的公开工厂，避免污染单例状态）
      final backend = SyncService.instance.createBackendForVerification();
      if (backend == null) return false;

      await backend.init();
      final remoteResponse = await backend.getManifest();
      if (remoteResponse.ciphertext.isEmpty) {
        // 远端无 manifest：无法验证
        await backend.close();
        return false;
      }

      // 仅解析 header（不需要 dataKey）
      final header =
          ManifestCrypto.deserializeHeaderOnly(remoteResponse.ciphertext);

      // 用输入密码 + 远端 salt 派生 MK，比对 fingerprint
      final mk = await SyncCrypto.deriveMasterKeyAsync(
        passphrase,
        salt: header.kdf.saltBytes,
      );
      final fp = SyncCrypto.computeKeyFingerprint(mk);
      if (fp != header.keyFingerprint) {
        // fingerprint 不匹配 → 密码错误
        await backend.close();
        return false;
      }

      // fingerprint 匹配 → 密码正确，用远端 encryptedDataKey 解锁
      await Vault.unlockFromRemoteManifest(
        password: passphrase,
        remoteVaultId: header.vaultId,
        remoteEncryptedDataKey: header.encryptedDataKey,
        remoteKdf: header.kdf,
        remoteKeyFingerprint: header.keyFingerprint,
        remoteKeyVersion: header.keyVersion,
        remoteCreatedAt: header.createdAt,
        database: database,
      );

      await backend.close();

      // 更新本地 hash + 注入 dataKey
      // 注意：unlockFromRemoteManifest 内部已持久化 vault 元数据，
      // 但没有调用 database.setDataKey，需要补上
      final vault = await Vault.unlockLocal(
        password: passphrase,
        database: database,
      );
      await _updateLocalHashAndDataKey(passphrase, vault);
      return true;
    } on Exception {
      // 任何异常（网络故障、后端不可达、解析失败）都视为验证失败
      return false;
    }
  }

  /// 更新本地 passPhraseHash 并注入 dataKey 到 database
  ///
  /// 在 _tryVerifyPassphraseViaVault 验证成功后调用：
  ///   - 把 passPhraseHash 更新为当前密码的 hash（修复 hash 过时问题）
  ///   - 把 dataKey 注入 database（启用本地加解密）
  ///   - 缓存 vault 到 SyncService（供后续 SyncEngine 使用）
  Future<void> _updateLocalHashAndDataKey(
    String passphrase,
    Vault vault,
  ) async {
    // 更新本地 hash 为当前密码（B2：他端改密码后本端 hash 过时）
    await PreferencesStorage.setPassPhraseHash(
      sha256.convert(utf8.encode(passphrase)).toString(),
    );
    // 注入 dataKey 到 database
    NotesDatabase.instance.setDataKey(vault.dataKey);
    // 缓存 vault 引用（SyncService._vault，供 initBackend 使用）
    await SyncService.instance.cacheVaultFromLogin(vault);
  }

  /// 登录后初始化 Vault：解锁 dataKey + 注入 database
  ///
  /// D1 修复：返回 bool 表示是否成功。
  ///   - true：vault 初始化成功（可能后端初始化失败，但 vault 已就绪）
  ///   - false：vault 初始化失败，调用方不应导航到 /home
  ///
  /// 注意：如果 _tryVerifyPassphraseViaVault 已完成 vault 解锁（B2 路径），
  /// 此方法会跳过重复解锁，直接初始化后端。
  Future<bool> _initVault(String passphrase) async {
    // B2 路径：vault 已在 _tryVerifyPassphraseViaVault 中解锁并缓存到 SyncService
    // 此时直接走 initBackend 流程
    if (SyncService.instance.vault != null) {
      return _initBackendOnly();
    }

    // 标准路径：本地 hash 匹配，通过 SyncService.initVaultFromPassword 解锁
    final result = await SyncService.instance.initVaultFromPassword(
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

    return _initBackendOnly();
  }

  /// 初始化同步后端（如果已配置）
  ///
  /// 返回 true 表示 vault 已就绪（无论后端是否成功）。
  /// 后端失败只提示不阻断进入 home 页——用户可在设置页修复后端配置。
  Future<bool> _initBackendOnly() async {
    await SyncConfig.init();
    if (!SyncConfig.isSyncEnabled) {
      return true;
    }

    final backendResult = await SyncService.instance.initBackend(
      database: NotesDatabase.instance,
    );
    if (!backendResult.success && mounted) {
      showSnackBarMessage(
        context,
        '同步初始化失败：${backendResult.error ?? "未知错误"}',
      );
    }
    // 登录后执行一次初始同步，拉取远端最新数据
    // autoSync 内部会判断 _engine 是否就绪，未就绪则直接返回
    SyncService.instance.autoSync();
    return true;
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
        onPressed: () {
          showGenericDialog(
            context: context,
            icon: Icons.info_outline,
            message:
                'There is no way to decrypt these notes without the passphrase. With great security comes the great responsibility of remembering the passphrase!'
                    .tr(),
          );
        },
      ),
    );
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

int _noOfAllowedAttempts = PreferencesStorage.noOfLogginAttemptAllowed;
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
        _noOfAllowedAttempts = PreferencesStorage.noOfLogginAttemptAllowed;
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

enum _BiometricState { unknown, supported, unsupported }
