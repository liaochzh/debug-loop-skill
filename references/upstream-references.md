# 上游参考与取舍记录（2026-10-27 调研）

> 用途：说明本 skill 的哪些设计**借鉴自外部开源 skill/工具**、哪些**明确不采纳**及原因。
> 维护：再次调研时先看本表，避免重复评估同一来源；新采纳项请补一行并注明落点。

## 调研对象

| 来源 | 形态 | 关键做法 |
|---|---|---|
| `callstack/agent-device`（`skills/agent-device`、`skills/android-emulator`、`skills/ios-simulator`、`skills/dogfood`） | CLI + MCP + 4 个 open skill | 启动经济（禁止 `--help`/`devices` 探路）；`--settle` 后再断言；`scroll --until <selector>`；错误输出带纠正提示；dogfood 每条问题附证据 |
| `getsentry/MobileBuildMCP`（XcodeBuildMCP 后继） | MCP + CLI + 可选 skill | `doctor` 式环境自检；CLI/MCP 双形态共用执行路径；按 workspace 常驻 daemon 管状态 |
| `mobile-next/mobile-mcp` | MCP server | 无障碍树优先、截图兜底；结构化输出优于纯视觉；设备/应用管理命令分组 |
| `aiopshwang/ship-mobile-app` | 纯 SKILL.md + references | 五类「真值边界」；证据分层（源码/测试/产物/真机）；主张不得超出观测；重试无新证据时先分类失败边界 |
| `anthropics/skills` → `skills/skill-creator` | 官方 skill 编写规范 | SKILL.md < 500 行；深度内容下沉 `references/`（按需加载）；评估用例带 `evidence` 字段 |
| `anthropics/skills` 其余 | — | **无**移动端调试类 skill（该目录只有 docx/pdf/webapp-testing 等），无可直接对标项 |

## 已采纳 → 落点

| 采纳项 | 落点 |
|---|---|
| `doctor` 一次自检，分级 ✅/⚠️/❌ | `scripts/doctor.sh`；`SKILL.md` 前置检查第 3 步；`test_common.sh` G11 |
| `--settle`（动画收敛后再取证） | `scripts/android/settle.sh`；UI 优先级第 4 条；命令表 |
| `scroll --until`（滑动查找） | `scripts/android/findtap.sh`（另加「文本节点非 clickable 时中心兜底点击」） |
| 启动经济 / 不要反复探测 | `SKILL.md` 执行约定「启动经济」 |
| 错误提示即下一手依据 | `SKILL.md` 执行约定「`💡` 提示优先于自行重规划」 |
| 依赖安装归用户（不可变版本自举） | `SKILL.md` 执行约定最后一条 |
| 证据分层 + 主张映射 | `SKILL.md`「证据与主张（回报口径）」；`references/autoDebug-task-template.md` 回报要求 |
| 失败边界分类（先分类再改码） | `SKILL.md`「先分类再改码」表；`references/autoDebug-task-template.md` 失败处理 |
| 故障速查（避免重复踩坑） | 新增 `references/troubleshooting.md`（A–G 七类） |
| SKILL.md 控制在 500 行内、深内容下沉 | SKILL.md 412 行；troubleshooting / autoDebug 模板独立成文 |

## 明确不采纳

| 候选 | 不采纳原因 |
|---|---|
| 改成 MCP server + 工具面 | 本 skill 面向 opencode subagent 的 **shell 白名单**模型；MCP 需额外常驻进程与配置，且现有脚本已覆盖同等能力 |
| `@ref` 引用 + 快照 diff 模型 | 依赖 agent-device 自身的快照协议；我们靠 `settle.sh` + `ui.sh` + Maestro 已达同类效果 |
| 自建常驻 daemon 管日志 | 已有 `bg.sh` + `logwatch.sh`（按 PID 动态跟随，不吃孤儿进程） |
| 云端真机队列 | 单人本地调试场景不需要；引入会带来网络与凭据面 |
| Agent 自行安装/升级工具 | 明确要求交回用户（权限与供应链风险） |

## 重新调研时的入口

- agent-device skill 目录：`callstack/agent-device` → `skills/{agent-device,android-emulator,ios-simulator,dogfood}/SKILL.md`
- MobileBuildMCP：`getsentry/MobileBuildMCP` → `README.md` + `docs/_content/{cli,skills,tools}.mdx`
- ship-mobile-app：`aiopshwang/ship-mobile-app` → `skills/ship-mobile-app/SKILL.md` + `references/`
- skill 编写规范：`anthropics/skills` → `skills/skill-creator/SKILL.md`（第 82–110 行的目录结构与 500 行建议）
