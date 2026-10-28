# client.py — 百炼 OpenAI 兼容 Vision API 调用
import os
import json
import requests
from typing import List, Dict, Any

# 环境变量配置（复用现有 Token Plan Key）
VISION_BASE_URL = os.environ.get(
    "VISION_BASE_URL",
    "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
)
VISION_MODEL = os.environ.get("VISION_MODEL", "qwen3.8-flash")

class VisionAPIError(Exception):
    """Vision API 调用错误（网络/HTTP/协议）"""
    pass

class VisionSchemaError(Exception):
    """模型返回非 JSON 或结构不符"""
    pass

def _load_from_debug_env() -> str:
    """从当前目录（或项目根）的 .debug.env 中读取 VISION_API_KEY（不执行文件内容）"""
    for candidate in (".debug.env", os.path.join(os.getcwd(), ".debug.env")):
        if not os.path.isfile(candidate):
            continue
        try:
            with open(candidate, encoding="utf-8") as f:
                for raw in f:
                    line = raw.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" not in line:
                        continue
                    key, _, val = line.partition("=")
                    key = key.strip()
                    if key.startswith("export "):
                        key = key[len("export "):].strip()
                    if key != "VISION_API_KEY":
                        continue
                    val = val.strip()
                    if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                        val = val[1:-1]
                    if val:
                        return val
        except OSError:
            continue
    return ""


def _get_headers() -> Dict[str, str]:
    api_key = os.environ.get("VISION_API_KEY") or os.environ.get("OPENAI_API_KEY") or _load_from_debug_env()
    if not api_key:
        raise RuntimeError("VISION_API_KEY 或 OPENAI_API_KEY 环境变量未设置，或 .debug.env 中未配置 VISION_API_KEY")
    return {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

TIMEOUT = 60  # 秒
MAX_RETRIES = 1

def call_vision_api(messages: List[Dict[str, Any]]) -> Dict[str, Any]:
    """
    调用百炼兼容模式 /chat/completions
    返回: 解析后的 JSON（choices[0].message.content）
    抛出: VisionAPIError (网络/HTTP) / VisionSchemaError (JSON 解析失败)
    """
    payload = {
        "model": VISION_MODEL,
        "messages": messages,
        "temperature": 0.1,
        "max_tokens": 4096,
        "response_format": {"type": "json_object"},  # 强制 JSON
    }

    url = f"{VISION_BASE_URL}/chat/completions"

    for attempt in range(MAX_RETRIES + 1):
        try:
            resp = requests.post(url, headers=_get_headers(), json=payload, timeout=TIMEOUT)
            if resp.status_code == 200:
                data = resp.json()
                content = data["choices"][0]["message"]["content"]
                try:
                    return json.loads(content)
                except json.JSONDecodeError as e:
                    raise VisionSchemaError(f"模型返回非 JSON: {e}")
            elif resp.status_code >= 500:
                # 5xx 重试
                if attempt < MAX_RETRIES:
                    continue
                raise VisionAPIError(f"API {resp.status_code}: {resp.text}")
            else:
                # 4xx 不重试
                raise VisionAPIError(f"API {resp.status_code}: {resp.text}")
        except requests.Timeout:
            if attempt < MAX_RETRIES:
                continue
            raise VisionAPIError("API 请求超时")
        except requests.RequestException as e:
            if attempt < MAX_RETRIES:
                continue
            raise VisionAPIError(f"网络错误: {e}")

    raise VisionAPIError("API 调用失败（重试耗尽）")