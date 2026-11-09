/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/proxy_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

/// 网络代理设置页面
class ProxySettingsPage extends StatefulWidget {
  const ProxySettingsPage({super.key});

  @override
  State<ProxySettingsPage> createState() => _ProxySettingsPageState();
}

class _ProxySettingsPageState extends State<ProxySettingsPage> {
  late bool _enabled;
  late final TextEditingController _addressController;

  bool _testing = false;
  String? _testResultText;
  bool? _testSuccess;

  @override
  void initState() {
    super.initState();
    _enabled = ProxyConfig.isProxyEnabled;
    _addressController = TextEditingController(text: ProxyConfig.proxyAddress);
  }

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    final addr = _addressController.text.trim();
    if (addr.isEmpty) {
      showSnackBarMessage(context, 'Please enter a proxy server address'.tr());
      return;
    }

    setState(() {
      _testing = true;
      _testResultText = null;
      _testSuccess = null;
    });

    final result = await ProxyConfig.testConnectivity(addr);
    if (!mounted) return;

    setState(() {
      _testing = false;
      _testSuccess = result.success;
      if (result.success) {
        _testResultText = 'Proxy server is reachable'.tr();
      } else {
        _testResultText = 'Proxy connection failed: {error}'.tr(
          namedArgs: {'error': result.message ?? 'Unknown error'.tr()},
        );
      }
    });
  }

  Future<void> _save() async {
    final addr = _addressController.text.trim();
    await ProxyConfig.setProxyAddress(addr);
    await ProxyConfig.setProxyEnabled(_enabled);

    // 若同步服务已就绪，通知其热重载底层连接
    if (SyncService.instance.state.isInitialized) {
      await SyncService.instance.applyConfigToService(
        database: NotesDatabase.instance,
      );
    }

    if (!mounted) return;
    showSnackBarMessage(context, 'Proxy settings saved'.tr());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('Network Proxy'.tr(), style: appBarTitle),
        actions: [
          if (!kIsWeb)
            IconButton(
              icon: const Icon(LucideIcons.check),
              tooltip: 'Save'.tr(),
              onPressed: _save,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: shadSettingsList([
        if (kIsWeb) ...[
          shadSettingsCard([
            shadInfoTile(
              context,
              icon: LucideIcons.info,
              title: 'Web Platform'.tr(),
              value: 'Managed by browser'.tr(),
              description: 'Web proxy managed by browser'.tr(),
            ),
          ]),
          const SizedBox(height: 12),
        ],
        shadSettingsCard([
          shadSwitchTile(
            context,
            icon: LucideIcons.globe,
            title: 'Enable Proxy'.tr(),
            description: 'Route sync network traffic through proxy'.tr(),
            value: _enabled,
            onChanged: kIsWeb
                ? (_) {}
                : (value) {
                    setState(() => _enabled = value);
                  },
          ),
        ]),
        if (!kIsWeb) ...[
          shadSectionTitle(context, 'Proxy Server'.tr()),
          ShadCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Server Address'.tr(),
                  style: theme.textTheme.small.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.mutedForeground,
                  ),
                ),
                const SizedBox(height: 8),
                ShadInput(
                  controller: _addressController,
                  placeholder: const Text('127.0.0.1:7890'),
                  padding: kInputPadding,
                  leading: const Icon(LucideIcons.server, size: 18),
                  trailing: _addressController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(LucideIcons.x, size: 16),
                          tooltip: 'Clear'.tr(),
                          onPressed: () {
                            _addressController.clear();
                            setState(() {});
                          },
                        )
                      : null,
                  enabled: !_testing,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                Text(
                  'Supports formats: host:port, http://host:port, socks5://host:port'
                      .tr(),
                  style: theme.textTheme.muted.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
          shadSectionTitle(context, 'Actions'.tr()),
          shadSettingsCard([
            shadNavigationTile(
              context,
              icon: LucideIcons.zap,
              title: 'Test Connection'.tr(),
              value: _testing
                  ? 'Testing...'.tr()
                  : (_testSuccess == true ? 'Connected'.tr() : ''),
              subtitle: _testResultText,
              onTap: _testing ? () {} : _testConnection,
            ),
            shadActionTile(
              context,
              icon: LucideIcons.check,
              title: 'Save Settings'.tr(),
              onTap: _save,
            ),
          ]),
        ],
        const SizedBox(height: 24),
      ]),
    );
  }
}
