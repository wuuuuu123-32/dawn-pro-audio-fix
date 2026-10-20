<#
  Dawn Pro 音频守护（B 方案）

  背景：这个 USB DAC 有两类故障，表现都是「设备在线、端点 ACTIVE、服务在跑，
        但播放器建流失败（进度条走却没声音 / 播放器卡住）」，手动重启 Audiosrv 能好：
    1) 设备经历大量 USB 瞬断后，音频引擎状态被拖坏
    2) 零掉线、长时间运行后引擎自己卡死

  做法（按会审意见设计）：
    - 主信号：PlaybackManager 里「短命音频流」模式（流启动后 5 秒内就停止，
              120 秒内出现 5 次）——这是播放器建流失败的近似反映
              ⚠️ 会审指出它挡不住「快速连续切歌 / 拖进度条 / 通知音」的误触发，
              所以阈值放得很宽；误触发的代价只是多重启一次音频服务
    - 补偿信号：Dawn Pro 端点从非 ACTIVE 恢复为 ACTIVE（Event 65 的等价判断）
    - 复位分级：端点非 ACTIVE 时先只重启这个 USB 设备（pnputil /restart-device），
              3 秒后还不行才重启 Audiosrv；端点本来就 ACTIVE（引擎层卡死）时
              直接跳到重启 Audiosrv，不做无用的第一级
    - 限流：两次复位间隔不小于 CooldownSeconds；一小时内最多 MaxPerHour 次
    - 状态判断用位掩码（ACTIVE=0x1），不精确匹配 4/1

  用法：
    -DryRun    只记录不动作（用来观察是否会误触发）
    -Simulate  立刻走一次复位流程然后退出
    正常运行需要管理员权限，建议用 install-guard.cmd 注册成开机计划任务
#>
param(
    [switch]$DryRun,
    [switch]$Simulate,
    [int]$PollSeconds = 5,
    [int]$CooldownSeconds = 60,
    [int]$MaxPerHour = 3,
    [int]$RunSeconds = 0,
    [int]$StreamThreshold = 5,
    [int]$StreamWindowSeconds = 120
)

$ErrorActionPreference = 'Continue'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$logPath = Join-Path $scriptDir 'audio-guard.log'

function Write-Log {
    param([string]$msg, [string]$level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    Write-Host $line
}

$TargetVid = 'VID_2FC6&PID_F06A'

# 读端点注册表，把 MMDevices 端点映射回 USB PnP InstanceId
# 名称与关联在 Properties 子键，DeviceState 在主键
function Get-DawnEndpoint {
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
    $out = @()
    foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $main = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        $p = Get-ItemProperty -LiteralPath "$($k.PSPath)\Properties" -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $name = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
        $assoc = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},2'
        if (($name -match 'Dawn') -or ($assoc -match $TargetVid)) {
            $iid = $null
            if ($assoc -match '^\{[^}]+\}\.(.+)$') { $iid = $Matches[1] }
            elseif ($assoc -match '(USB\\VID_2FC6&PID_F06A[^;]*)') { $iid = $Matches[1] }
            $st = 0
            if ($main -and $null -ne $main.DeviceState) { $st = [int]$main.DeviceState }
            $out += [pscustomobject]@{
                EndpointId = $k.PSChildName
                Name       = $name
                InstanceId = $iid
                State      = $st
                Active     = (($st -band 1) -ne 0)
            }
        }
    }
    return $out
}

function Get-PrimaryEndpoint {
    $eps = @(Get-DawnEndpoint)
    if ($eps.Count -eq 0) { return $null }
    $a = @($eps | Where-Object { $_.Active })
    if ($a.Count -gt 0) { return $a[0] }
    return $eps[0]
}

$script:LastReset = $null
$script:ResetTimes = New-Object System.Collections.ArrayList

function Test-CanReset {
    $now = Get-Date
    if ($script:LastReset -and (($now - $script:LastReset).TotalSeconds -lt $CooldownSeconds)) {
        Write-Log ("冷却中：距上次复位 {0:N0} 秒（阈值 {1} 秒），跳过" -f ($now - $script:LastReset).TotalSeconds, $CooldownSeconds) 'WARN'
        return $false
    }
    $recent = @($script:ResetTimes | Where-Object { ($now - $_).TotalHours -lt 1 })
    $script:ResetTimes = New-Object System.Collections.ArrayList
    foreach ($t in $recent) { [void]$script:ResetTimes.Add($t) }
    if ($recent.Count -ge $MaxPerHour) {
        Write-Log ("一小时内已复位 {0} 次，达到上限 {1}，跳过" -f $recent.Count, $MaxPerHour) 'WARN'
        return $false
    }
    return $true
}

