<#
  Dawn Pro 音频守护（B 方案）

  背景：这个 USB DAC 有两类故障，表现都是「设备在线、端点 ACTIVE、服务在跑，
        但播放器建流失败（进度条走却没声音 / 播放器卡住）」，手动重启 Audiosrv 能好：
    1) 设备经历大量 USB 瞬断后，音频引擎状态被拖坏
    2) 零掉线、长时间运行后引擎自己卡死

  做法（按第二轮会审意见设计，2026-10-20 改）：
    - 主判据：静置刷新（按墙钟时间，不等播放发生）
              会审指出 20:43 那次故障「零流事件」，任何只盯「建流失败」的判据
              都看不到它，必须改成按时间判断。
              判据用 PlaybackManager 的流状态，不用 CPU：
              audiodg 空闲时每 5 秒也在吃约 0.02 到 0.13 秒 CPU，和播放时分不开（已实测）。
              「最后一条流事件是 25/22，或没有」= 无流，从那一刻起算静置；
              连续 IdleMinutes 分钟无流 → 预防性重启 Audiosrv（此时没人在听）；
              只要距上次刷新满 RefreshIntervalMinutes 分钟就会再刷一次，
              所以长时间静置（比如一整夜）期间引擎也是被定期刷新的，不会「刷一次就锁死」。
              这条能覆盖「静置后首播失败」，因为它根本不等播放发生。

              ⚠️ 已知局限（2026-10-20 第二轮会审）：
                 PlaybackManager 事件里没有任何会话/流标识字段（实测 EventData.Data
                 全空），只能维护一个全局布尔值。多应用同时播放时，A 停了可能把
                 状态置为「无流」而 B 还在播，若恰好静置满 30 分钟会误重启一次
                 （打断约 5 秒，播放器多半会自动续播）。权衡：误重启的代价远小于
                 故障时完全没声音。缓解：触发前复查最近 60 秒有无新事件，有则跳过。
    - 辅判据：PlaybackManager 里「短命音频流」模式（流启动后 5 秒内就停止，
              120 秒内出现 5 次）——播放器建流失败且留下了事件时用它。
              ⚠️ 挡不住「快速连续切歌 / 拖进度条 / 通知音」的误触发，所以阈值很宽。
    - 补偿信号：Dawn Pro 端点从非 ACTIVE 恢复为 ACTIVE（Event 65 的等价判断）
    - 复位分级：端点非 ACTIVE 时先只重启这个 USB 设备（pnputil /restart-device），
              3 秒后还不行才重启 Audiosrv；端点本来就 ACTIVE（引擎层卡死）时
              直接跳到重启 Audiosrv，不做无用的第一级
    - 限流：两次复位间隔不小于 CooldownSeconds；一小时内最多 MaxPerHour 次（2）
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
    [int]$MaxPerHour = 2,
    [int]$RunSeconds = 0,
    [int]$StreamThreshold = 5,
    [int]$StreamWindowSeconds = 120,
    [int]$IdleMinutes = 30,
    [int]$RefreshIntervalMinutes = 60,   # 两次「静置刷新」之间的最小间隔（不是每轮只刷一次）
    [double]$StartupGraceMinutes = 5   # 守护自己至少醒这么久，才允许做第一次静置刷新
)

$ErrorActionPreference = 'Continue'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$logPath = Join-Path $scriptDir 'audio-guard.log'

function Write-Log {
    param([string]$msg, [string]$level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    # Session 0 里没有控制台，Write-Host 会抛「句柄无效」且这是终止性错误，必须吃掉
    try { Write-Host $line -ErrorAction SilentlyContinue } catch { }
}

# 全局兜底：任何未处理异常都落盘后继续，绝不让守护静默死掉
trap {
    $m = "[{0}] [FATAL] 未处理异常：{1}`r`n{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message, $_.ScriptStackTrace
    try { Add-Content -LiteralPath $logPath -Value $m -Encoding UTF8 } catch { }
    try { Add-Content -LiteralPath (Join-Path $scriptDir '_crash.txt') -Value $m -Encoding UTF8 } catch { }
    continue
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
        return $true
    }
    if (-not (Test-CanReset)) { return $false }

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
            return $true
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
    return $true
}

# ---------------- 启动 ----------------
Write-Log '=== Dawn Pro 音频守护启动 ==='
Write-Log ("参数：DryRun={0} Simulate={1} Poll={2}s Cooldown={3}s MaxPerHour={4} Idle={5}min Refresh={6}min" -f $DryRun, $Simulate, $PollSeconds, $CooldownSeconds, $MaxPerHour, $IdleMinutes, $RefreshIntervalMinutes)

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
$streaming = $false               # 是否有活跃音频流（最后一条流事件是 24 且还没收到 25）
$lastStreamStop = Get-Date        # 最后一次「流结束 / 暂停」的时刻，静置计时起点
$lastRefreshTime = [datetime]::MinValue  # 上次刷新引擎的时刻；静置期间按 RefreshIntervalMinutes 反复刷，不是只刷一次
# 引擎刚重建过（audiodg 启动不到 10 分钟）就不必再刷一次，否则守护每次重启都会立刻多刷一遍
$ag = Get-Process audiodg -ErrorAction SilentlyContinue
if ($ag -and ((Get-Date) - $ag.StartTime).TotalMinutes -lt 10) {
    # 引擎刚重建过：只是「刚刷过」这一点要记住，不是把整轮静置都豁免掉
    $lastRefreshTime = $ag.StartTime
    Write-Log ('启动检测：audiodg 于 {0:HH:mm:ss} 启动，不足 10 分钟，视为引擎刚刷新过（{1} 分钟后才允许再刷）' -f $ag.StartTime, $RefreshIntervalMinutes)
}
else {
    Write-Log '启动检测：audiodg 不是刚重建，lastRefreshTime 保持初始值（首轮满足静置条件即可刷新）'
}

