# dawn-pro-audio-fix

给 **MOONDROP Dawn Pro**（水月雨 USB DAC 小尾巴）在 Windows 上用的音频卡死修复工具。

## 它解决什么问题

这个 USB DAC 在两种情况下会出现同一个症状：**设备是连着的、系统里看得到、音量条也不一定是零，但就是不出声**（播放器进度条照走，网易云 / B 站直接卡住）。

1. **接口接触不良** —— Type-C 口松动，设备在系统里反复「掉线 → 回来」，几分钟内几十上百次。掉得够多之后，音频引擎的状态就被拖坏了。
2. **零掉线卡死** —— 设备一直没掉线、电脑也没睡眠，开机跑了十几个小时后，引擎自己卡死。

两种情况都能靠**重启 Windows 音频服务（`Audiosrv`）**立刻恢复 —— 这就是这个工具做的事。

## 两个工具，选一个

| | 用法 | 适合 |
|---|---|---|
| **手动版** `fix-audio.cmd` | 双击 → UAC → 修完自动关 | 你发现没声音了，点一下 |
| **守护版** `audio-guard.ps1` | 装成计划任务后开机自启 | 想让它自动修 |

### 手动版

双击 `fix-audio.cmd` 即可。也可直接跑脚本：

```powershell
powershell -ExecutionPolicy Bypass -File fix-audio.ps1 -CheckOnly   # 只看状态，不改任何东西
powershell -ExecutionPolicy Bypass -File fix-audio.ps1              # 常规修复
powershell -ExecutionPolicy Bypass -File fix-audio.ps1 -Full        # 连 AudioEndpointBuilder 一起按依赖顺序重启
```

### 守护版

安装（需要管理员）：双击 `install-guard.cmd`
卸载：双击 `uninstall-guard.cmd`

只想观察、不真动手：

```powershell
powershell -ExecutionPolicy Bypass -File audio-guard.ps1 -DryRun -RunSeconds 300
```

## 守护怎么判断「该修了」

两个信号：

1. **掉线恢复** —— 音频端点从「不在场」变回 ACTIVE。这个最可靠，掉线恢复后重置一次引擎本来就是想要的结果。
2. **建流失败（近似）** —— Windows 的 `PlaybackManager` 日志里出现「短命音频流」（流启动后 5 秒内就停止），且 120 秒内出现 5 次。

> ⚠️ 第二个信号是**近似的**。快速连续切歌、拖动进度条、暂停后恢复、切换输出设备、系统通知音，都可能形成同样的模式，所以阈值放得很宽。误触发的代价只是多重启一次音频服务（约 1 到 2 秒没声音）。

复位分两级，尽量少打扰：

1. 端点**不是** ACTIVE 时，先只重启这一个 USB 设备（`pnputil /restart-device`，影响最小）
2. 端点**已经**是 ACTIVE（引擎层卡死，设备级重启注定无效），或者第 1 级没救回来，才重启 `Audiosrv`

限流：两次复位至少隔 60 秒，一小时内最多 3 次。

## 依赖与前提

- Windows 10 / 11
- 需要管理员权限（重启服务、重启设备都要）
- 脚本按 USB VID/PID `2FC6:F06A` 定位设备 —— **换成别的 USB DAC 需要改这个 ID**

## 日志

- `fix-audio.log` —— 手动版的记录
- `audio-guard.log` —— 守护版的记录（复位、跳过、限流都写在这里）

## 已知局限

- 守护版**尚未在真实故障下验证过**，作者环境里只跑过 `-DryRun`
- 「短命流」信号无法区分正常切歌和真正的建流失败
- 它只处理「设备在线但引擎卡死」，**不解决接触不良本身** —— 那是硬件问题，换线、换口、换接口才是正解

## License

MIT
