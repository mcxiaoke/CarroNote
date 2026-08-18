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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:core/core.dart';

class AppLifecycleEventHandler extends WidgetsBindingObserver {
  final AsyncCallback? resumeCallBack;
  final AsyncCallback? inactiveCallBack;
  final AsyncCallback? pausedCallBack;
  final AsyncCallback? detachedCallBack;
  final AsyncCallback? hiddenCallBack;

  AppLifecycleEventHandler({
    this.resumeCallBack,
    this.inactiveCallBack,
    this.pausedCallBack,
    this.detachedCallBack,
    this.hiddenCallBack,
  });

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    // 集中记录所有 OS 生命周期状态切换(底层唯一入口)。
    // resumed/paused 的「业务动作」日志在 main.dart 的回调闭包里以 info 级别记录,
    // 此处仅记录原始状态切换,避免重复 info;detached 是退出路径,提升为 info。
    switch (state) {
      case AppLifecycleState.resumed:
        Log.app.d('生命周期: resumed (OS 前台)');
        await _executeCallback(resumeCallBack);
        break;
      case AppLifecycleState.inactive:
        Log.app.d('生命周期: inactive');
        await _executeCallback(inactiveCallBack);
        break;
      case AppLifecycleState.paused:
        Log.app.d('生命周期: paused (OS 后台)');
        await _executeCallback(pausedCallBack);
        break;
      case AppLifecycleState.detached:
        Log.app.i('生命周期: detached (应用即将分离/退出)');
        await _executeCallback(detachedCallBack);
        break;
      case AppLifecycleState.hidden:
        Log.app.d('生命周期: hidden');
        await _executeCallback(hiddenCallBack);
        break;
    }
  }

  Future<void> _executeCallback(AsyncCallback? callback) async {
    if (callback != null) {
      await callback();
    }
  }
}