# 启动时先扫一遍最近的流事件，建立「当前是否在播放」的初始状态
# （只读增量的话，守护重启后 streaming 会一直是 false，可能在你正听歌时误判）
$initEvs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Audio/PlaybackManager'; StartTime = (Get-Date).AddHours(-24) } -ErrorAction SilentlyContinue)
$initLast = $null
foreach ($e in @($initEvs | Sort-Object TimeCreated)) {
    if ($e.Id -eq 24 -or $e.Id -eq 25 -or $e.Id -eq 22) { $initLast = $e }
}
if ($initLast) {
    $lastStreamStop = $initLast.TimeCreated
    if ($initLast.Id -eq 24) { $streaming = $true }
    Write-Log ("启动状态：最近流事件 Id={0} @ {1:HH:mm:ss}，streaming={2}" -f $initLast.Id, $initLast.TimeCreated, $streaming)
} else {
    Write-Log '启动状态：最近 24 小时无流事件，按「无流」处理'
}

while ($true) {
    try { Start-Sleep -Seconds $PollSeconds } catch { }
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
            $streaming = $true
        } elseif ($e.Id -eq 25) {
            if ($pendingStart) {
                $alive = ($e.TimeCreated - $pendingStart).TotalSeconds
                if ($alive -lt 5) { [void]$shortStreams.Add($e.TimeCreated) }
                $pendingStart = $null
            }
            $streaming = $false
            $lastStreamStop = $e.TimeCreated
        } elseif ($e.Id -eq 22) {
            $streaming = $false
            $lastStreamStop = $e.TimeCreated
        }
    }

    $cut = $now.AddSeconds(-$StreamWindowSeconds)
    $keep = @($shortStreams | Where-Object { $_ -gt $cut })
    $shortStreams = New-Object System.Collections.ArrayList
    foreach ($t in $keep) { [void]$shortStreams.Add($t) }

    if ($keep.Count -ge $StreamThreshold) {
        $shortStreams = New-Object System.Collections.ArrayList
        [void](Invoke-Reset -Reason ("{0} 秒内出现 {1} 次短命音频流（疑似播放器建流失败）" -f $StreamWindowSeconds, $keep.Count))
    }

    # --- 主判据：静置刷新 ---
    # 判定「有没有在播放」不看 CPU：实测 audiodg 在完全没播放时每 5 秒也在消耗
    # 0.015~0.125 秒 CPU（约 1.2%），和播放时分不开，这条路作废。
    # 改看 PlaybackManager 的流状态：
    #   最后一条流事件是 24（流启动、还没收到 25）→ 正在播放，不动它
    #   最后一条是 25/22（流停止/暂停），或压根没有新事件 → 无流，从那一刻开始算静置
    # 这样即使故障期间一条事件都没有（10-20 20:43 那次就是），也能按「最后一次停止」计时
    if ($streaming -and ($now - $lastStreamStop).TotalHours -ge 12) {
        Write-Log '流状态已持续 12 小时未见停止事件，按无流处理（防止应用没发 25 导致永远不复位）；同时把静置计时起点重置为现在，免得立刻触发刷新' 'WARN'
        $streaming = $false
        $lastStreamStop = $now
    }

    $idleMin = ($now - $lastStreamStop).TotalMinutes
    $sinceRefresh = ($now - $lastRefreshTime).TotalMinutes
    $awakeMin = ($now - $runStart).TotalMinutes
    # 三个门同时满足才刷：① 没有活跃流 ② 静置够久 ③ 距上次刷新够久（否则静置一小时就只刷一次）
    # 外加 ④ 守护自己至少醒了 5 分钟，避免刚启动就刷（那是无意义的抖动）
    if (-not $streaming -and $idleMin -ge $IdleMinutes -and $sinceRefresh -ge $RefreshIntervalMinutes -and $awakeMin -ge $StartupGraceMinutes) {
        # 触发前复查：最近 60 秒内有任何音频事件就跳过（降低「刚好开始播放」的误判）
        $recentEvs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Audio/PlaybackManager'; StartTime = $now.AddSeconds(-60) } -ErrorAction SilentlyContinue)
        if ($recentEvs.Count -gt 0) {
            Write-Log ("静置 {0:N0} 分钟，但最近 60 秒有 {1} 条新音频事件，跳过本次刷新" -f $idleMin, $recentEvs.Count)
        }
        else {
            $didReset = Invoke-Reset -Reason ("已静置 {0:N0} 分钟无音频流（最后一条流事件是停止/暂停），预防性刷新引擎" -f $idleMin)
            if ($didReset) {
                $lastRefreshTime = Get-Date
                $lastStreamStop = $lastRefreshTime
            }
        }
    }

    # --- 心跳（每 30 分钟一行，便于确认守护还活着）---
    if (($now - $lastHeartbeat).TotalMinutes -ge 30) {
        $lastHeartbeat = $now
        $cur = Get-PrimaryEndpoint
        $svc = Get-Service Audiosrv -ErrorAction SilentlyContinue
        $state = if ($cur) { $cur.State } else { 'N/A' }
        $idle = [int]($now - $lastStreamStop).TotalMinutes
        $tag = if ($streaming) { '播放中' } else { ('静置 ' + $idle + ' 分钟') }
        Write-Log ("心跳：端点 State={0}，Audiosrv={1}，{2}" -f $state, $svc.Status, $tag)
    }
}
