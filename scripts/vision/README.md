# Vision Tool — `vision_read.py`

按需调用的视觉分析工具，供 DeepSeek Debug Agent 使用。

## 安装依赖
```bash
cd ~/.config/opencode/skills/debug-loop/scripts/vision
pip install -r requirements.txt
```

## 环境变量
| 变量 | 说明 | 默认 |
|------|------|------|
| `VISION_API_KEY` / `OPENAI_API_KEY` | 百炼 Token Plan Key | 可选（见下方「配置方式」） |
| `VISION_BASE_URL` | 百炼兼容模式端点 | `https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1` |
| `VISION_MODEL` | 视觉模型名 | `qwen3.8-flash` |
| `VISION_LOG_LEVEL` | 日志级别 | `INFO` |

## API Key 配置方式（三选一，优先级从高到低）

1. **CLI 参数**：`python vision_read.py --image ... --api-key <KEY>`（临时覆盖，适合 CI/脚本）
2. **环境变量**：`export VISION_API_KEY=<KEY>` 或 `export OPENAI_API_KEY=<KEY>`（全局）
3. **`.debug.env`**：在项目根的 `.debug.env` 中写 `VISION_API_KEY="<KEY>"`（init.sh 生成的模板已包含该键，留空即可）—— vision_read.py 会自动读取当前目录的 `.debug.env`

未配置时 vision_read.py 以 exit 3 失败并提示配置方式。

## 调用示例

```bash
# UI 全量分析
python vision_read.py --image /path/to/screen.png --task ui_analysis --question "当前页面有无网络错误？"

# 仅 OCR
python vision_read.py --image /path/to/screen.png --task ocr

# 定向找元素（带裁剪区域，加速+省 token）
python vision_read.py --image /path/to/screen.png --task find_element --question "添加设备按钮" --region 0,1800,1170,2532

# 视觉回归对比
python vision_read.py --image /path/to/current.png --task compare --compare-image /path/to/baseline.png

# 错误页面分析
python vision_read.py --image /path/to/screen.png --task error_analysis
```

## 参数
| 参数 | 必填 | 说明 |
|------|------|------|
| `--image` | 是 | 截图绝对路径 |
| `--task` | 是 | `ui_analysis` / `ocr` / `find_element` / `compare` / `error_analysis` |
| `--question` | 否 | 定向问题，建议提供 |
| `--region` | 否 | 裁剪区域 `x1,y1,x2,y2`（原图像素） |
| `--compare-image` | compare 时是 | 基准图路径 |
| `--no-cache` | 否 | 跳过缓存 |

## 返回值（结构化 JSON）

```json
{
  "screen": {
    "description": "摄像头设备列表页面",
    "state": "empty"
  },
  "elements": [
    {
      "type": "button",
      "text": "添加设备",
      "bbox": [430, 1450, 740, 1530],
      "confidence": 0.98,
      "state": "enabled"
    }
  ],
  "ocr_text": ["摄像头", "添加设备", "网络连接失败"],
  "visual_issues": ["设备列表为空"],
  "cached": false
}
```

`compare` task 额外返回：
```json
{
  "visual_diff": {
    "added": [{"type": "toast", "text": "网络错误", "bbox": [...], "confidence": 0.9}],
    "removed": [],
    "changed": []
  }
}
```

## 坐标系说明
- `bbox` = `[x1, y1, x2, y2]` **原图 PNG 像素坐标**，左上角为原点 (0,0)
- 直接可用于 `tap.sh x y`：中心点 `x = (x1+x2)/2, y = (y1+y2)/2`
- `--region` 裁剪不影响 bbox 输出（内部自动映射回原图）

## 缓存机制
- 缓存目录：`~/.cache/opencode-vision/`
- Key = `SHA256(主图字节 + task + question + region + 对比图字节 + model名)`
- **同一路径新截图 → 文件字节变 → Key 变 → 自动失效**
- 命中时返回 `cached: true`，不产生 API 调用

## 成本预估
- 单次 `ui_analysis`：约 200-500 input tokens（取决于图片复杂度）
- 缓存命中：0 成本
- 日常调试缓存命中率预期 30-50%

## 退出码
| 码 | 含义 |
|----|------|
| 0 | 成功 |
| 2 | 参数/文件错误 |
| 3 | API/网络错误（Agent 应回退 `ui.sh + logs.sh`） |
| 4 | JSON 校验失败（模型未按 schema 返回） |

## 集成到 Debug Agent
1. `autoDebug` 调用 `shot.sh` 得到 `build/debug/screen.png`
2. 先跑 `ui.sh`，命中元素直接 `tap.sh`
3. 未命中/需视觉判断时：`python vision/vision_read.py --image build/debug/screen.png --task ui_analysis --question "..."`
4. 取 `elements[].bbox` 中心点 → `tap.sh x y`
5. Vision 失败（exit 3）→ 回退 `ui.sh + logs.sh` 组合判断