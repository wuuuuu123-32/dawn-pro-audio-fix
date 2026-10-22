<#
  Dawn Pro 音频守护 —— 计划任务管理（v1.2.0）

  把 audio-guard.ps1 注册成计划任务。

  ⚠️ 运行身份从 SYSTEM 改成了「当前用户 + 最高权限 + 交互登录」：
     2026-10-22 第三轮会审指出，WASAPI（IAudioMeterInformation）必须在
     用户会话里才能访问音频设备图，SYSTEM 处在 Session 0，读不到。
     代价：必须有人登录着才跑（注销后不跑），且 RDP 断开时端点可能重定向。
     对「一台人天天用的笔记本」这个场景可以接受。

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
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Show-Status {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Host "计划任务: $taskName" -ForegroundColor Green
        Write-Host ("  状态: {0}" -f $task.State)
        Write-Host ("  身份: {0} / {1}" -f $task.Principal.UserId, $task.Principal.LogonType)
        Write-Host ("  上次运行: {0}  结果: {1}" -f $info.LastRunTime, $info.LastTaskResult)
        Write-Host ("  下次运行: {0}" -f $info.NextRunTime)
    } else {
        Write-Host "计划任务 $taskName 不存在（守护未安装）" -ForegroundColor Yellow
    }
    # 排除查询命令自身：执行这条查询的 powershell 命令行里也含 audio-guard.ps1
    $proc = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*audio-guard.ps1*' -and $_.ProcessId -ne $PID })
    if ($proc.Count -gt 0) {
        foreach ($p in $proc) { Write-Host ("守护进程: PID {0}（启动于 {1}）" -f $p.ProcessId, $p.CreationDate) -ForegroundColor Green }
    } else {
        Write-Host '守护进程: 未在运行（若不是管理员查询，可能看不到 SYSTEM 进程的命令行）' -ForegroundColor Yellow
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
        # 旧任务（可能是 SYSTEM 身份的老版本）先停掉删掉，否则 -Force 覆盖时可能残留运行中的实例
        $old = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($old) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host '已移除旧任务。' -ForegroundColor Yellow
        }
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*audio-guard.ps1*' -and $_.ProcessId -ne $PID } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                Write-Host ("已结束残留守护进程 PID {0}" -f $_.ProcessId) -ForegroundColor Yellow
            }

        $taskAction = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$guard`""
        # Interactive 身份只能在「用户登录」时触发；开机还没登录时本来也没人在听
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
        $trigger.Delay = 'PT30S'
        $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
        # StopOnIdleEnd 默认是 true —— 意思是「用户一活动（结束空闲）就把任务停掉」，
        # 2026-10-20 排查发现守护每次启动后活不过几秒就是被这条杀掉的，必须显式关掉。
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "已注册计划任务 $taskName（登录后 30 秒自启，身份 $me / Interactive + Highest）" -ForegroundColor Green
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 6
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
            Where-Object { $_.CommandLine -like '*audio-guard.ps1*' -and $_.ProcessId -ne $PID } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host ("已结束守护进程 PID {0}" -f $_.ProcessId) }
    }
    'start' {
        Start-ScheduledTask -TaskName $taskName
        Write-Host '已请求启动。' -ForegroundColor Green
        Start-Sleep -Seconds 6
        Show-Status
    }
    'stop' {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Host '已请求停止。' -ForegroundColor Green
    }
    'status' { Show-Status }
}
