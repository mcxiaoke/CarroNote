#!/usr/bin/env pwsh
# SafeNotes CLI 端到端测试脚本（真实流程，无 Flutter / 无 UI）
#
# 参照 packages/core/test/sync/longrun_persistent_store_test.dart 的长期存续思路，
# 用 CLI 驱动核心真实流程：
#   S1 keyring init → 笔记增删改查 → 改密码（keyVersion+1）→ 密码错误路径
#   S2 双 data-dir + LocalFS：A 建笔记同步 → B join（场景 d 迁移）收敛
#   S3 双向编辑/新增 → 再次同步收敛（LWW）
#   S4 删除传播（A 软删 → B 收到墓碑）
#   S5 export → 清空 → import 幂等；新设备 C import 完整还原
#   S6 db wipe 逃生通道；journal / log 可读性
#
# 用法：pwsh scripts/cli-e2e-test.ps1
# 退出码：0=全部通过；1=存在失败

$ErrorActionPreference = 'Stop'

# 统一 UTF-8：CLI 输出为 UTF-8，PowerShell 捕获/显示必须同步，否则中文断言失效
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$work = Join-Path $root 'temp\cli-e2e'

# ───────────────────────────── 工具函数 ─────────────────────────────
$script:Passed = 0
$script:Failed = 0
$script:FailMsgs = [System.Collections.Generic.List[string]]::new()

function Assert {
  param([bool]$Cond, [string]$Msg)
  if ($Cond) {
    $script:Passed++
    Write-Host "  [ok] $Msg" -ForegroundColor Green
  } else {
    $script:Failed++
    $script:FailMsgs.Add($Msg)
    Write-Host "  [FAIL] $Msg" -ForegroundColor Red
  }
}

# 运行 CLI：优先使用 AOT 编译产物 build/cli/bundle/bin/safenotes_cli.exe（无 build-hooks 噪声、启动快），
# 不存在时回退 dart run（带 build-hooks 清洗）。
$script:CLI_BIN = Join-Path $root 'build\cli\bundle\bin\safenotes_cli.exe'
$script:UseBinary = Test-Path $script:CLI_BIN
if ($script:UseBinary) {
  Write-Host "[setup] 使用二进制: $script:CLI_BIN" -ForegroundColor DarkCyan
} else {
  Write-Host '[setup] 未找到编译产物，回退 dart run' -ForegroundColor DarkCyan
}

function Invoke-Cli {
  param(
    [string]$DataDir,
    [string]$Password,
    [string[]]$CmdArgs
  )
  if ($script:UseBinary) {
    # 二进制的 --data-dir 相对路径基于当前工作目录解析，脚本已 Push-Location 到 repo 根
    $raw = @(& $script:CLI_BIN '--data-dir' $DataDir '--password' $Password @CmdArgs 2>$null)
  } else {
    $a = @('run', 'bin/safenotes_cli.dart', '--data-dir', $DataDir, '--password', $Password) + $CmdArgs
    # CLI 业务输出走 stdout；dart 的 "Running build hooks" 进度文本用 \r 与真实输出粘连在同一行，
    # 先整体剔除该噪声再剥离行首残留的 \r / 空格，避免误删真实内容。
    $raw = @(& dart @a 2>$null) | ForEach-Object {
      ($_ -replace 'Running build hooks\.*', '') -replace '^[\r ]+', ''
    }
  }
  $script:Code = $LASTEXITCODE
  $script:Out = @($raw)
}

function Out-Text { return ($script:Out -join "`n") }

function Has-Line {
  param([string]$Pattern)
  return ($script:Out | Where-Object { $_ -match $Pattern }).Count -gt 0
}

# ───────────────────────────── 准备 ─────────────────────────────
Push-Location $root
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Path $work -Force | Out-Null

$dirA = Join-Path $work 'devA'
$dirB = Join-Path $work 'devB'
$dirC = Join-Path $work 'devC'
$vault = Join-Path $work 'vault'
$backup = Join-Path $work 'backup.json'
$pw1 = 'test-pass-1'
$pw2 = 'test-pass-2'

Write-Host "`n=== S1: keyring 初始化 + 笔记 CRUD + 改密码 ===" -ForegroundColor Cyan

