<#
  Dawn Pro 音频守护 —— 计划任务管理

  把 audio-guard.ps1 注册成开机自启的计划任务（SYSTEM 身份、最高权限、
  不限运行时长），这样它才能在后台做设备级/服务级复位。

  用法（需管理员）：
    -Action install    注册并立即启动
    -Action uninstall  停止并删除任务
    -Action status     查看任务与守护进程状态
    -Action start      手动启动
    -Action stop       手动停止
#>
param(
    [ValidateSet('install', 'uninstall', 'status', 'start', 'stop')]
    [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$guard = Join-Path $scriptDir 'audio-guard.ps1'
$logPath = Join-Path $scriptDir 'audio-guard.log'
$taskName = 'DawnProAudioGuard'
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Show-Status {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Host "计划任务: $taskName" -ForegroundColor Green
        Write-Host ("  状态: {0}" -f $task.State)
        Write-Host ("  上次运行: {0}  结果: {1}" -f $info.LastRunTime, $info.LastTaskResult)
        Write-Host ("  下次运行: {0}" -f $info.NextRunTime)
    } else {
        Write-Host "计划任务 $taskName 不存在（守护未安装）" -ForegroundColor Yellow
    }
    $proc = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*audio-guard.ps1*' }
    if ($proc) {
        foreach ($p in $proc) { Write-Host ("守护进程: PID {0}" -f $p.ProcessId) -ForegroundColor Green }
    } else {
        Write-Host '守护进程: 未在运行' -ForegroundColor Yellow
    }
    if (Test-Path -LiteralPath $logPath) {
        Write-Host '--- 日志尾部 ---'
        Get-Content -LiteralPath $logPath -Tail 8
    }
}

if (-not $isAdmin -and $Action -ne 'status') {
    Write-Host '需要管理员权限。请通过 install-guard.cmd / uninstall-guard.cmd 启动。' -ForegroundColor Red
    exit 1
}

switch ($Action) {
    'install' {
        if (-not (Test-Path -LiteralPath $guard)) {
            Write-Host "找不到守护脚本：$guard" -ForegroundColor Red
            exit 1
        }
        $taskAction = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$guard`""
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        # StopOnIdleEnd 默认是 true —— 意思是「用户一活动（结束空闲）就把任务停掉」，
        # 2026-10-20 排查发现守护每次启动后活不过几秒就是被这条杀掉的，必须显式关掉。
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "已注册计划任务 $taskName（开机自启，SYSTEM 身份）" -ForegroundColor Green
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 3
        Write-Host '已启动守护。' -ForegroundColor Green
        Show-Status
    }
    'uninstall' {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "已删除计划任务 $taskName" -ForegroundColor Green
        } else {
            Write-Host '任务本来就不存在。' -ForegroundColor Yellow
        }
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*audio-guard.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host ("已结束守护进程 PID {0}" -f $_.ProcessId) }
    }
    'start' {
        Start-ScheduledTask -TaskName $taskName
        Write-Host '已请求启动。' -ForegroundColor Green
        Start-Sleep -Seconds 3
        Show-Status
    }
    'stop' {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Host '已请求停止。' -ForegroundColor Green
    }
    'status' { Show-Status }
}
