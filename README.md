# dawn-pro-audio-fix

给 **MOONDROP Dawn Pro**（水月雨 USB DAC 小尾巴）在 Windows 上用的音频卡死修复工具。

## 它解决什么问题

这个 USB DAC 在两种情况下会出现同一个症状：**设备是连着的、系统里看得到、音量条也不一定是零，但就是不出声**（播放器进度条照走，网易云 / B 站直接卡住）。

1. **接口接触不良** —— Type-C 口松动，设备在系统里反复「掉线 → 回来」，几分钟内几十上百次。掉得够多之后，音频引擎的状态就被拖坏了。
2. **零掉线卡死** —— 设备一直没掉线、电脑也没睡眠，开机跑了十几个小时后，引擎自己卡死。

两种情况都能靠**重启 Windows 音频服务（`Audiosrv`）**立刻恢复 —— 这就是这个工具做的事。

## 三个工具，选一个

| | 用法 | 适合 |
|---|---|---|
| **热键版** `hotkey-fix.ps1` | 常驻监听，按 `Ctrl+Alt+Shift+A` 立刻修 | 想按一下就修，不想找图标（**推荐**） |
| **手动版** `fix-audio.cmd` | 双击 → UAC → 修完自动关 | 偶尔用一次，不想装常驻进程 |
| **守护版** `audio-guard.ps1` | 装成计划任务后开机自启 | 想让它自动修 |

### 热键版（推荐）

装好后常驻监听 **`Ctrl+Alt+Shift+A`**，按下立刻修，不用回桌面找图标。

```powershell
# 安装（需要管理员）
powershell -ExecutionPolicy Bypass -File _install-hotkey.ps1
```

**它会在重启服务之前先抓一份现场快照。** 这类故障在系统日志里一条记录都没有（2026-10-26 实测：故障前后 45 分钟，`Audio/Operational`、`PlaybackManager`、`Event 65` 全是 0 条），唯一的机会就是按下热键到服务重启之间那两三秒。

每次按热键都会往 `snapshot.log` 追加：

- 默认端点峰值（6 次采样，给最大值、平均值和逐个样本）
- 每个渲染会话的 `pid / 进程名 / state`（Inactive / Active / Expired）
- 每个采集会话（谁在用麦克风 —— 录音或会议时重启会打断）
- 键鼠空闲秒数
- `audiodg` 的 PID、启动时间、CPU
- 修复后再采一次，和故障态前后对照

攒几次就能看清「引擎坏死」到底长什么样。

实现上的几个点：

- 计划任务是「**仅用户登录时运行** + 最高权限 + 单实例」。必须在交互会话里，否则 `RegisterHotKey` 注册成功也不响应（它的「全局」范围是当前窗口站/桌面，不是跨会话）。
- 热键注册失败会弹一次 MessageBox —— 提权进程发 Toast 不可靠，只写日志你会以为它工作了。
- 5 秒冷却，执行期间不处理消息并丢弃积压，连按不会叠加。
- 卸载：

```powershell
Stop-ScheduledTask -TaskName DawnProAudioHotkey
Unregister-ScheduledTask -TaskName DawnProAudioHotkey -Confirm:$false
```

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

v1.1.0 的做法（只看 `PlaybackManager` 事件）有个致命缺陷：**它看不见「没声音」这件事本身**，用户整晚正常听歌时它仍每小时重启一次音频服务，等于工具自己在制造故障。v1.2.0 换了一套判据，起点是一条会审结论：

> **零峰值 ≠ 故障，非零峰值 ≠ 发声。**

只观察「输出量」永远同时存在漏修和误伤，必须引入独立的「应该正在输出」依据。

现在用两个**互相独立**的信号：

| 信号 | 怎么读 | 判断什么 |
|---|---|---|
| WASAPI 峰值 | `IAudioMeterInformation.GetPeakValue()`，90 秒滑窗内密采（每轮连采 5 次、间隔 200ms）取最大值 | 有没有数字音频在流 |
| 键鼠空闲 | `GetLastInputInfo` | 有没有人在用这台电脑 |

第二条是关键：**人不在，就一定没人在听**，这时重启绝对安全。

三条判据：

- **判据 A（强信号，覆盖「正在用时坏死」）**：`streaming=True`（确实收到过 Event 24）**且** 90 秒窗口峰值全 < `-SilenceThreshold` → 有播放意图 + 无音频输出 = 确定故障 → 重启（冷却 `-HardCooldownSeconds`，默认 120 秒）
- **判据 B（预防，覆盖「静置后首播失败」）**：键鼠空闲 ≥ `-IdleMinutes`（默认 30 分钟）**且** 90 秒窗口峰值全 < 阈值 → 没人在用、也没声音 → 重启安全（冷却 `-RefreshIntervalMinutes`，默认 60 分钟）
- **判据 C（兜底，绝不误伤）**：WASAPI 读不到（独占模式 / ASIO / 端点切换中 / 初始化失败）→ 视为**未知，不重启**，日志记 WARN。绝不降级回已被实测证伪的 `PlaybackManager` 判据。

