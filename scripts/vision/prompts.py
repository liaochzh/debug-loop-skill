# prompts.py — 5 种 task 的 system/user 模板 + JSON 强制约束
from typing import Optional, List, Dict, Any

# 通用 JSON 格式约束
JSON_SCHEMA_INSTRUCTION = """
必须严格输出 JSON，不得包含任何额外文本、Markdown 代码块或解释。
JSON 结构：
{
  "screen": {
    "description": "string",  // 页面整体描述
    "state": "string"         // 页面状态：normal/empty/loading/error/white_screen/obscured/misaligned
  },
  "elements": [               // 识别到的 UI 元素
    {
      "type": "string",       // text/button/input/image/icon/error/toast/dialog/tab/list_item/other
      "text": "string",       // 可见文本（OCR 或 content-desc）
      "bbox": [int, int, int, int], // [x1, y1, x2, y2] 像素坐标，基于输入图片
      "confidence": 0.0,      // 0.0-1.0，识别置信度
      "state": "string"       // 可选：enabled/disabled/selected/pressed/loading
    }
  ],
  "ocr_text": ["string"],     // 全图 OCR 文本行列表
  "visual_issues": ["string"] // 视觉异常：遮挡/错位/缺图/白屏/文案异常等
}
"""

# compare task 额外字段
COMPARE_EXTRA = """
compare task 额外返回：
  "visual_diff": {
    "added": [{"type": "...", "text": "...", "bbox": [...], "confidence": 0.0}],
    "removed": [{"type": "...", "text": "...", "bbox": [...], "confidence": 0.0}],
    "changed": [{"type": "...", "text": "...", "bbox": [...], "confidence": 0.0, "from": "...", "to": "..."}]
  }
"""

SYSTEM_PROMPTS = {
    "ui_analysis": f"""你是一个 UI 视觉分析器。输入一张移动端/桌面端应用截图，输出结构化 JSON。
任务：全面分析页面 UI 状态、元素、文本、视觉异常。
{JSON_SCHEMA_INSTRUCTION}
- bbox 必须为输入图片像素坐标 [x1,y1,x2,y2]，左上角为原点
- confidence 必须填写，未知元素不得编造
- state 枚举：normal/empty/loading/error/white_screen/obscured/misaligned
- type 枚举：text/button/input/image/icon/error/toast/dialog/tab/list_item/other
""",

    "ocr": f"""你是一个 OCR 识别器。输入一张截图，提取所有可见文本。
{JSON_SCHEMA_INSTRUCTION}
- elements 只包含 type="text" 的项
- bbox 紧贴文本边界
- ocr_text 包含所有识别到的文本行
""",

    "find_element": f"""你是一个 UI 元素定位器。输入截图和目标描述，定位指定元素。
{JSON_SCHEMA_INSTRUCTION}
- 只返回匹配目标的元素（elements 通常 1 个）
- 若未找到，elements 为空数组，visual_issues 增加 "未找到目标元素"
- confidence < 0.7 时标注为低置信度
""",

    "compare": f"""你是一个视觉回归对比器。输入两张截图（基准图、当前图），输出差异。
{JSON_SCHEMA_INSTRUCTION}
{COMPARE_EXTRA}
- 先分别分析两图，再输出 visual_diff
- added/removed/changed 的 bbox 基于当前图坐标
""",

    "error_analysis": f"""你是一个错误页面分析器。输入截图，专门识别错误/异常状态。
{JSON_SCHEMA_INSTRUCTION}
- 重点关注：toast、dialog、snackbar、红色文案、堆栈、空状态、网络错误图标
- state 优先判断为 error/empty/loading
- visual_issues 详细列出每个异常点
""",
}

def build_messages(
    task: str,
    image_base64: str,
    question: Optional[str] = None,
    compare_base64: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """构建 OpenAI 兼容 messages"""
    system = SYSTEM_PROMPTS.get(task, SYSTEM_PROMPTS["ui_analysis"])

    # user 内容
    user_content = []

    # question 注入
    if question:
        user_content.append({
            "type": "text",
            "text": f"问题：{question}\n请结合问题重点分析。"
        })

    # 主图
    user_content.append({
        "type": "image_url",
        "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}
    })

    # 对比图
    if compare_base64:
        user_content.append({
            "type": "text",
            "text": "以下是基准图（期望状态）："
        })
        user_content.append({
            "type": "image_url",
            "image_url": {"url": f"data:image/jpeg;base64,{compare_base64}"}
        })

    return [
        {"role": "system", "content": system},
        {"role": "user", "content": user_content},
    ]