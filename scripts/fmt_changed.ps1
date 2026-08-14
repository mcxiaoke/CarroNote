#!/usr/bin/env pwsh
# SafeNotes: 仅对 git 中已修改(M) 与 新增(??) 的 .dart 文件运行 dart format + import_sorter
#
# 用法:
#   pwsh scripts/fmt_changed.ps1            # 实际格式化选中的文件
#   pwsh scripts/fmt_changed.ps1 -DryRun    # 仅列出待处理文件，不执行任何格式化
#   pwsh scripts/fmt_changed.ps1 -Path xxx  # 指定 git 仓库目录(默认: 脚本所在仓库根)
#
# 退出码: 0=成功; 1=失败

param(
  [switch]$DryRun,
  [string]$Path
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.Encoding]::UTF8

if ($Path) {
  $root = (Resolve-Path $Path).Path
} else {
  $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
Push-Location $root

# ───────────────── 1. 收集 git 中修改/新增的 .dart 文件 ─────────────────
# git status --porcelain -z: NUL 分隔，路径不带引号，兼容含空格/中文路径
$raw = (& git status --porcelain -z) -join ''
$records = $raw -split "`0"

$files = [System.Collections.Generic.List[string]]::new()
$i = 0
while ($i -lt $records.Count) {
  $rec = $records[$i]
  $i++
  if ($rec.Length -lt 2) { continue }

  $x = $rec.Substring(0, 1)   # index 状态
  $y = $rec.Substring(1, 1)   # worktree 状态
  $path = $rec.Substring(2)
  # rename/copy: 下一条记录是旧路径，跳过
  if ($x -eq 'R' -or $x -eq 'C') { $i++ }

  if (-not $path.EndsWith('.dart')) { continue }
  if ($x -eq 'D' -or $y -eq 'D') { continue }   # 删除的文件不格式化
  if ($x -eq 'U' -or $y -eq 'U') { continue }   # 冲突状态跳过

  # 修改(M) / 暂存新增(A) / 重命名(R) / 复制(C) / 未跟踪新增(?) / 工作区修改(M)
  $isChanged = ($x -in @('M','A','R','C','?')) -or ($y -eq 'M')
  if (-not $isChanged) { continue }

  $files.Add($path)
}

if ($files.Count -eq 0) {
  Write-Host '[fmt] git 中没有需要格式化的 .dart 文件'
  Pop-Location
  exit 0
}

$files = @($files | Sort-Object)
Write-Host "待处理 $($files.Count) 个 .dart 文件:"
$files | ForEach-Object { Write-Host "  $_" }

if ($DryRun) {
  Write-Host '[fmt] DryRun 模式，未做任何修改'
  Pop-Location
  exit 0
}

# ───────────────── 2. dart format ─────────────────
Write-Host "`n[dart format]"
& dart format @files
if ($LASTEXITCODE -ne 0) { Pop-Location; exit 1 }

# ───────────────── 3. import_sorter ─────────────────
Write-Host "`n[import_sorter]"
& dart run import_sorter:main @files
if ($LASTEXITCODE -ne 0) { Pop-Location; exit 1 }

Write-Host "`n完成: $($files.Count) 个文件已格式化"
Pop-Location
exit 0
