# cache.py — 文件缓存：SHA256(key) -> JSON
import hashlib
import json
import os
import tempfile
from typing import Dict, Any, Optional

CACHE_DIR = os.path.expanduser("~/.cache/opencode-vision")

def _ensure_cache_dir():
    os.makedirs(CACHE_DIR, exist_ok=True)

def make_cache_key(
    image_path: str,
    task: str,
    question: Optional[str],
    region: Optional[list],
    compare_image_path: Optional[str],
    model: str = "qwen3.8-flash",
) -> str:
    """
    缓存 key = SHA256(文件字节 + task + question + region + compare图哈希 + model名)
    同一路径新截图 -> 文件字节变 -> key 变 -> 自动失效
    各字段用 '\x00' 分隔，防止碰撞（如 question="1,2,3,4" 与 region=[1,2,3,4]）
    """
    hasher = hashlib.sha256()

    # 1. 主图字节
    with open(image_path, "rb") as f:
        hasher.update(f.read())
    hasher.update(b"\x00")

    # 2. task
    hasher.update(task.encode())
    hasher.update(b"\x00")

    # 3. question
    if question:
        hasher.update(question.encode())
    hasher.update(b"\x00")

    # 4. region
    if region:
        hasher.update(",".join(map(str, region)).encode())
    hasher.update(b"\x00")

    # 5. 对比图字节
    if compare_image_path:
        with open(compare_image_path, "rb") as f:
            hasher.update(f.read())
    hasher.update(b"\x00")

    # 6. model 名
    hasher.update(model.encode())

    return hasher.hexdigest()

def get_cache(key: str) -> Optional[Dict[str, Any]]:
    _ensure_cache_dir()
    path = os.path.join(CACHE_DIR, f"{key}.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

def set_cache(key: str, value: Dict[str, Any]):
    _ensure_cache_dir()
    path = os.path.join(CACHE_DIR, f"{key}.json")
    # 原子写：mkstemp + rename（避免并发同 key 写同一 tmp 损坏）
    fd, tmp_path = tempfile.mkstemp(dir=CACHE_DIR, prefix=f"{key}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(value, f, ensure_ascii=False)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except Exception:
            pass
        raise

def clear_cache():
    """清空所有缓存（调试用）"""
    if os.path.isdir(CACHE_DIR):
        for f in os.listdir(CACHE_DIR):
            if f.endswith(".json"):
                os.remove(os.path.join(CACHE_DIR, f))