# schema.py — JSON 归一化 + 校验
from typing import Dict, Any, List, Optional
import logging

logger = logging.getLogger("vision_read.schema")

class VisionResponseError(Exception):
    """响应校验失败"""
    pass

REQUIRED_TOP = ["screen", "elements", "ocr_text", "visual_issues"]
VALID_STATES = {"normal", "empty", "loading", "error", "white_screen", "obscured", "misaligned"}
VALID_TYPES = {"text", "button", "input", "image", "icon", "error", "toast", "dialog", "tab", "list_item", "other"}
VALID_ELEMENT_STATES = {"enabled", "disabled", "selected", "pressed", "loading"}

def clamp_bbox(bbox: List[int], max_w: int, max_h: int) -> List[int]:
    """钳制 bbox 到图内"""
    x1, y1, x2, y2 = bbox
    x1 = max(0, min(x1, max_w - 1))
    y1 = max(0, min(y1, max_h - 1))
    x2 = max(1, min(x2, max_w))
    y2 = max(1, min(y2, max_h))
    if x1 >= x2: x2 = min(x1 + 1, max_w)
    if y1 >= y2: y2 = min(y1 + 1, max_h)
    return [x1, y1, x2, y2]

def normalize_element(elem: Dict[str, Any], max_w: int, max_h: int, img_data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """归一化单个元素"""
    # type
    t = elem.get("type", "other")
    if t not in VALID_TYPES:
        logger.warning(f"未知 element type: {t}，归为 other")
        t = "other"

    # text
    text = elem.get("text", "")
    if not isinstance(text, str):
        text = str(text)

    # bbox
    bbox = elem.get("bbox")
    if not bbox or not isinstance(bbox, (list, tuple)) or len(bbox) != 4:
        logger.warning(f"bbox 缺失或格式错误: {bbox}，使用全图")
        bbox = [0, 0, max_w, max_h]
    else:
        bbox = [int(x) for x in bbox]
        # 先映射回原图坐标系（若提供了 img_data）
        if img_data:
            from preprocess import map_bbox_to_original
            bbox = map_bbox_to_original(bbox, img_data)
        bbox = clamp_bbox(bbox, max_w, max_h)

    # confidence
    conf = elem.get("confidence", 0.0)
    try:
        conf = float(conf)
    except Exception:
        conf = 0.0
    conf = max(0.0, min(1.0, conf))
    if conf == 0.0:
        logger.warning(f"元素 confidence 缺失或为 0: {text}")

    # state
    state = elem.get("state", "enabled")
    if state not in VALID_ELEMENT_STATES:
        state = "enabled"

    return {
        "type": t,
        "text": text,
        "bbox": bbox,
        "confidence": conf,
        "state": state,
    }

def normalize_screen(screen: Dict[str, Any]) -> Dict[str, Any]:
    """归一化 screen"""
    desc = screen.get("description", "未知页面")
    if not isinstance(desc, str):
        desc = str(desc)

    state = screen.get("state", "normal")
    if state not in VALID_STATES:
        logger.warning(f"未知 screen state: {state}，归为 normal")
        state = "normal"

    return {"description": desc, "state": state}

def normalize_visual_diff(diff: Dict[str, Any], max_w: int, max_h: int, img_data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """归一化 visual_diff"""
    def norm_list(lst):
        return [normalize_element(e, max_w, max_h, img_data) for e in lst] if lst else []

    return {
        "added": norm_list(diff.get("added")),
        "removed": norm_list(diff.get("removed")),
        "changed": norm_list(diff.get("changed")),
    }

def normalize_response(
    raw_response: Dict[str, Any],
    task: str,
    img_data: Dict[str, Any],
    region: Optional[list],
) -> Dict[str, Any]:
    """
    归一化模型原始响应
    - 补全缺失字段
    - 校验类型/枚举
    - bbox 映射回原图坐标系（基于 img_data 的 scale/crop_offset）
    """
    max_w, max_h = img_data["original_size"]

    # 1. 必填顶层字段
    for k in REQUIRED_TOP:
        if k not in raw_response:
            raw_response[k] = [] if k != "screen" else {}

    # 2. screen
    raw_response["screen"] = normalize_screen(raw_response.get("screen", {}))

    # 3. elements
    elements = raw_response.get("elements", [])
    if not isinstance(elements, list):
        elements = []
    raw_response["elements"] = [normalize_element(e, max_w, max_h, img_data) for e in elements]

    # 4. ocr_text
    ocr = raw_response.get("ocr_text", [])
    if isinstance(ocr, str):
        ocr = [ocr]
    elif not isinstance(ocr, list):
        ocr = []
    raw_response["ocr_text"] = [str(x) for x in ocr]

    # 5. visual_issues
    issues = raw_response.get("visual_issues", [])
    if isinstance(issues, str):
        issues = [issues]
    elif not isinstance(issues, list):
        issues = []
    raw_response["visual_issues"] = [str(x) for x in issues]

    # 6. compare task: visual_diff
    if task == "compare":
        diff = raw_response.get("visual_diff", {})
        if not isinstance(diff, dict):
            diff = {}
        raw_response["visual_diff"] = normalize_visual_diff(diff, max_w, max_h, img_data)

    # 7. 最终校验：确保所有 bbox 在范围内
    for elem in raw_response["elements"]:
        elem["bbox"] = clamp_bbox(elem["bbox"], max_w, max_h)
    if task == "compare":
        for key in ["added", "removed", "changed"]:
            for elem in raw_response["visual_diff"][key]:
                elem["bbox"] = clamp_bbox(elem["bbox"], max_w, max_h)

    return raw_response


# ===== 单元测试 =====
def _test_normalize():
    """内部自测：happy path + 3 种异常 + 坐标映射"""
    orig = (1080, 1920)
    # 模拟无裁剪、缩放 0.5 的 img_data
    img_data_no_crop = {
        "original_size": orig,
        "processed_size": (540, 960),
        "scale_x": 0.5,
        "scale_y": 0.5,
        "crop_offset": (0, 0),
    }
    # 模拟裁剪 [100,200,500,800] + 缩放 0.5 的 img_data
    img_data_crop = {
        "original_size": orig,
        "processed_size": (200, 300),
        "scale_x": 0.5,
        "scale_y": 0.5,
        "crop_offset": (100, 200),
    }

    # Happy path: 无裁剪，模型返回处理后图坐标 [50,100,150,140] -> 映射回原图 [100,200,300,280]
    raw = {
        "screen": {"description": "首页", "state": "normal"},
        "elements": [{"type": "button", "text": "登录", "bbox": [50, 100, 150, 140], "confidence": 0.95}],
        "ocr_text": ["登录", "注册"],
        "visual_issues": [],
    }
    out = normalize_response(raw, "ui_analysis", img_data_no_crop, None)
    assert out["screen"]["state"] == "normal"
    assert out["elements"][0]["bbox"] == [100, 200, 300, 280], f"实际: {out['elements'][0]['bbox']}"
    assert out["elements"][0]["confidence"] == 0.95
    print("✅ happy path (无裁剪，坐标映射 2x)")

    # 坐标映射测试：裁剪 + 缩放
    raw_mapped = {
        "screen": {},
        "elements": [{"type": "button", "text": "目标", "bbox": [50, 50, 150, 150], "confidence": 0.9}],
        "ocr_text": [],
        "visual_issues": [],
    }
    out_mapped = normalize_response(raw_mapped, "ui_analysis", img_data_crop, None)
    # processed [50,50,150,150] -> /0.5 = [100,100,300,300] -> +crop(100,200) = [200,300,400,500]
    assert out_mapped["elements"][0]["bbox"] == [200, 300, 400, 500], f"实际: {out_mapped['elements'][0]['bbox']}"
    print("✅ 坐标映射 (裁剪+缩放)")

    # 异常 1: bbox 越界
    raw2 = {"screen": {}, "elements": [{"type": "button", "text": "x", "bbox": [-10, -10, 2000, 3000], "confidence": 0.9}], "ocr_text": [], "visual_issues": []}
    out2 = normalize_response(raw2, "ui_analysis", img_data_no_crop, None)
    assert out2["elements"][0]["bbox"] == [0, 0, 1080, 1920]
    print("✅ bbox 越界钳制")

    # 异常 2: confidence 缺失
    raw3 = {"screen": {}, "elements": [{"type": "text", "text": "hello", "bbox": [10, 10, 100, 50]}], "ocr_text": [], "visual_issues": []}
    out3 = normalize_response(raw3, "ui_analysis", img_data_no_crop, None)
    assert out3["elements"][0]["confidence"] == 0.0
    print("✅ confidence 缺失默认 0.0")

    # 异常 3: 模型回自然语言（非 JSON 会在 client.py 报错，这里模拟缺字段）
    raw4 = {"screen": {}, "elements": [], "ocr_text": "这是一段文本不是数组", "visual_issues": "这是字符串不是数组"}
    out4 = normalize_response(raw4, "ui_analysis", img_data_no_crop, None)
    assert out4["ocr_text"] == ["这是一段文本不是数组"]
    assert out4["visual_issues"] == ["这是字符串不是数组"]
    print("✅ 非数组字段强制转列表")

    print("所有单测通过")

if __name__ == "__main__":
    _test_normalize()