function Invoke-Reset {
    param([string]$Reason)

    Write-Log "=== 触发复位：$Reason ==="
    if ($DryRun) {
        Write-Log 'DryRun：只记录，不执行任何复位动作' 'WARN'
        return
    }
    if (-not (Test-CanReset)) { return }

    $t = Get-Date
    $script:LastReset = $t
    [void]$script:ResetTimes.Add($t)

    $ep = Get-PrimaryEndpoint
    if ($ep -and $ep.Active) {
        Write-Log '端点已处于 ACTIVE：判定为引擎层卡死，设备级重启无效，直接跳到第 2 级' 'WARN'
    } elseif ($ep -and $ep.InstanceId) {
        Write-Log ("第 1 级：只重启该设备 -> pnputil /restart-device {0}" -f $ep.InstanceId)
        $r = & pnputil.exe /restart-device "$($ep.InstanceId)" 2>&1
        Write-Log ('pnputil 输出: ' + ($r -join ' | '))
        Start-Sleep -Seconds 3
        $after = Get-PrimaryEndpoint
        if ($after -and $after.Active) {
            Write-Log ("第 1 级完成：端点已回到 ACTIVE（State={0}）" -f $after.State)
            return
        }
        Write-Log '第 1 级后端点仍未 ACTIVE，升级到第 2 级' 'WARN'
    } else {
        Write-Log '取不到设备实例，跳过第 1 级，直接做第 2 级' 'WARN'
    }

    Write-Log '第 2 级：Restart-Service Audiosrv -Force'
    try {
        Restart-Service Audiosrv -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
        $after2 = Get-PrimaryEndpoint
        $svc = Get-Service Audiosrv -ErrorAction SilentlyContinue
        $act = if ($after2) { $after2.Active } else { $false }
        Write-Log ("第 2 级完成：Audiosrv={0}，端点 Active={1}" -f $svc.Status, $act)
    } catch {
        Write-Log ('第 2 级失败：' + $_.Exception.Message) 'ERROR'
    }
}

# ---------------- 启动 ----------------
Write-Log '=== Dawn Pro 音频守护启动 ==='
Write-Log ("参数：DryRun={0} Simulate={1} Poll={2}s Cooldown={3}s MaxPerHour={4}" -f $DryRun, $Simulate, $PollSeconds, $CooldownSeconds, $MaxPerHour)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Write-Log '需要管理员权限（要执行设备重启与服务重启）。' 'ERROR'
    exit 1
}

if ($Simulate) {
    Invoke-Reset -Reason '手动模拟触发'
    exit 0
}

$ep0 = Get-PrimaryEndpoint
if ($ep0) {
    Write-Log ("启动补偿扫描：端点={0} State={1} Active={2}" -f $ep0.EndpointId, $ep0.State, $ep0.Active)
} else {
    Write-Log '启动补偿扫描：未找到 Dawn Pro 端点（可能没插好）' 'WARN'
}
$wasActive = [bool]($ep0 -and $ep0.Active)

$lastCheck = Get-Date
$pendingStart = $null
$shortStreams = New-Object System.Collections.ArrayList
$lastHeartbeat = Get-Date
$runStart = Get-Date

while ($true) {
    Start-Sleep -Seconds $PollSeconds
    $now = Get-Date

    if ($RunSeconds -gt 0 -and (($now - $runStart).TotalSeconds -ge $RunSeconds)) {
        Write-Log ("达到测试时长 {0} 秒，退出守护" -f $RunSeconds)
        break
    }

    # --- 补偿信号：端点从非 ACTIVE 恢复为 ACTIVE ---
    $ep = Get-PrimaryEndpoint
    if ($ep) {
        if ($ep.Active -and -not $wasActive) {
            Write-Log '检测到端点从非 ACTIVE 恢复为 ACTIVE（等价于 Event 65 的 state=4 -> 1）'
            Start-Sleep -Seconds 5
            Invoke-Reset -Reason '端点掉线后恢复'
        }
        $wasActive = [bool]$ep.Active
    }

    # --- 主信号：短命音频流（建流失败模式）---
    $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Audio/PlaybackManager'; StartTime = $lastCheck } -ErrorAction SilentlyContinue)
    $lastCheck = $now
    foreach ($e in @($evs | Sort-Object TimeCreated)) {
        if ($e.Id -eq 24) {
            $pendingStart = $e.TimeCreated
        } elseif ($e.Id -eq 25 -and $pendingStart) {
            $alive = ($e.TimeCreated - $pendingStart).TotalSeconds
            $pendingStart = $null
            if ($alive -lt 5) { [void]$shortStreams.Add($e.TimeCreated) }
        }
    }

    $cut = $now.AddSeconds(-$StreamWindowSeconds)
    $keep = @($shortStreams | Where-Object { $_ -gt $cut })
    $shortStreams = New-Object System.Collections.ArrayList
    foreach ($t in $keep) { [void]$shortStreams.Add($t) }

    if ($keep.Count -ge $StreamThreshold) {
        $shortStreams = New-Object System.Collections.ArrayList
        Invoke-Reset -Reason ("{0} 秒内出现 {1} 次短命音频流（疑似播放器建流失败）" -f $StreamWindowSeconds, $keep.Count)
    }

    # --- 心跳（每 30 分钟一行，便于确认守护还活着）---
    if (($now - $lastHeartbeat).TotalMinutes -ge 30) {
        $lastHeartbeat = $now
        $cur = Get-PrimaryEndpoint
        $svc = Get-Service Audiosrv -ErrorAction SilentlyContinue
        $state = if ($cur) { $cur.State } else { 'N/A' }
        Write-Log ("心跳：端点 State={0}，Audiosrv={1}" -f $state, $svc.Status)
    }
}
