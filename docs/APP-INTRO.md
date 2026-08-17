# 萝笺 / CarroNote — 应用介绍
# CarroNote — App Introduction

> 本文档为对外发布稿，全部对外内容中英文双语。
> This is a publishable document; all external content is bilingual.
> 版本 / Version：1.0　日期 / Date：2026-08-17

---

## 一句话介绍 / One-line intro

> 萝笺是一款端到端加密的私密笔记应用，让每一页只属于你。
>
> CarroNote is an end-to-end encrypted private note app where every page belongs only to you.

> 萝笺，安心写下每一笺。
> CarroNote, write safely on every page.

---

## 概述 / Overview

> 萝笺（CarroNote）是一款注重隐私的笔记应用：所有笔记默认在本地设备上加密存储（AES-256-GCM），不依赖任何第三方云。它以奶油黄与胡萝卜书页为视觉基调，把"加密隐私"变得温柔可亲——私密记录，也可以很安心。
>
> CarroNote is a privacy-focused note app: all notes are encrypted at rest on your device by default (AES-256-GCM), with no dependency on any third-party cloud. Its cream-yellow and carrot-on-paper visual identity makes encryption feel warm and approachable — private writing can feel safe, too.

> 萝笺 · 所记皆安心
> CarroNote · your words kept safe

---

## 核心特性 / Key Features

### 端到端加密 / End-to-end encryption

> 笔记在你的设备上加密后才离开本机。即使通过自建服务同步，服务端也只见到密文，永远拿不到明文。
>
> Notes are encrypted on your device before they ever leave it. Even when synced through your own server, the server sees only ciphertext — never plaintext.

### 本地优先 / Local-first

> 没有网络也能用。所有笔记默认以加密形式存放在本机，离线记录、联网后再同步。
>
> Works offline. All notes are stored encrypted on your device by default; write offline, sync when connected.

### 多端同步 / Multi-device sync

> 改一次密码，全设备原子生效；WebDAV（坚果云 / NextCloud / 自建）、自建 SafeServer HTTP、或本地文件系统，任选后端。
>
> Change your password once and it propagates atomically to every device. Pick any backend: WebDAV (Jianguoyun / NextCloud / self-hosted), self-hosted SafeServer HTTP, or local filesystem.

### 生物识别解锁 / Biometric unlock

> 指纹或面容快速解锁，不必每次输入主密码。
>
> Unlock instantly with fingerprint or face — no need to type your master passphrase every time.

### 隐私防护 / Privacy protection

> 安卓后台快照保护、隐身键盘、防截屏，从系统层面减少泄露面。
>
> Android background-snapshot protection, stealth keyboard, and screenshot protection reduce the leak surface at the OS level.

### 防破解与自动锁定 / Anti-brute-force & auto-lock

> 暴力破解防护 + 闲置自动锁定，手机离手即锁。
>
> Brute-force protection plus inactivity auto-lock — your phone locks the moment it leaves your hand.

### 加密备份 / Encrypted backup

> 加密导出 / 导入，换机不丢笔记，迁移无缝。
>
> Encrypted export / import — switch devices without losing a single note, migration included.

### 彩色笔记与主题 / Colored notes & themes

> 列表 / 网格视图、彩色笔记，默认奶油黄浅色主题，并支持深色模式。
>
> List / grid views and colored notes, with the cream-yellow light theme by default and a dark mode available.

---

## 它是怎么工作的 / How it works

> 萝笺采用 **MK + dataKey 两层密钥**：主密码（MK）只用来保护一把数据密钥（dataKey），真正的笔记用 dataKey 加密。改密码时只需重加密 dataKey，复杂度 O(1) 且原子完成——你的笔记内容本身不会被反复重写。
>
> CarroNote uses a **two-layer key hierarchy: MK + dataKey**. Your master passphrase (MK) only protects a data key (dataKey); the notes themselves are encrypted with the dataKey. Changing your password only re-encrypts the dataKey — O(1) and atomic — so your note contents are never rewritten en masse.

> 内容按内容寻址（content hash）天然去重，配合软删除 / 墓碑同步、LWW 冲突解决与历史版本保留，多设备之间既一致又可追溯。
>
> Content is content-addressed (content hash) for natural deduplication, with soft-delete / tombstone sync, LWW conflict resolution, and version history — consistent and traceable across devices.

---

## 多端支持 / Platforms

> 安卓、iOS、Windows、Web、Linux 多端覆盖；并提供纯 Dart 命令行客户端，无需 Flutter SDK 即可读写同一加密数据库。
>
> Android, iOS, Windows, Web, and Linux — plus a pure-Dart CLI client that reads and writes the same encrypted database without the Flutter SDK.

---

## 安全承诺 / Security promise

> 再强的加密，也要求你牢记自己的主密码。密码只存在于你的脑中，任何人都无法帮你找回——包括我们。
>
> No matter how strong the encryption, you must remember your master passphrase. It lives only in your head; no one — including us — can recover it for you.

> 萝笺不收集你的笔记内容。选择自建同步，数据主权完全在你。
>
> CarroNote does not collect your note contents. Choose self-hosted sync and full data sovereignty is yours.

---

## 品牌故事 / Brand story

> 明代天启年间（1626），有一部名为《萝轩变古笺谱》的孤本——中国木版水印史上最早的笺谱，如今是国家一级文物。「萝」与「笺」，在中国文化里天然就是"书、纸、珍贵内容"的代名词。
> 我们用「萝笺」命名这款加密笔记：让每一页私密，都像古人珍视的信笺一样，只属于写下它的人。
>
> In the Ming dynasty (1626), a single-copy book titled *Luoxuan Biangu Jianpu* — the earliest letter-paper album in the history of Chinese woodblock printing — was made. It is now a Grade-One national cultural relic. In Chinese culture, "萝" (vine) and "笺" (letter paper) have always meant *book, paper, and cherished words*.
> We named this encrypted note app "萝笺 / CarroNote": so that every private page, like the letter paper treasured by the ancients, belongs only to the one who wrote it.

---

## 开始使用 / Get started

> 1. 下载萝笺（应用商店搜索「萝笺 CarroNote」）。
> 2. 设置主密码——请务必牢记，它无法被找回。
> 3. （可选）在设置中配置同步后端，开启多端加密同步。
> 4. 安心写下每一笺。
>
> 1. Download CarroNote (search "萝笺 CarroNote" in your app store).
> 2. Set a master passphrase — remember it; it cannot be recovered.
> 3. (Optional) Configure a sync backend in Settings to enable encrypted multi-device sync.
> 4. Write safely on every page.

---

## 商标与版权 / Trademark & License

> 品牌名称「萝笺 / CarroNote」及 Slogan 文本归本项目所有，对外发布文案以本文档双语版本为准。
> The brand name "萝笺 / CarroNote" and slogan texts are owned by this project; external copy follows the bilingual text in this document.
>
> 软件基于上游 keshav-space/safenotes fork 改造，遵循 GPL-3.0-or-later。
> Software is a fork of keshav-space/safenotes, licensed under GPL-3.0-or-later.

---

*对外发布时，请优先使用本文档中的双语文案，保持名称、口号、术语在全渠道一致。*
*For external publishing, use the bilingual copy in this document and keep the name, slogans, and terms consistent across all channels.*
