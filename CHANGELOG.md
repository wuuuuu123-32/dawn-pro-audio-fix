# 更新日志

本文件由 release.mjs 维护。

## v1.0.0 — 2026-10-20

- 手动版 fix-audio.cmd：双击修好「设备在线但不出声」，含 -CheckOnly / -Full
- 守护版 audio-guard.ps1：主判据改为静置刷新，能覆盖「零事件」静默卡死
- guard-task.ps1：注册计划任务时关闭 StopOnIdleEnd，避免守护被系统随时杀掉
- 判据不用 CPU（audiodg 空闲也在吃 CPU），改用 PlaybackManager 流状态