Invoke-Cli $dirA $pw1 @('keyring', 'init')
Assert ($script:Code -eq 0) 'A keyring init 成功'
Assert (Has-Line 'keyring 已初始化.*keyVersion=1 epoch=1') 'A keyVersion=1 epoch=1'

Invoke-Cli $dirA $pw1 @('note', 'add', '--title', '标题一', '--body', '正文一')
Assert ($script:Code -eq 0) 'A 新建笔记 1'

Invoke-Cli $dirA $pw1 @('note', 'add', '--title', '标题二', '--body', '正文二')
$note2Uuid = ($script:Out | Select-String -Pattern 'uuid=([0-9a-f-]{36})').Matches[0].Groups[1].Value

Invoke-Cli $dirA $pw1 @('note', 'list')
Assert ((Out-Text).Split("`n") -match '^\S+\t' | Measure-Object).Count -eq 2 'A note list 2 条'

Invoke-Cli $dirA $pw1 @('note', 'get', $note2Uuid)
Assert (Has-Line '正文二') 'A note get 正文解密正确'
Assert (Has-Line 'synced=否') 'A 新建笔记未同步'

Invoke-Cli $dirA $pw1 @('note', 'update', $note2Uuid, '--title', '标题二改')
Assert (Has-Line "已更新笔记.*uuid=$note2Uuid") 'A note update 成功'

Invoke-Cli $dirA $pw1 @('note', 'delete', $note2Uuid)
Assert (Has-Line '已软删除') 'A note delete 软删除'

Invoke-Cli $dirA $pw1 @('note', 'list', '--deleted')
Assert (Has-Line '已删除') 'A 回收站可见墓碑'

Invoke-Cli $dirA $pw1 @('note', 'restore', $note2Uuid)
Assert (Has-Line '已恢复') 'A note restore 恢复'

Invoke-Cli $dirA $pw1 @('keyring', 'change-password', '--old', $pw1, '--new', $pw2)
Assert (Has-Line '改密码完成.*keyVersion=2 epoch=1') 'A 改密码 keyVersion+1 epoch 不变'

Invoke-Cli $dirA $pw1 @('keyring', 'verify')
Assert ($script:Code -eq 1) '旧密码失效（exit 1）'

Invoke-Cli $dirA $pw2 @('keyring', 'verify')
Assert ($script:Code -eq 0) '新密码有效'

Invoke-Cli $dirA $pw2 @('note', 'get', $note2Uuid)
Assert (Has-Line '标题二改') '改密码后仍可解密（dataKey 未变）'

Invoke-Cli $dirA 'WRONG-PASS' @('note', 'list')
Assert ($script:Code -eq 1) '错误密码访问数据 exit 1'

Write-Host "`n=== S2: 双设备 LocalFS 同步（B join，场景 d 迁移） ===" -ForegroundColor Cyan

Invoke-Cli $dirA $pw2 @('sync', 'setup', '--type', 'localfs', '--path', $vault)
Assert ($script:Code -eq 0) 'A 配置 localfs 后端'

Invoke-Cli $dirA $pw2 @('sync', 'run')
Assert ($script:Code -eq 0) 'A 首次同步成功'
Assert (Has-Line '上传=2') 'A 上传 2 条到 vault'

Invoke-Cli $dirB $pw2 @('keyring', 'init')
Assert ($script:Code -eq 0) 'B keyring init（独立 vault）'

Invoke-Cli $dirB $pw2 @('sync', 'setup', '--type', 'localfs', '--path', $vault)
Invoke-Cli $dirB $pw2 @('sync', 'run')
Assert ($script:Code -eq 0) 'B 首次同步成功'
Assert (Has-Line '下载=2') 'B 从 vault 下载 2 条（含场景 d 迁移）'

Invoke-Cli $dirB $pw2 @('note', 'list')
Assert ((Out-Text).Split("`n") -match '^\S+\t' | Measure-Object).Count -eq 2 'B 收敛后 2 条'

Write-Host "`n=== S3: 双向新增再同步（LWW 收敛） ===" -ForegroundColor Cyan

Invoke-Cli $dirB $pw2 @('note', 'add', '--title', 'B设备新增', '--body', '来自B')
$noteB = ($script:Out | Select-String -Pattern 'uuid=([0-9a-f-]{36})').Matches[0].Groups[1].Value

