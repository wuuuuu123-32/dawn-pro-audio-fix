#Requires -Version 5.1
<#
.SYNOPSIS
    Dawn Pro 音频修复 —— 全局热键常驻版

.DESCRIPTION
    常驻进程，监听全局热键（默认 Ctrl+Alt+Shift+A）。按下后：
      ① 先抓故障现场快照（端点峰值 + 每个音频会话的 pid/状态 + 键鼠空闲）
      ② 重启 Audiosrv
      ③ 再抓一次恢复后的快照，与故障态对比
    所有内容追加到 snapshot.log，便于下次分析「引擎坏死」的真实特征。

    为什么先抓快照再修：这类故障在系统日志里一条记录都没有，
    唯一的机会就是按下热键到重启服务之间的那 2 到 3 秒。

    运行方式：计划任务（RunLevel=Highest、仅用户登录时运行、单实例）。
    必须用 Highest，否则 Restart-Service Audiosrv 会失败；
    必须「仅用户登录时运行」，否则会跑到 Session 0，热键注册了也不响应。

.NOTES
    已知边界（会审 rv-19c4eb1e996e33cf 提出）：
    - RegisterHotKey(NULL,...) 的「全局」范围是当前窗口站/桌面，不是跨会话
    - 提权进程发 Toast 通知不可靠，故注册失败时写日志 + 弹一次 MessageBox
    - 录音/会议期间重启 Audiosrv 会中断录音；本脚本不阻止，
      因为热键由用户主动按下（知情），但会把当时的录音会话状态记进日志
#>
param(
    [int]$HotkeyVk = 0x41,              # VK_A
    [int]$HotkeyMods = 0x7,             # MOD_ALT(1) | MOD_CONTROL(2) | MOD_SHIFT(4)
    [string]$StopFlag = '',             # 存在这个文件时退出（卸载用）
    [switch]$SelfTest,                  # 不注册热键，直接跑一次「快照 + 修复 + 快照」
    [switch]$RegisterTest               # 只测热键能否注册成功，然后退出
)

