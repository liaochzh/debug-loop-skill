# Maestro 流程片段（可复制）

> **何时必读**：需要写 `maestro/flow.sh` 的 YAML、或想把「等动画 → 点击 → 断言」一次跑完时。
> `flow.sh <flow.yaml>` 会**自动注入 `appId` 头**（见 `scripts/maestro/_common.sh` 的 `prepare_flow`）。

## 写片段的三条硬约束

1. **片段首行不要写 `appId:`** —— 由 `flow.sh` 从 `.debug.env`（`ANDROID_APP_ID` / `IOS_BUNDLE_ID`）自动注入；只有需要显式指定别的包名时才自带。
2. **不要以 `---` 开头** —— 注入的头部自带 `appId: …\n---\n`，重复分隔符会解析异常。
3. 片段保存成 `.yaml` 后整文件交给 `flow.sh`，不要逐条拆成 `tap.sh` 调用（每次调用都是一次 JVM 冷启动，真机可达 60~180s）。

## 片段 ①：整流程冒烟 / 冷启动（含 `launchApp`）

> ⚠️ **适用边界**：`launchApp` 会重启 App 并清掉当前页面状态。**只用于冷启动冒烟或整流程回归**；
> 复现「某个已有页面上的操作」必须用片段 ②，否则会把「状态丢失导致未复现」误判成「缺陷不存在」。

```yaml
# cold-start-smoke.yaml
- launchApp:
    clearState: false
- waitForAnimationToEnd:
    timeout: 5000
- tapOn: "目标按钮文案"
- waitForAnimationToEnd:
    timeout: 5000
- assertVisible: "成功页面标题"
```

`waitForAnimationToEnd` 的 `timeout` 是**最长等待**，**超时仍算成功**（官方语义：命令只是「等到静止或超时」就继续，不会因此失败）。
⇒ 只能当**等待**用，**不能当断言**用。要断言「动画确实结束了」，用 `assertVisible` 轮询目标元素，或改用 `settle.sh` 判定两帧一致。

## 片段 ②：复现既有页面状态（无 `launchApp`）

没有 Maestro 可用（或不需要跨端 YAML）时，shell 等价序列：

```bash
# 前提：App 已在前台，页面状态就是要复现的那个
bash <S>/scripts/android/settle.sh              # 等页面静止（语义树不可用会自动降级整屏像素）
bash <S>/scripts/maestro/tap.sh "目标按钮"        # 或 android/findtap.sh "目标"（需滚动查找时）
bash <S>/scripts/android/settle.sh              # 等跳转动画结束
bash <S>/scripts/maestro/assert.sh "成功页面标题"  # 或 android/shot.sh 后人工 Read 确认
```

**为什么每次都 settle**：`shot.sh` / `ui.sh` / 断言紧跟在动画中间帧执行时，会拿到过渡态（白屏、半透明、节点列表不全），把「还没画完」误判成「页面错乱」。

## 失败怎么回退

- 停在 `Tap on …` / `Assert …`（如 `Element not found`）⇒ **真·流程失败**：先 `shot.sh` + `Read` 看真实页面，再降级 `ui.sh` / Vision，**不得盲点**。
- 停在启动信息或 `Selected device … port …` 后无输出 ⇒ **被外层超时杀掉**，不是流程失败：先 `adb -s <设备> forward --remove-all` 清残留，改用 `bg.sh` 后台模式（或超时 ≥180s）重试。

## 版本说明

`waitForAnimationToEnd` 的超时语义以本机 `maestro --version` 对应的官方文档为准（本文按 2026-10 文档记录：超时不视为失败）。
无论该语义如何变化，「只当等待、不当断言」的用法都安全。
