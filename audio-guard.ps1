<#
  Dawn Pro 音频守护（v1.2.0）

  背景：这个 USB DAC 有三类故障，表现都是「设备在线、端点 ACTIVE、服务在跑，
        但播放器出不来声音」，手动重启 Audiosrv 能好（约 4 秒）：
    1) Type-C 口物理松动 → 设备反复瞬断（Event 65 在 1/4 之间狂跳）
    2) 零掉线，但长时间运行后引擎内部流对象坏死（进度条走，没声音）
    3) 长时间不播放后第一次播放失败（日志里一条事件都没有）

  判据设计（2026-10-22 第三轮会审后重做）：

    会审直接否掉了我原来两个假设：
      - 「峰值 0 = 没在播放」不成立：独占模式 / ASIO / Kernel Streaming 绕过
        软件峰值表，一直在播也读 0
      - 「峰值 > 0 = 正常」不成立：故障在下游（USB 输出、DAC）时软件混音照跑，
        坏了也读正常
    结论：只看「输出量」永远同时存在漏修和误伤，必须引入独立的
    「应该正在输出」依据。

    于是改用两个独立信号：
      ① WASAPI 峰值（IAudioMeterInformation）：过去 90 秒窗口内密采（每轮连采
         5 次、间隔 200ms），取最大值 → 判断「有没有数字音频在流」
      ② 用户输入空闲（GetLastInputInfo）：判断「有没有人在用这台电脑」
    第二条是关键：人不在，就一定没人在听，这时重启绝对安全。

    判据 A（强信号，覆盖「正在用时坏死」）：
        streaming=True（确实收到过 PlaybackManager Event 24）
        且 90 秒窗口峰值全 < SilenceThreshold
        → 有播放意图 + 无音频输出 = 确定故障 → 重启（冷却 HardCooldownSeconds）

    判据 B（预防信号，覆盖「静置后首播失败」）：
        用户输入空闲 >= IdleMinutes 分钟
        且 90 秒窗口峰值全 < SilenceThreshold
        → 没人在用、也没声音 → 重启安全（冷却 RefreshIntervalMinutes）

    判据 C（兜底，绝不误伤）：
        WASAPI 读不到（独占模式 / 端点不存在 / 初始化失败）
        → 视为「未知」，不重启，日志记 WARN。
        绝不降级回 PlaybackManager 判据 —— 那个已被实测证实会误伤。

    已知局限（会审列出的反例，权衡后接受）：
      - 播客 / 有声书有超过 90 秒的静音段，若此时人也不在，会被判据 B 刷一次
        （无人在听，无感；风险是重启可能销毁仍被播放器持有的音频客户端）
      - 其他应用持续发声会掩盖目标播放器坏死 → 判据 A 不触发（漏修）
      - 独占 / ASIO 输出绕过峰值表 → 判据 A 不触发（漏修），这类请手动修
      - 多用户会话：任务跑在注册的那个账号会话里，不一定是正在用 DAC 的会话
      - FastUserSwitch 期间 Interactive 任务可能停在旧会话

    运行身份：计划任务注册为「当前用户 + 最高权限 + 交互登录」。
      必须交互登录，因为 SYSTEM 会话（Session 0）访问不到用户会话的音频设备图。

    其余保留：
      - 补偿信号：Dawn Pro 端点从非 ACTIVE 恢复为 ACTIVE
      - 复位分级：端点非 ACTIVE 先 pnputil /restart-device，3 秒后不行再重启服务；
        端点已 ACTIVE（引擎层卡死）直接跳到重启服务
      - 限流：CooldownSeconds / MaxPerHour 双重闸
      - 状态用位掩码（ACTIVE=0x1）

  用法：
    -DryRun    只记录不动作（用来观察是否会误触发）
    -Simulate  立刻走一次复位流程然后退出
    正常运行需要管理员权限，建议用 install-guard.cmd 注册成登录计划任务
