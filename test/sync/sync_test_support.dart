/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 同步测试公共支撑（re-export core 版本）。
//
// 本文件是 app 侧测试（change_password_multi_client_test）对 core 测试支撑的
// 唯一引用点：避免在根 test/ 复制一份导致两处代码漂移。
// core 包测试直接在包内引用 packages/core/test/sync/sync_test_support.dart。
export '../../packages/core/test/sync/sync_test_support.dart';
