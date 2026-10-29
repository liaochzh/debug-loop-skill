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
bash <S>/scripts/maestro/assert.sh "成功页面标题"  # 断言不可用/失败时：先 assert_page.sh 或 snapshot.sh，exit 4 才 shot.sh
```

**为什么每次都 settle**：`shot.sh` / `ui.sh` / 断言紧跟在动画中间帧执行时，会拿到过渡态（白屏、半透明、节点列表不全），把「还没画完」误判成「页面错乱」。

### 变体：先取快照再点击（`tap_snapshot.sh`，省掉重复 dump）

已经为断言/摘要取过快照（`snapshot.sh`，≤60 s 内）时，点击可直接复用这份快照的 `bounds` 中心点，不必再 dump：

```bash
bash <S>/scripts/snapshot.sh --platform android    # 一次快照（同时落盘 build/debug/last_snapshot.json）
bash <S>/scripts/assert_page.sh --file docs/test/a.txt --platform android
bash <S>/scripts/tap_snapshot.sh "目标按钮" --platform android   # 命中缓存 <1 s，输出 ♻️ 复用快照 (age=Ns)
bash <S>/scripts/android/settle.sh
bash <S>/scripts/snapshot.sh --platform android --diff   # 变了什么？（基线自动取 prev，见下）
bash <S>/scripts/assert_page.sh --file docs/test/b.txt --platform android   # rc=0 只代表点击已送达，必须另断言
```

- 先 `--dry-run` 只算坐标不点：`tap_snapshot.sh "目标按钮" --dry-run`（输出 `命中 N 处…center=(x,y)`）。
- 多命中取第 N 个：`--index 2`；精确匹配（区分 `Add` / `Add device`）：`--exact`；只按资源 id：`--id`。
- 点击成功后 `last_snapshot.json` 会轮转为 `prev_snapshot.json`（页面已变；`prev` **只作 `--diff` 的基线，不作坐标来源**）；要连续点同一页多次加 `--keep-cache`。
- 目标不在当前屏 ⇒ 用 `findtap.sh`（自动滚动），本命令只点「当前快照里有的」节点。
- iOS 模拟器/真机不支持本命令（rc=3，会给出 `maestro/tap.sh` / `appium/driver.py find-click` 指引）。

#### `--diff` 怎么读（点击后判「变了什么」）

```
# diff baseline=prev(age=8s) fp=c4674058→6e362504 nodes=31: +1 -3 ~2 (text 2 / pos 0 / clickable 0)
+	Button	Settings	com.demo:id/settings	[901,298][1028,424]
-	View	Loading…		[0,0][1080,200]
-	View	Search home events by text or voice		[42,154][1038,291]
-	View	Daily care report		[42,343][1038,469]
~ text	View	08:30→08:31		[26,1507][210,1556]
~ text	Button	Offline→Online		[901,298][1028,424]
```

- `+` 新增 / `-` 消失 / `~ text|pos|clickable` 变化；header 计数是**截断前全量**（示例 6 项全列出；超过 `--max-diff` 时截断并补「另有 N 项」）。
- **`~ text` 只代表文本刷新**（时间戳/进度），不代表跳转；`+` 多 `-` 少通常是跳转后节点更多，不是「凭空新增」。
- 必须**点击 → `settle.sh` → `--diff`**：动画中间帧会刷出满屏 `~ pos`。
- 基线优先级 `--against <json>` > `last` > `prev`；隐式基线（`last`/`prev`）要求 `dialect` 与 `_meta.platform` 一致，不符 ⇒ rc=1 且**不降级**（跨平台/换方言请显式 `--against`，此时只 ⚠️ 仍输出）。
- 无基线时 rc=1，但本次快照已落盘 ⇒ 再跑一次 `--diff` 即可看变化；`--diff` 与 `--json` 互斥（rc=2）。

## 失败怎么回退

- 停在 `Tap on …` / `Assert …`（如 `Element not found`）⇒ **真·流程失败**：先 `snapshot.sh` 取摘要（含指纹）定位失败层，摘要为空（exit 4）才 `shot.sh`，再降级 `ui.sh` / Vision，**不得盲点**。
- 停在启动信息或 `Selected device … port …` 后无输出 ⇒ **被外层超时杀掉**，不是流程失败：先 `adb -s <设备> forward --remove-all` 清残留，改用 `bg.sh` 后台模式（或超时 ≥180s）重试。

## 版本说明

`waitForAnimationToEnd` 的超时语义以本机 `maestro --version` 对应的官方文档为准（本文按 2026-10 文档记录：超时不视为失败）。
无论该语义如何变化，「只当等待、不当断言」的用法都安全。