#>
param(
    [switch]$DryRun,
    [switch]$Simulate,
    [switch]$DebugPeak,
    [int]$PollSeconds = 5,
    [int]$CooldownSeconds = 60,
    [int]$MaxPerHour = 4,
    [int]$RunSeconds = 0,
    [int]$StreamThreshold = 5,
    [int]$StreamWindowSeconds = 120,
    [int]$IdleMinutes = 30,              # 用户输入空闲多少分钟才算「人不在」
    [int]$RefreshIntervalMinutes = 60,   # 判据 B 两次刷新之间的最小间隔
    [int]$HardCooldownSeconds = 120,     # 判据 A（确定故障）的冷却，比 B 短，故障时效优先
    [int]$PeakWindowSeconds = 90,        # 峰值滑动窗口长度
    [double]$SilenceThreshold = 0.0005,  # 低于它视为「没有音频输出」（约 -66 dBFS）
    [int]$ProbeBurst = 5,                # 每轮连采几次
    [int]$ProbeGapMs = 200,              # 连采间隔
    [double]$StartupGraceMinutes = 5     # 守护自己至少醒这么久才允许第一次动作
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

# ---------------- WASAPI 峰值探针 + 用户输入空闲 ----------------
# 注意：这段 C# 是 C# 5 语法（Add-Type 在 PS 5.1 下用老编译器），别用新特性。
$probeSrc = @'
using System;
using System.Runtime.InteropServices;

public static class DshAudioProbe
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        int RegisterEndpointNotificationCallback(IntPtr client);
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams,
                     [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        int OpenPropertyStore(int stgmAccess, out IntPtr properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioMeterInformation
    {
        int GetPeakValue(out float pfPeak);
        int GetMeteringChannelCount(out int pnChannelCount);
        int GetChannelsPeakValues(int u32ChannelCount, [Out] float[] afPeakValues);
        int QueryHardwareSupport(out int pdwHardwareSupportMask);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("kernel32.dll")]
    private static extern uint GetTickCount();

    // 默认输出设备（eRender=0, eMultimedia=1）的实时峰值，范围 0.0 到 1.0
    public static float GetPeak()
    {
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        IMMDevice dev = null;
        object meterObj = null;
        try
        {
            int hr = en.GetDefaultAudioEndpoint(0, 1, out dev);
            if (hr != 0) throw new COMException("GetDefaultAudioEndpoint", hr);

            Guid iid = typeof(IAudioMeterInformation).GUID;
            hr = dev.Activate(ref iid, 1 /* CLSCTX_INPROC_SERVER */, IntPtr.Zero, out meterObj);
            if (hr != 0) throw new COMException("Activate", hr);

            IAudioMeterInformation meter = (IAudioMeterInformation)meterObj;
            float peak;
            hr = meter.GetPeakValue(out peak);
            if (hr != 0) throw new COMException("GetPeakValue", hr);
            return peak;
        }
        finally
        {
            if (meterObj != null) Marshal.ReleaseComObject(meterObj);
            if (dev != null) Marshal.ReleaseComObject(dev);
            if (en != null) Marshal.ReleaseComObject(en);
        }
    }

    // 默认输出设备的端点 ID，用来确认「默认设备还是不是 Dawn Pro」
    public static string GetDefaultEndpointId()
    {
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        IMMDevice dev = null;
        try
        {
            int hr = en.GetDefaultAudioEndpoint(0, 1, out dev);
            if (hr != 0) throw new COMException("GetDefaultAudioEndpoint", hr);
            string id;
            hr = dev.GetId(out id);
            if (hr != 0) throw new COMException("GetId", hr);
            return id;
        }
        finally
        {
            if (dev != null) Marshal.ReleaseComObject(dev);
            if (en != null) Marshal.ReleaseComObject(en);
        }
    }

    // 最后一次键盘/鼠标输入距今多少秒；取不到时返回 0（保守：当成「人就在电脑前」）
    public static double GetIdleSeconds()
    {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return 0.0;
        uint now = GetTickCount();
        uint idle = now - lii.dwTime;
        return idle / 1000.0;
    }
}
'@

$probeOk = $false
try {
    # -ErrorAction SilentlyContinue：重复加载同类型会报「类型已存在」，无害
    Add-Type -TypeDefinition $probeSrc -Language CSharp -ErrorAction SilentlyContinue
    $probeOk = $true
} catch {
    Write-Log ('WASAPI 探针编译失败：' + $_.Exception.Message) 'ERROR'
}

function Get-PeakBurst {
    <# 连采 ProbeBurst 次，返回最大值；全部失败返回 $null（=未知，不是 0） #>
    if (-not $probeOk) { return $null }
    $max = -1.0
    $okCount = 0
    for ($i = 0; $i -lt $ProbeBurst; $i++) {
        try {
            $v = [double][DshAudioProbe]::GetPeak()
            if ($v -gt $max) { $max = $v }
            $okCount++
        } catch { }
        if ($i -lt ($ProbeBurst - 1)) { Start-Sleep -Milliseconds $ProbeGapMs }
    }
    if ($okCount -eq 0) { return $null }
    return $max
}

function Get-InputIdleMinutes {
    <# 用户多久没碰键盘鼠标；失败时返回 0（保守，避免误判「人不在」） #>
    if (-not $probeOk) { return 0.0 }
    try { return ([DshAudioProbe]::GetIdleSeconds() / 60.0) } catch { return 0.0 }
}

# ---------------- 端点映射 ----------------

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
    param([int]$Cooldown = 0)
    $now = Get-Date
    $cd = if ($Cooldown -gt 0) { $Cooldown } else { $CooldownSeconds }
    if ($script:LastReset -and (($now - $script:LastReset).TotalSeconds -lt $cd)) {
        Write-Log ("冷却中：距上次复位 {0:N0} 秒（本次判据冷却 {1} 秒），跳过" -f ($now - $script:LastReset).TotalSeconds, $cd) 'WARN'
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
    param([string]$Reason, [int]$Cooldown = 0)

    Write-Log "=== 触发复位：$Reason ==="
    if (-not (Test-CanReset -Cooldown $Cooldown)) { return $false }
    if ($DryRun) {
        # DryRun 也走同样的限流：否则日志里每轮都报一次，看不出真实的触发频率
        $script:LastReset = Get-Date
        [void]$script:ResetTimes.Add($script:LastReset)
        Write-Log 'DryRun：只记录，不执行任何复位动作（已按真实限流计时）' 'WARN'
        return $true
    }

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
Write-Log '=== Dawn Pro 音频守护启动（v1.2.0）==='
Write-Log ("参数：DryRun={0} Simulate={1} Poll={2}s Cooldown={3}s MaxPerHour={4} IdleInput={5}min Refresh={6}min PeakWin={7}s Thr={8} Burst={9}x{10}ms" -f `
    $DryRun, $Simulate, $PollSeconds, $CooldownSeconds, $MaxPerHour, $IdleMinutes, $RefreshIntervalMinutes, $PeakWindowSeconds, $SilenceThreshold, $ProbeBurst, $ProbeGapMs)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Write-Log '需要管理员权限（要执行设备重启与服务重启）。' 'ERROR'
    exit 1
}

if (-not $probeOk) {
    Write-Log 'WASAPI 探针不可用 → 判据 A/B 都无法评估，守护将只做端点补偿与短命流检测（不会主动刷新引擎）' 'ERROR'
}
else {
    try {
        $defId = [DshAudioProbe]::GetDefaultEndpointId()
        Write-Log ("当前默认输出端点：{0}" -f $defId)
    } catch {
        Write-Log ('读取默认端点失败：' + $_.Exception.Message) 'WARN'
    }
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

# 探针自检：确认这个运行身份下真的读得到峰值（SYSTEM 会话读不到，会是 null）
if ($probeOk) {
    $p0 = Get-PeakBurst
    $i0 = Get-InputIdleMinutes
    if ($null -eq $p0) {
        Write-Log '探针自检：读取默认端点峰值失败（独占模式 / 端点切换中 / 权限不足）' 'WARN'
    } else {
        Write-Log ("探针自检：默认端点峰值={0:F6}，键鼠空闲={1:N1} 分钟" -f $p0, $i0)
    }
}

$lastCheck = Get-Date
$pendingStart = $null
$shortStreams = New-Object System.Collections.ArrayList
$lastHeartbeat = Get-Date
$runStart = Get-Date
$streaming = $false               # 是否有活跃音频流（最后一条流事件是 24 且还没收到 25）
$lastStreamStart = $null          # 最近一次 Event 24 的时刻（用于 12 小时兜底）
$peaks = New-Object System.Collections.ArrayList   # 峰值样本 {T=时刻, V=值}
$lastRefreshTime = [datetime]::MinValue
$probeFailStreak = 0
$probeWarned = $false

# 引擎刚重建过（audiodg 启动不到 10 分钟）就不必再刷一次，否则守护每次重启都会立刻多刷一遍
$ag = Get-Process audiodg -ErrorAction SilentlyContinue
if ($ag -and ((Get-Date) - $ag.StartTime).TotalMinutes -lt 10) {
    $lastRefreshTime = $ag.StartTime
    Write-Log ('启动检测：audiodg 于 {0:HH:mm:ss} 启动，不足 10 分钟，视为引擎刚刷新过（{1} 分钟后才允许再刷）' -f $ag.StartTime, $RefreshIntervalMinutes)
}
else {
    Write-Log '启动检测：audiodg 不是刚重建，lastRefreshTime 保持初始值（首轮满足条件即可刷新）'
}

# 启动时先扫一遍最近的流事件，建立 streaming 的初始状态
# （判据 A 需要它：有播放意图但没输出，才是确定故障）
$initEvs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Audio/PlaybackManager'; StartTime = (Get-Date).AddHours(-24) } -ErrorAction SilentlyContinue)
$initLast = $null
foreach ($e in @($initEvs | Sort-Object TimeCreated)) {
    if ($e.Id -eq 24 -or $e.Id -eq 25 -or $e.Id -eq 22) { $initLast = $e }
}
if ($initLast) {
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

    # --- 采一次峰值（连采 ProbeBurst 次取最大，防止短音漏采）---
    $peak = Get-PeakBurst
    if ($null -eq $peak) {
        $probeFailStreak++
        if (-not $probeWarned -and $probeFailStreak -ge 3) {
            Write-Log 'WASAPI 峰值连续读取失败 → 判据视为「未知」，不做主动刷新（独占模式/ASIO 输出也会读不到）' 'WARN'
            $probeWarned = $true
        }
    }
    else {
        if ($probeFailStreak -gt 0) { Write-Log ("WASAPI 峰值恢复读取（此前连续失败 {0} 次）" -f $probeFailStreak) }
        $probeFailStreak = 0
        $probeWarned = $false
        [void]$peaks.Add([pscustomobject]@{ T = $now; V = [double]$peak })
    }

    # 裁剪滑窗
    $winCut = $now.AddSeconds(-$PeakWindowSeconds)
    $keepP = @($peaks | Where-Object { $_.T -gt $winCut })
    $peaks = New-Object System.Collections.ArrayList
    foreach ($x in $keepP) { [void]$peaks.Add($x) }

    $winMax = $null
    $winSpan = 0.0
    if ($keepP.Count -gt 0) {
        $winMax = [double](($keepP | Measure-Object -Property V -Maximum).Maximum)
        $winSpan = ($now - $keepP[0].T).TotalSeconds
    }
    # 窗口必须「基本填满」才允许下结论，否则刚启动那 90 秒会用不完整的数据误判。
    # 注意：窗口是按时间裁剪的，最老那个样本天然落在窗口边缘内侧，跨度上限天然等于
    #       PeakWindowSeconds 减去约一个轮询周期，所以门槛不能写成 0.9 倍（那样永不成立）。
    $winSlack = $PollSeconds * 3 + 5
    $winFull = ($keepP.Count -ge 3) -and ($winSpan -ge ($PeakWindowSeconds - $winSlack))

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

    # --- 维护 streaming（只给判据 A 用，不作单独判据）---
    $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Audio/PlaybackManager'; StartTime = $lastCheck } -ErrorAction SilentlyContinue)
    $lastCheck = $now
    foreach ($e in @($evs | Sort-Object TimeCreated)) {
        if ($e.Id -eq 24) {
            $pendingStart = $e.TimeCreated
            $lastStreamStart = $e.TimeCreated
            $streaming = $true
        } elseif ($e.Id -eq 25) {
            if ($pendingStart) {
                $alive = ($e.TimeCreated - $pendingStart).TotalSeconds
                if ($alive -lt 5) { [void]$shortStreams.Add($e.TimeCreated) }
                $pendingStart = $null
            }
            $streaming = $false
        } elseif ($e.Id -eq 22) {
            $streaming = $false
        }
    }

    # streaming 卡住 12 小时说明应用没发 25（事件通道不全），按无流处理，免得判据 A 永远成立
    if ($streaming -and $lastStreamStart -and (($now - $lastStreamStart).TotalHours -ge 12)) {
        Write-Log ("streaming 已持续 {0:N0} 小时未见停止事件，按无流处理" -f ($now - $lastStreamStart).TotalHours) 'WARN'
        $streaming = $false
    }

    # --- 短命流（辅助信号，独立于峰值）---
    $cut = $now.AddSeconds(-$StreamWindowSeconds)
    $keep = @($shortStreams | Where-Object { $_ -gt $cut })
    $shortStreams = New-Object System.Collections.ArrayList
    foreach ($t in $keep) { [void]$shortStreams.Add($t) }

    if ($keep.Count -ge $StreamThreshold) {
        $shortStreams = New-Object System.Collections.ArrayList
        [void](Invoke-Reset -Reason ("{0} 秒内出现 {1} 次短命音频流（疑似播放器建流失败）" -f $StreamWindowSeconds, $keep.Count))
    }

    # --- 主判据 ---
    $awakeMin = ($now - $runStart).TotalMinutes
    $idleInputMin = Get-InputIdleMinutes
    $sinceRefresh = ($now - $lastRefreshTime).TotalMinutes

    if ($DebugPeak) {
        $dbgMax = if ($null -eq $winMax) { 'null' } else { $winMax.ToString('F6') }
        Write-Log ("DEBUG 峰值窗最大={0} 样本={1} 跨度={2:N1}s winFull={3} 键鼠空闲={4:N1}min streaming={5} 醒着={6:N1}min 距上次刷新={7:N1}min 探针失败={8}" -f $dbgMax, $keepP.Count, $winSpan, $winFull, $idleInputMin, $streaming, $awakeMin, $sinceRefresh, $probeFailStreak)
    }

    if ($probeFailStreak -eq 0 -and $winFull -and $null -ne $winMax -and $winMax -lt $SilenceThreshold -and $awakeMin -ge $StartupGraceMinutes) {

        # 判据 A：有播放意图（收到过 24）但整整 90 秒没有任何音频输出
        if ($streaming) {
            $why = ("判据A：有播放意图（最后一条流事件是启动）但 {0} 秒窗口峰值最大仅 {1:F6}，判定引擎坏死" -f $PeakWindowSeconds, $winMax)
            [void](Invoke-Reset -Reason $why -Cooldown $HardCooldownSeconds)
            if ($script:LastReset) { $lastRefreshTime = Get-Date }
        }
        # 判据 B：没人在用电脑、也没声音 → 安全刷新（覆盖「静置后首播失败」）
        elseif ($idleInputMin -ge $IdleMinutes -and $sinceRefresh -ge $RefreshIntervalMinutes) {
            $why = ("判据B：用户已 {0:N0} 分钟无键鼠输入，且 {1} 秒窗口峰值最大仅 {2:F6}，预防性刷新引擎" -f $idleInputMin, $PeakWindowSeconds, $winMax)
            $did = Invoke-Reset -Reason $why -Cooldown ($RefreshIntervalMinutes * 60)
            if ($did) { $lastRefreshTime = Get-Date }
        }
    }

    # --- 心跳（每 30 分钟一行，便于确认守护还活着、以及它当时看到了什么）---
    if (($now - $lastHeartbeat).TotalMinutes -ge 30) {
        $lastHeartbeat = $now
        $cur = Get-PrimaryEndpoint
        $svc = Get-Service Audiosrv -ErrorAction SilentlyContinue
        $state = if ($cur) { $cur.State } else { 'N/A' }
        $peakTxt = if ($null -eq $winMax) { 'N/A' } else { ('{0:F6}' -f $winMax) }
        Write-Log ("心跳：端点 State={0}，Audiosrv={1}，峰值窗最大={2}，键鼠空闲={3:N0}分钟，streaming={4}" -f $state, $svc.Status, $peakTxt, $idleInputMin, $streaming)
    }
}
