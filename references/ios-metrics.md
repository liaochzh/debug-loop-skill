# iOS 埋点内测包（INTERNAL_METRICS）

> 由 `SKILL.md` 抽出，内容原样保留；仅在需要注入内测埋点判据时读。

## 埋点内测包（INTERNAL_METRICS，iOS）

`<S>/scripts/ios/build_metrics.sh --pod <pod> --symbol <串> [--symbol …] [--control <串> …] [--mode profile|release] [--restore|--keep|--clear-pending|--force]`
把「给 Pods 的 `<pod>.release.xcconfig` 临时加 `INTERNAL_METRICS` → 构建 → `strings` 判据 → 还原 →
重编 → 判据归零」做成状态机（备份 + sha256 守卫、pending 标记、审计日志）。**只能在宿主机执行**
（沙箱内 rc=3），且需先 `pod install` 生成 xcconfig（该文件被 Profile/Release 共用、常被 gitignore）。

- **`--mode` 只接受 `profile`/`release`**：debug 走 `debug.xcconfig`，且 `#if DEBUG` 会让判据恒真 ⇒ 假阳性。
  `--mode release` 已于 2026-11-04 实测通过（开发签名；判据 1 → 0 归零）；它与 `profile` 走同一条状态机，
  区别只是 `flutter build` 的模式参数。⚠️ 产出是**开发签名**真机包，上架/分发（`flutter build ipa`）
  仍需分发描述文件，不在本脚本范围内。
- 判据示例：`--symbol P2PCameraOverlap --control 'ThingLogSDK.startLog done'`；对照串恒应 ≥1
  （证明 `strings` 通道没坏），`[P2PHeat]` 应恒 0。
- 中断/失败留 `<项目根>/build/debug/metrics/pending_restore` ⇒ 下次注入被拒，先 `--restore`；
  确认误报用 `--clear-pending`（仅当 xcconfig 已无标记）。`--keep` 只用于「故意留注入态」，必须手工收尾。
- **`[IPC] ThingLogSDK.startLog done` 的触发条件（runbook）**：唯一调用点是导出涂鸦日志
  （`IPCBusinessPlugin.swift` 的 `exportTuyaLogs`），入口只有「登录页长按 logo」与「初始化页按钮」
  ⇒ **已登录态够不到**，需先退出登录再触发；别把它误判成「日志通道坏了」。