$ErrorActionPreference = 'Stop'
$RootDir = $PSScriptRoot
if (-not $RootDir) { $RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogPath = Join-Path $RootDir 'hotkey.log'
$SnapPath = Join-Path $RootDir 'snapshot.log'
if (-not $StopFlag) { $StopFlag = Join-Path $RootDir 'hotkey.stop' }

# ============================================================
# 日志
# ============================================================
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO', [string]$File = $LogPath)
    $line = ('[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Msg)
    try { Add-Content -LiteralPath $File -Value $line -Encoding UTF8 } catch { }
    try { Write-Host $line } catch { }
}

# ============================================================
# Win32 热键
# ============================================================
$hotkeySrc = @'
using System;
using System.Runtime.InteropServices;

public static class HotkeyApi
{
    [StructLayout(LayoutKind.Sequential)]
    public struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, int fsModifiers, int vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

    public const uint WM_HOTKEY = 0x0312;
    public const uint PM_REMOVE = 0x0001;

    // 清空消息队列里所有积压消息，避免修复期间按下的键在恢复后被重复处理
    public static void DrainQueue()
    {
        MSG m;
        int guard = 0;
        while (PeekMessage(out m, IntPtr.Zero, 0, 0, PM_REMOVE) && guard++ < 1000) { }
    }

    // 在 timeoutMs 内等待 WM_HOTKEY；收到返回 true，超时返回 false。
    // 放在 C# 里做是为了避免在 PowerShell 里操作 MSG 结构体。
    public static bool WaitHotkey(int timeoutMs)
    {
        MSG m;
        int waited = 0;
        while (waited < timeoutMs)
        {
            if (PeekMessage(out m, IntPtr.Zero, 0, 0, PM_REMOVE))
            {
                if (m.message == WM_HOTKEY) return true;
            }
            else
            {
                System.Threading.Thread.Sleep(100);
                waited += 100;
            }
        }
        return false;
    }
}
'@
try { Add-Type -TypeDefinition $hotkeySrc -Language CSharp -ErrorAction SilentlyContinue } catch { }

# ============================================================
# 音频探针：默认端点峰值 + 会话枚举
# ============================================================
$audioSrc = @'
using System;
using System.Runtime.InteropServices;

public static class HotkeyAudio
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr ppDevices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioMeterInformation
    {
        int GetPeakValue(out float pfPeak);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionManager2
    {
        int GetAudioSessionControl(ref Guid AudioSessionGuid, int StreamFlags, out IntPtr SessionControl);
        int GetSimpleAudioVolume(ref Guid AudioSessionGuid, int StreamFlags, out IntPtr AudioVolume);
        int GetSessionEnumerator(out IAudioSessionEnumerator SessionEnum);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionEnumerator
    {
        int GetCount(out int SessionCount);
        int GetSession(int SessionCount, out IAudioSessionControl2 Session);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl2
    {
        int GetState(out int pRetVal);
        int GetDisplayName(out IntPtr pRetVal);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetIconPath(out IntPtr pRetVal);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetGroupingParam(out Guid pRetVal);
        int SetGroupingParam(ref Guid Override, ref Guid EventContext);
        int RegisterAudioSessionNotification(IntPtr NewNotifications);
        int UnregisterAudioSessionNotification(IntPtr NewNotifications);
        int GetSessionIdentifier(out IntPtr pRetVal);
        int GetSessionInstanceIdentifier(out IntPtr pRetVal);
        int GetProcessId(out int pRetVal);
        int IsSystemSoundsSession();
        int SetDuckingPreference(bool optOut);
    }

    // 采样 n 次峰值，返回最大与平均
    public static string GetPeakStats(int n, int gapMs)
    {
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        IMMDevice dev = null;
        object mo = null;
        try
        {
            int hr = en.GetDefaultAudioEndpoint(0, 1, out dev);
            if (hr != 0) return "GetDefaultAudioEndpoint failed hr=" + hr;
            Guid iid = typeof(IAudioMeterInformation).GUID;
            hr = dev.Activate(ref iid, 1, IntPtr.Zero, out mo);
            if (hr != 0) return "Activate(meter) failed hr=" + hr;
            IAudioMeterInformation m = (IAudioMeterInformation)mo;
            float max = 0f;
            float sum = 0f;
            string all = "";
            for (int i = 0; i < n; i++)
            {
                float p;
                hr = m.GetPeakValue(out p);
                if (hr != 0) return "GetPeakValue failed hr=" + hr;
                if (p > max) max = p;
                sum += p;
                if (i > 0) all += ",";
                all += p.ToString("F4");
                System.Threading.Thread.Sleep(gapMs);
            }
            return "peakMax=" + max.ToString("F6") + " peakAvg=" + (sum / n).ToString("F6") + " samples=[" + all + "]";
        }
        finally
        {
            if (mo != null) Marshal.ReleaseComObject(mo);
            if (dev != null) Marshal.ReleaseComObject(dev);
            if (en != null) Marshal.ReleaseComObject(en);
        }
    }

    // 枚举指定数据流方向上的会话：dataFlow 0=eRender 1=eCapture
    public static string ListSessions(int dataFlow)
    {
        string result = "";
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        IMMDevice dev = null;
        object mgrObj = null;
        IAudioSessionEnumerator sessEnum = null;
        try
        {
            int hr = en.GetDefaultAudioEndpoint(dataFlow, 1, out dev);
            if (hr != 0) return "  (GetDefaultAudioEndpoint failed hr=" + hr + ")";
            Guid iidMgr = typeof(IAudioSessionManager2).GUID;
            hr = dev.Activate(ref iidMgr, 1, IntPtr.Zero, out mgrObj);
            if (hr != 0) return "  (Activate(mgr) failed hr=" + hr + ")";
            IAudioSessionManager2 mgr = (IAudioSessionManager2)mgrObj;
            hr = mgr.GetSessionEnumerator(out sessEnum);
            if (hr != 0) return "  (GetSessionEnumerator failed hr=" + hr + ")";
            int count = 0;
            sessEnum.GetCount(out count);
            for (int i = 0; i < count; i++)
            {
                IAudioSessionControl2 ctl = null;
                try
                {
                    hr = sessEnum.GetSession(i, out ctl);
                    if (hr != 0) continue;
                    int state = -1;
                    ctl.GetState(out state);
                    int pid = -1;
                    ctl.GetProcessId(out pid);
                    string name = "?";
                    try { if (pid > 0) name = System.Diagnostics.Process.GetProcessById(pid).ProcessName; else name = "SystemSounds"; } catch { }
                    string stateName = state == 0 ? "Inactive" : (state == 1 ? "Active" : (state == 2 ? "Expired" : "?"));
                    result += "    pid=" + pid + " (" + name + ") state=" + state + " [" + stateName + "]\r\n";
                }
                finally
                {
                    if (ctl != null) Marshal.ReleaseComObject(ctl);
                }
            }
            if (count == 0) result += "    (no sessions)\r\n";
        }
        catch (Exception ex)
        {
            result += "    (EXCEPTION " + ex.GetType().Name + ": " + ex.Message + ")\r\n";
        }
        finally
        {
            if (sessEnum != null) Marshal.ReleaseComObject(sessEnum);
            if (mgrObj != null) Marshal.ReleaseComObject(mgrObj);
            if (dev != null) Marshal.ReleaseComObject(dev);
            if (en != null) Marshal.ReleaseComObject(en);
        }
        return result;
    }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("kernel32.dll")]
    private static extern uint GetTickCount();

    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    public static double GetIdleSeconds()
    {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return 0.0;
        return (GetTickCount() - lii.dwTime) / 1000.0;
    }
}
'@
try { Add-Type -TypeDefinition $audioSrc -Language CSharp -ErrorAction SilentlyContinue } catch {
    Write-Log ('音频探针编译失败：' + $_.Exception.Message) 'ERROR'
}

# ============================================================
# 快照
# ============================================================
function Get-Snapshot {
    param([string]$Tag)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('---- ' + $Tag + ' @ ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ----')
    try {
        $ag = Get-Process audiodg -ErrorAction SilentlyContinue
        if ($ag) {
            [void]$sb.AppendLine(('  audiodg PID={0} 启动={1:HH:mm:ss} CPU={2:N1}s' -f $ag.Id, $ag.StartTime, $ag.CPU))
        } else {
            [void]$sb.AppendLine('  audiodg 未运行')
        }
    } catch { [void]$sb.AppendLine('  audiodg 查询失败') }

    try {
        [void]$sb.AppendLine('  ' + [HotkeyAudio]::GetPeakStats(6, 300))
    } catch { [void]$sb.AppendLine('  峰值采样失败: ' + $_.Exception.Message) }

    try {
        [void]$sb.AppendLine('  键鼠空闲=' + [math]::Round([HotkeyAudio]::GetIdleSeconds(), 1) + ' 秒')
    } catch { }

    try {
        [void]$sb.AppendLine('  渲染会话:')
        [void]$sb.Append(([HotkeyAudio]::ListSessions(0)))
    } catch { [void]$sb.AppendLine('  渲染会话枚举失败') }

    try {
        [void]$sb.AppendLine('  采集会话（录音/会议占用）:')
        [void]$sb.Append(([HotkeyAudio]::ListSessions(1)))
    } catch { [void]$sb.AppendLine('  采集会话枚举失败') }

    return $sb.ToString()
}

# ============================================================
# 执行一次「快照 + 修复 + 快照」
# ============================================================
function Invoke-Repair {
    param([string]$Trigger = '热键')

    Write-Log ('===== ' + $Trigger + ' 触发修复 =====')
    try {
        Add-Content -LiteralPath $SnapPath -Value (Get-Snapshot '故障现场') -Encoding UTF8
    } catch { Write-Log ('快照写入失败: ' + $_.Exception.Message) 'WARN' }

    $t0 = Get-Date
    $ok = $false
    $err = ''
    try {
        Restart-Service Audiosrv -Force -ErrorAction Stop
        $ok = $true
    } catch {
        $err = $_.Exception.Message
    }

    $wait = 1
    if ($ok) { $wait = 3 }
    Start-Sleep -Seconds $wait

    if ($ok) {
        $elapsed = ((Get-Date) - $t0).TotalSeconds
        Write-Log ('Audiosrv 已重启，耗时 ' + [math]::Round($elapsed, 1) + ' 秒')
        try {
            Add-Content -LiteralPath $SnapPath -Value (Get-Snapshot '修复后') -Encoding UTF8
        } catch { }
    } else {
        Write-Log ('重启失败：' + $err) 'ERROR'
        try {
            Add-Content -LiteralPath $SnapPath -Value ('---- 修复失败: ' + $err + ' ----') -Encoding UTF8
        } catch { }
    }

    try {
        $svc = Get-Service Audiosrv -ErrorAction SilentlyContinue
        if ($svc) { Write-Log ('Audiosrv 当前状态=' + $svc.Status) }
    } catch { }
    Write-Log '===== 修复流程结束 ====='
    return $ok
}

# ============================================================
# 入口
# ============================================================
if ($SelfTest) {
    Write-Log ' 自检模式：直接执行一次修复流程'
    $r = Invoke-Repair -Trigger '自检'
    if ($r) { 'SELFTEST_OK' } else { 'SELFTEST_FAILED' }
    exit 0
}

# 单实例：已有同名互斥体则退出
$mutexName = 'Global\DawnProAudioHotkey'
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    if (-not $mutex.WaitOne(0)) {
        Write-Log '已有实例在运行，本实例退出' 'WARN'
        exit 0
    }
} catch {
    Write-Log ('互斥体创建失败（继续运行）: ' + $_.Exception.Message) 'WARN'
}

Write-Log ('启动：进程 SessionId=' + (Get-Process -Id $PID).SessionId + ' 用户=' + [Environment]::UserName)

# 注册热键
$regOk = $false
try {
    $regOk = [HotkeyApi]::RegisterHotKey([IntPtr]::Zero, 1, $HotkeyMods, $HotkeyVk)
} catch {
    Write-Log ('RegisterHotKey 异常：' + $_.Exception.Message) 'ERROR'
}

if ($RegisterTest) {
    if ($regOk) {
        'REGISTER_OK'
        [void][HotkeyApi]::UnregisterHotKey([IntPtr]::Zero, 1)
    } else {
        $e = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        'REGISTER_FAILED lastError=' + $e
    }
    exit 0
}

if (-not $regOk) {
    $lastErr = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Log ('热键注册失败（lastError=' + $lastErr + '），可能被其他程序占用。热键功能不可用。') 'ERROR'
    # 提权进程无法可靠发 Toast，用一次 MessageBox 保证用户看得见
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            ('音频修复热键注册失败（错误码 ' + $lastErr + '）。' + [Environment]::NewLine +
             'Ctrl+Alt+Shift+A 可能已被其他程序占用。' + [Environment]::NewLine +
             '热键暂时不可用，请仍使用桌面的 fix-audio.cmd。'),
            'Dawn Pro 音频热键', 'OK', 'Warning')
    } catch { }
    exit 1
}

Write-Log '热键注册成功：Ctrl+Alt+Shift+A'

# 主循环
$busy = $false
$lastRun = [datetime]::MinValue
$cooldownSec = 5

try {
    while ($true) {
        if (Test-Path -LiteralPath $StopFlag) {
            Write-Log '检测到停止标志，退出'
            break
        }

        $hit = $false
        try { $hit = [HotkeyApi]::WaitHotkey(3000) } catch { $hit = $false }

        if ($hit) {
            $now = Get-Date
            if (-not $busy -and (($now - $lastRun).TotalSeconds -ge $cooldownSec)) {
                $busy = $true
                try {
                    [void](Invoke-Repair -Trigger '热键 Ctrl+Alt+Shift+A')
                    $lastRun = Get-Date
                } catch {
                    Write-Log ('修复流程异常：' + $_.Exception.Message) 'ERROR'
                } finally {
                    $busy = $false
                    try { [HotkeyApi]::DrainQueue() } catch { }
                }
            } else {
                Write-Log '触发被忽略（正在处理中或处于冷却期）' 'WARN'
            }
        }
    }
} finally {
    try { [void][HotkeyApi]::UnregisterHotKey([IntPtr]::Zero, 1) } catch { }
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
    Write-Log '已退出'
}
