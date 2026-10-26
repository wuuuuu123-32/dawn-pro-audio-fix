# 安装/更新 Dawn Pro 音频热键守护的计划任务（需管理员）
$ErrorActionPreference = 'Stop'
$RootDir = 'D:\dsh\config\dawn-pro-audio-fix'
$TaskName = 'DawnProAudioHotkey'
$User = "$env:USERDOMAIN\$env:USERNAME"

$ps1 = Join-Path $RootDir 'hotkey-fix.ps1'
if (-not (Test-Path -LiteralPath $ps1)) { throw "找不到 $ps1" }

# 先删旧任务（如果存在）
try {
    $old = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($old) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "已删除旧任务"
    }
} catch { Write-Host ("删除旧任务时: " + $_.Exception.Message) }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ps1 + '"') `
    -WorkingDirectory $RootDir

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $User

$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'Dawn Pro 音频修复全局热键（Ctrl+Alt+Shift+A），常驻监听，按下即抓快照并重启 Audiosrv' `
    -Force | Out-Null

Write-Host "任务已注册：$TaskName"

# 立即启动一次，验证能起来
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 4

$t = Get-ScheduledTask -TaskName $TaskName
$i = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host ('State=' + $t.State + '  LastResult=' + $i.LastTaskResult + '  LastRun=' + $i.LastRunTime)

# 检查进程
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*hotkey-fix.ps1*' }
if ($procs) {
    foreach ($p in $procs) {
        Write-Host ('进程 PID=' + $p.ProcessId)
    }
} else {
    Write-Host '警告：没找到 hotkey-fix.ps1 进程'
}

Write-Host 'INSTALL_DONE'