另外保留两个旧信号：**短命流**（流启动后 5 秒内停止、120 秒内出现 5 次，辅助）、**掉线恢复**（端点从非 ACTIVE 变回 ACTIVE，补偿）。

### 为什么不再拿「静置 30 分钟没流事件」当主判据

`PlaybackManager` 这个事件通道极不可靠：`EventData` 全空、很多播放器根本不发。实测用户整晚正常听歌，它仍然认为「无流」，于是每小时误重启一次，每次打断约 1 秒 —— 2026-10-22 晚上用户多次察觉「突然没声音一秒左右又恢复」，就是这个。现在它只作为判据 A 的「播放意图」依据，不单独决策。

### 运行身份：必须是当前用户，不能是 SYSTEM

WASAPI 在 SYSTEM 会话（Session 0）里访问不到用户会话的音频设备图，`GetPeakValue` 会一直失败。所以计划任务改成「当前用户 + 最高权限 + 交互登录」，由**登录时触发**（`-AtLogOn`，延迟 30 秒）。

代价：**必须有人登录着才跑**（注销后不跑）；RDP 断开时端点可能重定向；快速用户切换期间可能停在旧会话。对「一台人天天用的笔记本」可以接受。日志里那行「探针自检：默认端点峰值=…」就是用来确认这条通路是通的。

### 已知局限（会审列出的反例，权衡后接受）

- 播客 / 有声书有超过 90 秒的静音段，若此时人也不在，会被判据 B 刷一次（无人在听，无感；理论上重启可能销毁仍被播放器持有的音频客户端）
- 其他应用持续发声会掩盖目标播放器坏死 → 判据 A 不触发（**漏修**）
- 独占 / ASIO / Kernel Streaming 绕过软件峰值表 → 一直读 0，判据 A 不触发（**漏修**），这类请用手动版
- 判据 A 依赖 `PlaybackManager` 的 Event 24，播放器不发就退化成只靠判据 B

复位分两级，尽量少打扰：

1. 端点**不是** ACTIVE 时，先只重启这一个 USB 设备（`pnputil /restart-device`，影响最小）
2. 端点**已经**是 ACTIVE（引擎层卡死，设备级重启注定无效），或者第 1 级没救回来，才重启 `Audiosrv`

限流：两次复位至少隔 60 秒；判据 A/B 各自另有更长的冷却；一小时内最多 4 次。

## 装计划任务时的一个坑（重要）

用 `Register-ScheduledTask` 装守护时，**必须**显式关掉任务计划的一个默认设置：

```powershell
$settings = New-ScheduledTaskSettingsSet -DontStopOnIdleEnd   # 对应 XML 里的 <StopOnIdleEnd>false</StopOnIdleEnd>
```

默认值是 `StopOnIdleEnd = true`，意思是**计算机一旦结束空闲状态（你一碰鼠标键盘），这个任务就被系统停掉**。

踩过的现场：守护每次启动活不过几秒、日志里什么都不留、看起来像「脚本自己崩了」——其实不是崩，是被调度器杀的。`guard-task.ps1` 里已经加上这个参数了；如果你自己改注册脚本，别忘了它。

## 改完代码必须重启守护进程（第二个坑）

计划任务指向的是 `audio-guard.ps1` 的**路径**，但 PowerShell 是**启动那一刻把脚本整个读进内存**的。所以你改完文件、任务状态照样显示 `Running`，实际跑的还是旧代码，日志里也看不出任何异常 —— 2026-10-21 修 bug 时就撞上过：任务重装成功、PID 却是 10:36 那个旧的。

正确做法是杀掉旧进程再启动任务：

```powershell
Stop-Process -Id <旧 PID> -Force
Start-ScheduledTask -TaskName DawnProAudioGuard
```

`guard-task.ps1 -Action install` 内部会处理这件事（它注册完会尝试清理同名进程），但 SYSTEM 身份的进程需要管理员权限才杀得掉，所以如果你不是用管理员跑的它，回头记得自己确认一下新进程的 `CreationDate` 是不是刚才。

## 依赖与前提

- Windows 10 / 11
- 需要管理员权限（重启服务、重启设备都要）
- 脚本按 USB VID/PID `2FC6:F06A` 定位设备 —— **换成别的 USB DAC 需要改这个 ID**

## 日志

- `fix-audio.log` —— 手动版的记录
- `audio-guard.log` —— 守护版的记录（复位、跳过、限流都写在这里）

## 已知局限

- 守护版只在作者这一台笔记本 + 一块 Dawn Pro 上验证过，**没有在其他机器上跑过长期测试**
- 「短命流」信号无法区分正常切歌和真正的建流失败
- 多应用同时播放时，静置判据可能误判（见上文「已知局限」），代价是多重启一次
- 它只处理「设备在线但引擎卡死」，**不解决接触不良本身** —— 那是硬件问题，换线、换口、换接口才是正解

## License

MIT
