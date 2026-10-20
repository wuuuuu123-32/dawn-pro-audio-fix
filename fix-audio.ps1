param([switch]$Full, [switch]$CheckOnly)

# ============================================================
#  Dawn Pro 音频一键修复
#  场景：Type-C 口接触不良导致设备反复瞬断后，出现「设备连上了、
#        播放器却卡住没声音」。本质是音频流/引擎状态卡死，
#        重启音频服务可让它重新建立。
#  用法：双击 fix-audio.cmd（自动请求管理员权限）
#        加 -Full 会连带按依赖顺序重启 AudioEndpointBuilder
#        加 -CheckOnly 只检测不修改
# ============================================================

$ErrorActionPreference = 'Continue'

# 提权后当前目录不是脚本目录，必须用脚本自身路径定位日志
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$logPath = Join-Path $scriptDir 'fix-audio.log'
if (-not (Test-Path -LiteralPath $scriptDir -PathType Container)) {
    $logPath = Join-Path $env:TEMP 'dawn-pro-fix-audio.log'
}

function Write-Log {
    param([string]$msg, [string]$level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    if ($level -eq 'ERROR') { Write-Host $line -ForegroundColor Red }
    elseif ($level -eq 'WARN') { Write-Host $line -ForegroundColor Yellow }
    else { Write-Host $line }
}

# 读端点注册表，把 MMDevices 的端点 GUID 映射回具体的 USB PnP InstanceId。
# 注意：名称与关联信息在端点的 Properties 子键里，DeviceState 在主键里。
# 映射依据：PKEY_AudioEndpoint_Association 形如 "{1}.USB\VID_2FC6&PID_F06A&MI_00\6&...&0&0000"
function Get-DawnEndpoints {
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
    $out = @()
    foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $main = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        $p = Get-ItemProperty -LiteralPath "$($k.PSPath)\Properties" -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $name = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
        $assoc = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},2'
        if (($name -match 'Dawn') -or ($assoc -match 'VID_2FC6&PID_F06A')) {
            $iid = $null
            if ($assoc -match '^\{[^}]+\}\.(.+)$') { $iid = $Matches[1] }
            elseif ($assoc -match '(USB\\VID_2FC6&PID_F06A[^;]*)') { $iid = $Matches[1] }
            $out += [pscustomobject]@{
                EndpointId = $k.PSChildName
                Name       = $name
                InstanceId = $iid
                State      = $main.DeviceState
            }
        }
    }
    return $out
}

# ---- 权限检查 ----
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '需要管理员权限。请双击 fix-audio.cmd 启动（它会自动申请提权）。' -ForegroundColor Red
    exit 1
}

Write-Log '=== Dawn Pro 音频修复开始 ==='

$eps = Get-DawnEndpoints
if ($eps.Count -eq 0) {
    Write-Log '未找到 Dawn Pro 音频端点（注册表里没有 VID_2FC6&PID_F06A 的 Render 端点）。' 'WARN'
    Write-Host ''
    Write-Host '设备当前没有音频端点，常见原因：' -ForegroundColor Yellow
    Write-Host '  1. 没插好 / 线松了 -> 重新插拔，等 10 到 15 秒' -ForegroundColor Yellow
    Write-Host '  2. 换一个 Type-C 口再试' -ForegroundColor Yellow
    exit 2
}

foreach ($e in $eps) {
    Write-Log ('端点 {0} | {1} | State={2} | {3}' -f $e.EndpointId, $e.Name, $e.State, $e.InstanceId)
}

$active = @($eps | Where-Object { $_.State -eq 1 })
if ($active.Count -gt 0) { $target = $active[0] } else { $target = $eps[0] }

