# preprocess.py — 图片预处理：裁剪、等比缩放、base64 编码
from PIL import Image
import base64
import io
from typing import Dict, Any, Optional, List

MAX_DIM = 1568  # 长边上限，避免 token 过多

def preprocess_image(image_path: str, region: Optional[List[int]] = None) -> Dict[str, Any]:
    """
    返回:
    {
        "base64": str,           # JPEG base64
        "original_size": (w, h), # 原图尺寸
        "processed_size": (w, h),# 送模型尺寸
        "scale_x": float,        # 原图->处理图 x 缩放
        "scale_y": float,        # 原图->处理图 y 缩放
        "crop_offset": (x, y),   # 裁剪偏移（原图坐标）
    }
    """
    with Image.open(image_path) as img:
        original_w, original_h = img.size
        crop_offset = (0, 0)

        # 1. 裁剪
        if region:
            x1, y1, x2, y2 = region
            # 钳制到图内
            x1 = max(0, min(x1, original_w - 1))
            y1 = max(0, min(y1, original_h - 1))
            x2 = max(x1 + 1, min(x2, original_w))
            y2 = max(y1 + 1, min(y2, original_h))
            img = img.crop((x1, y1, x2, y2))
            crop_offset = (x1, y1)

        crop_w, crop_h = img.size

        # 2. 等比缩放（长边 <= MAX_DIM）
        scale = 1.0
        if max(crop_w, crop_h) > MAX_DIM:
            scale = MAX_DIM / max(crop_w, crop_h)
            new_w = int(crop_w * scale)
            new_h = int(crop_h * scale)
            img = img.resize((new_w, new_h), Image.Resampling.LANCZOS)

        processed_w, processed_h = img.size

        # 3. 转 RGB + JPEG base64
        if img.mode != "RGB":
            img = img.convert("RGB")
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=85)
        b64 = base64.b64encode(buf.getvalue()).decode("ascii")

    return {
        "base64": b64,
        "original_size": (original_w, original_h),
        "processed_size": (processed_w, processed_h),
        "scale_x": scale,
        "scale_y": scale,
        "crop_offset": crop_offset,
    }

def map_bbox_to_original(bbox: List[int], prep: Dict[str, Any]) -> List[int]:
    """
    将模型返回的 bbox（基于 processed 图）映射回原图坐标系
    bbox: [x1, y1, x2, y2] in processed image coords
    """
    x1, y1, x2, y2 = bbox
    crop_x, crop_y = prep["crop_offset"]
    scale_x = prep["scale_x"]
    scale_y = prep["scale_y"]

    # 先缩放回裁剪图坐标
    x1 = int(x1 / scale_x)
    y1 = int(y1 / scale_y)
    x2 = int(x2 / scale_x)
    y2 = int(y2 / scale_y)

    # 再加上裁剪偏移
    x1 += crop_x
    y1 += crop_y
    x2 += crop_x
    y2 += crop_y

    # 钳制到原图范围
    orig_w, orig_h = prep["original_size"]
    x1 = max(0, min(x1, orig_w - 1))
    y1 = max(0, min(y1, orig_h - 1))
    x2 = max(1, min(x2, orig_w))
    y2 = max(1, min(y2, orig_h))

    if x1 >= x2: x2 = x1 + 1
    if y1 >= y2: y2 = y1 + 1

    return [x1, y1, x2, y2]