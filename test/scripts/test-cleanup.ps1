# SafeServer 测试环境清理脚本
#
# 清理内容：
#   1. 残留 server 进程（safeserver.exe / safenotes-server.exe / node server.js 测试目录）
#   2. 占用测试端口的进程
#   3. 临时数据目录（$env:TEMP\safenotes-test, $env:TEMP\sn-test-*）
#   4. 项目 temp/ 下的 server 日志文件（safeserver-*.log, sn-server-*.log）
#
# 用法：
#   pwsh -NoProfile -ExecutionPolicy Bypass -File test\scripts\test-cleanup.ps1
#   pwsh -NoProfile -ExecutionPolicy Bypass -File test\scripts\test-cleanup.ps1 -Ports 8090,8091
#   pwsh -NoProfile -ExecutionPolicy Bypass -File test\scripts\test-cleanup.ps1 -SkipFileCleanup
#
# 设计原则：
#   - 幂等：可重复运行，无副作用
#   - 安全：只杀命令行匹配测试特征的进程，不误杀其他 server
#   - 可观测：每一步都输出日志，便于排查
#   - 跨场景：覆盖当前和历史的测试二进制命名

[CmdletBinding()]
param(
    # 需要清理的端口列表（默认 8090，与测试用例保持一致）
    [int[]]$Ports = @(8090),
    # 跳过进程清理
    [switch]$SkipProcessKill,
    # 跳过文件清理
    [switch]$SkipFileCleanup,
    # 详细输出（显示进程命令行等详细信息）
    [switch]$Detailed
)

$ErrorActionPreference = 'SilentlyContinue'

function Write-Step {
    param([string]$msg)
    Write-Host "[cleanup] $msg" -ForegroundColor Cyan
}

function Write-Detail {
    param([string]$msg)
    if ($Detailed) {
        Write-Host "  $msg" -ForegroundColor DarkGray
    }
}

# ──────────────────────────────────────────────
# 1. 杀残留进程
# ──────────────────────────────────────────────

if (-not $SkipProcessKill) {
    Write-Step 'Step 1: Killing residual server processes...'

    # 匹配模式覆盖历史所有命名：
    #   - safeserver.exe           → 当前测试构建的 Go 二进制名
    #   - safenotes-server.exe     → 旧版 `go run` 自动生成的二进制名
    #   - safenotes-test           → 当前测试数据目录特征（kTestRoot）
    #   - sn-test-                 → 旧测试数据目录特征
    #   - sn-node-debug            → 手动调试 Node server 的日志特征
    #   - server\.js.*safenotes    → Node server 跑当前测试目录
    #   - server\.js.*sn-test      → Node server 跑旧测试目录
    $patterns = @(
        'safeserver\.exe',
        'safenotes-server\.exe',
        'safenotes-test',
        'sn-test-',
        'sn-node-debug',
        'server\.js.*safenotes',
        'server\.js.*sn-test'
    )

    $killed = 0
    $seenPids = @{}
    foreach ($p in $patterns) {
        $procs = Get-CimInstance Win32_Process |
            Where-Object { $_.CommandLine -match $p }
        foreach ($proc in $procs) {
            $procPid = $proc.ProcessId
            # 跳过自己（pwsh 进程）和已杀过的 PID
            if ($procPid -eq $PID -or $seenPids.ContainsKey($procPid)) {
                continue
            }
            $seenPids[$procPid] = $true
            Write-Step "  killing PID=$procPid ($($proc.Name))"
            Write-Detail "    cmd: $($proc.CommandLine)"
            Stop-Process -Id $procPid -Force -ErrorAction SilentlyContinue
            $killed++
        }
    }
    Write-Step "  killed $killed residual processes"

    # 2. 杀占用测试端口的进程（端口级兜底清理）
    Write-Step "Step 2: Killing processes on ports: $($Ports -join ', ')"
    $portKilled = 0
    foreach ($port in $Ports) {
        $conns = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
        foreach ($conn in $conns) {
            $ownerPid = $conn.OwningProcess
            if (-not $ownerPid -or $ownerPid -eq 0) { continue }
            if ($seenPids.ContainsKey($ownerPid)) { continue }
            $seenPids[$ownerPid] = $true
            $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
            $procName = if ($proc) { $proc.Name } else { '<unknown>' }
            Write-Step "  killing PID=$ownerPid ($procName) on port $port ($($conn.State))"
            Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
            $portKilled++
        }
    }
    Write-Step "  killed $portKilled port-owning processes"

    # 等待进程真正退出（让端口释放）
    if ($killed -gt 0 -or $portKilled -gt 0) {
        Write-Step '  waiting for processes to exit...'
        Start-Sleep -Milliseconds 1000
    }
}

# ──────────────────────────────────────────────
# 3. 清理临时数据目录
# ──────────────────────────────────────────────

if (-not $SkipFileCleanup) {
    Write-Step 'Step 3: Cleaning temp data directories...'

    # 临时数据目录模式（在系统 TEMP 下）
    $tempPatterns = @(
        "$env:TEMP\safenotes-test",
        "$env:TEMP\sn-test-*"
    )

    $dirCount = 0
    foreach ($pattern in $tempPatterns) {
        Get-Item $pattern | ForEach-Object {
            Write-Step "  removing $($_.FullName)"
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $_.FullName)) {
                $dirCount++
            } else {
                Write-Step "  WARNING: could not remove $($_.FullName) (file in use?)"
            }
        }
    }
    Write-Step "  removed $dirCount temp directories"

    # 4. 清理项目 temp/ 下的 server 日志文件
    Write-Step 'Step 4: Cleaning server log files in project temp/...'
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $logPatterns = @(
        "$repoRoot\temp\safeserver-*.log",
        "$repoRoot\temp\sn-server-*.log"
    )

    $logCount = 0
    foreach ($pattern in $logPatterns) {
        Get-Item $pattern | ForEach-Object {
            Write-Step "  removing $($_.FullName)"
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $_.FullName)) {
                $logCount++
            }
        }
    }
    Write-Step "  removed $logCount log files"
}

Write-Step 'Cleanup complete.'
