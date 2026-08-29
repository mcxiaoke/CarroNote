/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'package:flutter/material.dart';

/// 全局路由观察者。
///
/// 用于主界面（[HomePage]）感知从子页面（如设置页）返回，
/// 以便按最新偏好重新排序笔记列表。在 [App] 中注册到
/// [MaterialApp.navigatorObservers]。
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();