Invoke-Cli $dirB $pw2 @('sync', 'run')
Assert (Has-Line '上传=1') 'B 上传新增'

Invoke-Cli $dirA $pw2 @('sync', 'run')
Assert (Has-Line '下载=1') 'A 下载 B 的新增'

Invoke-Cli $dirA $pw2 @('note', 'list')
Assert (Has-Line $noteB) 'A 可见 B 的笔记（uuid 一致）'

Invoke-Cli $dirA $pw2 @('note', 'get', $noteB)
Assert (Has-Line '来自B') 'A 侧内容解密一致'

Write-Host "`n=== S4: 删除传播（墓碑同步） ===" -ForegroundColor Cyan

Invoke-Cli $dirA $pw2 @('note', 'delete', $noteB)
Invoke-Cli $dirA $pw2 @('sync', 'run')
Assert (Has-Line '删除=') 'A 上传墓碑'

Invoke-Cli $dirB $pw2 @('sync', 'run')
Invoke-Cli $dirB $pw2 @('note', 'list', '--deleted')
Assert (Has-Line '\[已删除\] B设备新增') 'B 收到墓碑'

Write-Host "`n=== S5: export / import 往返 ===" -ForegroundColor Cyan

Invoke-Cli $dirB $pw2 @('export', '--out', $backup)
Assert (Has-Line '已导出 2 条') 'B 导出 2 条'

Invoke-Cli $dirB $pw2 @('note', 'purge-deleted', '--yes')
Assert (Has-Line '已清空回收站') 'B 清空回收站'

Invoke-Cli $dirB $pw2 @('note', 'list')
Assert ((Out-Text).Split("`n") -match '^\S+\t' | Measure-Object).Count -eq 2 'B 剩 2 条未删'

Invoke-Cli $dirB $pw2 @('import', '--in', $backup)
Assert (Has-Line '跳过已存在 2 条') 'B 重导入幂等（跳过 2）'

Invoke-Cli $dirC $pw2 @('keyring', 'init')
Invoke-Cli $dirC $pw2 @('import', '--in', $backup)
Assert (Has-Line '已导入 2 条') 'C 新设备导入完整还原'
Invoke-Cli $dirC $pw2 @('note', 'list')
Assert ((Out-Text).Split("`n") -match '^\S+\t' | Measure-Object).Count -eq 2 'C 导入后 2 条'

Write-Host "`n=== S6: db wipe / journal / log ===" -ForegroundColor Cyan

Invoke-Cli $dirC $pw2 @('db', 'wipe')
Assert ($script:Code -eq 1) 'db wipe 未带 --yes 拒绝（exit 1）'

Invoke-Cli $dirC $pw2 @('db', 'wipe', '--yes')
Assert (Has-Line '已删除数据库') 'C db wipe 成功'

Invoke-Cli $dirC $pw2 @('keyring', 'status')
Assert (Has-Line '已初始化: false') 'C keyring 归未初始化'

Invoke-Cli $dirA $pw2 @('journal', 'cat', '--tail', '3')
Assert ($script:Code -eq 0) 'journal cat 可读'
Assert (Has-Line 'note\.') 'journal 含 note 事件'

Invoke-Cli $dirA $pw2 @('log', 'cat', '--tail', '2')
Assert ($script:Code -eq 0) 'log cat 可读'

Invoke-Cli $dirA $pw2 @('db', 'info')
Assert ($script:Code -eq 0) 'db info 退出码 0'
Assert (Has-Line '笔记总数.*: 3') 'db info 统计含回收站（3 条）'
Assert (Has-Line '回收站.*: 1') 'db info 墓碑计数正确（1 条）'

# ───────────────────────────── 汇总 ─────────────────────────────
Pop-Location
Write-Host "`n======================================================="
Write-Host "结果: 通过 $($script:Passed) 项, 失败 $($script:Failed) 项"
if ($script:Failed -gt 0) {
  Write-Host '失败明细:' -ForegroundColor Red
  foreach ($m in $script:FailMsgs) { Write-Host "  - $m" -ForegroundColor Red }
  exit 1
} else {
  Write-Host '全部通过' -ForegroundColor Green
  exit 0
}
