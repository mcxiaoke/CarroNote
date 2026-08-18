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

import 'dart:ui' as ui;

// RTL 检测暂时禁用：完整正文检测成本过高（根因 3），且当前不支持 RTL 排版。
// 统一返回 LTR，避免对每条笔记正文做 Bidi 全文扫描。
bool isRTL(String text) => false;

ui.TextDirection getTextDirecton(String text) => ui.TextDirection.ltr;