$dev = $null
if ($target.InstanceId) {
    $dev = Get-PnpDevice -InstanceId $target.InstanceId -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($dev) {
    Write-Log ('PnP 设备: Status={0} Problem={1}' -f $dev.Status, $dev.Problem)
}

$present = ($dev -and $dev.Status -eq 'OK' -and $dev.Problem -eq 'CM_PROB_NONE')

if ($CheckOnly) {
    Write-Log 'CheckOnly: 只检测，不做修改'
    if ($present) {
        Write-Host '检测结果: 设备在场，可以执行修复。' -ForegroundColor Green
    } else {
        Write-Host '检测结果: 设备不在场，需要重新插拔。' -ForegroundColor Yellow
    }
    exit 0
}

if (-not $present) {
    Write-Log '设备不在场（PHANTOM / 未连接），重启音频服务无法修复。' 'WARN'
    Write-Host ''
    Write-Host '设备不在场。请重新插拔 Dawn Pro，等 10 到 15 秒，再运行一次。' -ForegroundColor Yellow
    if ($target.InstanceId) {
        Write-Log '尽力尝试 pnputil /restart-device（对不在场设备通常无效）...'
        $r = & pnputil.exe /restart-device "$($target.InstanceId)" 2>&1
        Write-Log ('pnputil: ' + ($r -join ' | '))
        Start-Sleep -Seconds 2
        $dev2 = Get-PnpDevice -InstanceId $target.InstanceId -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($dev2) { Write-Log ('重查: Status={0} Problem={1}' -f $dev2.Status, $dev2.Problem) }
    }
    exit 3
}

Write-Log '设备在场，开始重启音频服务...'
$before = (Get-Service Audiosrv, AudioEndpointBuilder -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ' '
Write-Log "重启前: $before"

if ($Full) {
    Write-Log 'Full 模式：按依赖顺序重启 AudioEndpointBuilder 与 Audiosrv'
    try {
        Stop-Service Audiosrv -Force -ErrorAction Stop
        Stop-Service AudioEndpointBuilder -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Start-Service AudioEndpointBuilder -ErrorAction Stop
        Start-Sleep -Seconds 1
        Start-Service Audiosrv -ErrorAction Stop
        Write-Log '服务已按顺序重启'
    } catch {
        Write-Log ('服务重启失败: ' + $_.Exception.Message) 'ERROR'
    }
} else {
    try {
        Restart-Service Audiosrv -Force -ErrorAction Stop
        Write-Log 'Audiosrv 已重启'
    } catch {
        Write-Log ('Audiosrv 重启失败: ' + $_.Exception.Message) 'ERROR'
    }
}

Start-Sleep -Seconds 3

$svc = Get-Service Audiosrv -ErrorAction SilentlyContinue
$epsAfter = Get-DawnEndpoints
$activeAfter = @($epsAfter | Where-Object { $_.State -eq 1 })
Write-Log ('重启后: Audiosrv={0} | Dawn 端点总数={1} | 活跃={2}' -f $svc.Status, $epsAfter.Count, $activeAfter.Count)

if ($svc.Status -eq 'Running' -and $activeAfter.Count -gt 0) {
    Write-Log '结论: 音频链路已复位（端点重新处于 ACTIVE）'
    Write-Host ''
    Write-Host '修复完成，现在放一首歌试试。' -ForegroundColor Green
    Write-Host '如果还是没声音：' -ForegroundColor Yellow
    Write-Host '  1. 右键任务栏喇叭 -> 声音设置 -> 输出选 MOONDROP Dawn Pro' -ForegroundColor Yellow
    Write-Host '  2. 声音设置 -> Dawn Pro -> 高级 -> 默认格式改成 24 位 48000 Hz' -ForegroundColor Yellow
    Write-Host '  3. 再不行就用 -Full 参数跑一次（连带重启 AudioEndpointBuilder）' -ForegroundColor Yellow
    Write-Log '结束（成功）'
    exit 0
} else {
    Write-Log '结论: 重启后端点仍未恢复' 'WARN'
    Write-Host ''
    Write-Host '重启后端点没恢复，请重新插拔设备再试。' -ForegroundColor Yellow
    Write-Log '结束（未恢复）'
    exit 4
}
