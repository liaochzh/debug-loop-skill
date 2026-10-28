#!/usr/bin/env python3
# vision_read.py — Vision Tool CLI 入口
# 用法: python vision_read.py --image <path> --task <task> [--question "..."] [--region x1,y1,x2,y2] [--compare-image <path>] [--no-cache]
import argparse
import sys
import os
import json
import logging

# 添加当前目录到路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from preprocess import preprocess_image, map_bbox_to_original
from cache import get_cache, set_cache, make_cache_key
from client import call_vision_api, VISION_MODEL, VisionAPIError, VisionSchemaError
from schema import normalize_response, VisionResponseError
from prompts import build_messages

# 配置日志
log_level = os.environ.get("VISION_LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, log_level, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stderr
)
logger = logging.getLogger("vision_read")

TASKS = ["ui_analysis", "ocr", "find_element", "compare", "error_analysis"]

def parse_region(region_str: str):
    """解析 region 字符串 x1,y1,x2,y2"""
    try:
        parts = [int(x.strip()) for x in region_str.split(",")]
        if len(parts) != 4:
            raise ValueError
        x1, y1, x2, y2 = parts
        if x1 >= x2 or y1 >= y2:
            raise ValueError("region 坐标无效: x1<x2, y1<y2")
        return [x1, y1, x2, y2]
    except Exception:
        raise argparse.ArgumentTypeError("region 格式: x1,y1,x2,y2 (整数)")

def main():
    parser = argparse.ArgumentParser(description="Vision Tool: 分析截图并返回结构化 JSON")
    parser.add_argument("--image", required=True, help="截图绝对路径")
    parser.add_argument("--task", required=True, choices=TASKS, help="任务类型")
    parser.add_argument("--question", help="定向问题（建议提供）")
    parser.add_argument("--region", type=parse_region, help="裁剪区域 x1,y1,x2,y2")
    parser.add_argument("--compare-image", help="对比图路径（仅 compare task）")
    parser.add_argument("--no-cache", action="store_true", help="跳过缓存")
    parser.add_argument("--api-key", help="百炼 API Key（覆盖 env var / .debug.env）")
    args = parser.parse_args()

    # --api-key 覆盖：写入 env var，供 client._get_headers 读取
    if args.api_key:
        os.environ["VISION_API_KEY"] = args.api_key

    # 参数校验
    if not os.path.isfile(args.image):
        logger.error(f"图片不存在: {args.image}")
        sys.exit(2)
    if args.task == "compare" and not args.compare_image:
        logger.error("compare task 需要 --compare-image")
        sys.exit(2)
    if args.compare_image and not os.path.isfile(args.compare_image):
        logger.error(f"对比图不存在: {args.compare_image}")
        sys.exit(2)
    if args.task == "find_element" and not args.question:
        logger.error("find_element task 需要 --question 指定目标元素")
        sys.exit(2)
    if args.task == "compare" and args.region:
        logger.error("compare task 不支持 --region（基准图需同比例）")
        sys.exit(2)

    # 预处理：裁剪/缩放 -> base64 + 坐标映射
    try:
        img_data = preprocess_image(args.image, args.region)
        compare_data = None
        if args.compare_image:
            compare_data = preprocess_image(args.compare_image, None)
    except Exception as e:
        logger.error(f"预处理失败: {e}")
        sys.exit(2)

    # 缓存 key
    cache_key = make_cache_key(
        image_path=args.image,
        task=args.task,
        question=args.question,
        region=args.region,
        compare_image_path=args.compare_image,
        model=VISION_MODEL,
    )

    # 读缓存
    if not args.no_cache:
        cached = get_cache(cache_key)
        if cached:
            logger.info(f"缓存命中: {cache_key[:16]}...")
            cached["cached"] = True
            print(json.dumps(cached, ensure_ascii=False))
            sys.exit(0)

    # 构建 messages
    try:
        messages = build_messages(
            task=args.task,
            image_base64=img_data["base64"],
            question=args.question,
            compare_base64=compare_data["base64"] if compare_data else None,
        )
    except Exception as e:
        logger.error(f"构建 prompt 失败: {e}")
        sys.exit(4)

    # 调用 Vision API
    try:
        raw_response = call_vision_api(messages)
    except VisionSchemaError as e:
        logger.error(f"模型返回非 JSON: {e}")
        sys.exit(4)
    except VisionAPIError as e:
        logger.error(f"Vision API 调用失败: {e}")
        sys.exit(3)
    except Exception as e:
        logger.error(f"Vision API 意外错误: {e}")
        sys.exit(3)

    # 归一化 + 校验
    try:
        result = normalize_response(
            raw_response=raw_response,
            task=args.task,
            img_data=img_data,
            region=args.region,
        )
    except VisionResponseError as e:
        logger.error(f"响应校验失败: {e}")
        sys.exit(4)
    except Exception as e:
        logger.error(f"响应归一化失败: {e}")
        sys.exit(4)

    # 写缓存
    if not args.no_cache:
        try:
            set_cache(cache_key, result)
        except Exception as e:
            logger.warning(f"写缓存失败: {e}")

    result["cached"] = False
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0)

if __name__ == "__main__":
    main()