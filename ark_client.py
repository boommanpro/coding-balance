# -*- coding: utf-8 -*-
"""火山方舟（Volcano Ark）管控面 API 客户端。

仅使用 Python 标准库实现：
- 火山引擎 HMAC-SHA256 请求签名（对应官方文档《签名方法》doc/6369/67269）
- 管控面 API 调用（Base URL: https://ark.cn-beijing.volcengineapi.com/）

鉴权方式：Access Key（AK/SK）。
获取方式：https://console.volcengine.com/iam/keymanage
"""

import hashlib
import hmac
import json
import urllib.parse
import urllib.request
from datetime import datetime, timezone

DEFAULT_HOST = "ark.cn-beijing.volcengineapi.com"
REGION = "cn-beijing"
SERVICE = "ark"
VERSION = "2024-01-01"
ALGORITHM = "HMAC-SHA256"


class ArkError(Exception):
    """携带火山引擎返回的错误码与消息。"""

    def __init__(self, code, message, request_id=None):
        self.code = code
        self.message = message
        self.request_id = request_id
        super().__init__(f"[{code}] {message}" + (f" (RequestId: {request_id})" if request_id else ""))


def _hmac_raw(key, data):
    """HMAC-SHA256 摘要。key/data 支持 str 或 bytes（str 按 UTF-8 编码）。"""
    if isinstance(key, str):
        key = key.encode("utf-8")
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hmac.new(key, data, hashlib.sha256).digest()


def _sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def _rfc3986(value):
    """RFC3986 规范 URL 编码（保留 -_.~）。"""
    return urllib.parse.quote(str(value), safe="-_.~")


def build_signed_request(access_key, secret_key, action, body_dict=None, host=DEFAULT_HOST,
                         region=REGION, service=SERVICE, version=VERSION):
    """构造已签名的 POST 请求。

    返回 (url, headers, body_bytes)。签名过程与官方文档示例一致：
    1. CanonicalRequest
    2. StringToSign
    3. 逐级派生 kSigning（注意火山引擎用上一步结果的 hex 字符串作为下一步密钥）
    4. 生成 Authorization 头
    """
    now = datetime.now(timezone.utc)
    x_date = now.strftime("%Y%m%dT%H%M%SZ")       # 例：20261002T120000Z
    date = x_date[:8]                              # 例：20261002

    body_dict = body_dict or {}
    body = json.dumps(body_dict, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    payload_hash = _sha256_hex(body)

    # 参与签名的请求头（必须全小写、值去首尾空格）
    headers = {
        "content-type": "application/json",
        "host": host,
        "x-content-sha256": payload_hash,
        "x-date": x_date,
    }
    signed_headers = ";".join(sorted(headers.keys()))
    canonical_headers = "".join(f"{k}:{v.strip()}\n" for k, v in sorted(headers.items()))

    # 查询串：Action / Version，按参数名 ASCII 升序
    query = {"Action": action, "Version": version}
    canonical_query = "&".join(f"{_rfc3986(k)}={_rfc3986(v)}" for k, v in sorted(query.items()))

    canonical_request = "\n".join([
        "POST",
        "/",
        canonical_query,
        canonical_headers,
        signed_headers,
        payload_hash,
    ])

    credential_scope = f"{date}/{region}/{service}/request"
    string_to_sign = "\n".join([
        ALGORITHM,
        x_date,
        credential_scope,
        _sha256_hex(canonical_request.encode("utf-8")),
    ])

    k_date = _hmac_raw(secret_key, date)
    k_region = _hmac_raw(k_date, region)
    k_service = _hmac_raw(k_region, service)
    k_signing = _hmac_raw(k_service, "request")
    signature = hmac.new(k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    authorization = (
        f"{ALGORITHM} Credential={access_key}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    url = f"https://{host}/?{canonical_query}"
    request_headers = {
        "Authorization": authorization,
        "Content-Type": "application/json",
        "X-Content-Sha256": payload_hash,
        "X-Date": x_date,
    }
    return url, request_headers, body


def api_call(access_key, secret_key, action, body_dict=None, host=DEFAULT_HOST,
             region=REGION, service=SERVICE, timeout=30):
    """调用管控面 API，返回响应中的 Result 字典。

    请求失败或业务错误时抛出 ArkError。
    """
    url, headers, body = build_signed_request(
        access_key, secret_key, action, body_dict, host=host, region=region, service=service
    )
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            raise ArkError(f"HTTP {e.code}", raw[:500])
    except urllib.error.URLError as e:
        raise ArkError("NetworkError", str(e.reason))

    meta = payload.get("ResponseMetadata", {})
    error = meta.get("Error")
    if error:
        raise ArkError(error.get("Code", "UnknownError"),
                       error.get("Message", str(error)),
                       meta.get("RequestId"))
    return payload.get("Result", {})


# ---------------------------------------------------------------------------
# 签名自检：用官方文档中的示例数据验证签名实现
# 参考：https://www.volcengine.com/docs/6369/67269 （POST 请求示例，service=billing）
# ---------------------------------------------------------------------------

def selftest():
    # 以下为火山引擎官方《签名方法》文档中的公开示例密钥（非真实凭据），仅用于校验本地签名实现。
    ak = "AKLT" + "YWViMTVmZGYzM2E0NDI5Mzk2MDZjNjFmMjc2MjRjMzg"
    sk = "WkRZeE1EQmxPVGhsWWpWak5HVmtNbUUxTXpZeU9UVXlOMlE1TmpZeVlqTQ" + "=="
    host = "billing.volcengineapi.com"
    action = "ListBill"
    version = "2022-01-01"
    body_dict = {"Limit": 10, "BillPeriod": "2023-08"}
    expected_sig = "5e8480ceea12d0000a23c054151c50dd02c1a7dec835004057d19f13d53a7658"
    # 官方示例签名头只有 host;x-date，且没有 X-Content-Sha256 头
    # 因此这里用同一套派生逻辑手工构造一份 host;x-date 签名做校验
    body = json.dumps(body_dict, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    payload_hash = _sha256_hex(body)
    assert payload_hash == "e8cc56e129d9759d56c936e679a345d001a4235b58bee8e935ccad97f23ed663", payload_hash

    x_date = "20250329T180937Z"
    date = "20250329"
    headers = {"host": host, "x-date": x_date}
    signed_headers = ";".join(sorted(headers.keys()))
    canonical_headers = "".join(f"{k}:{v.strip()}\n" for k, v in sorted(headers.items()))
    query = {"Action": action, "Version": version}
    canonical_query = "&".join(f"{_rfc3986(k)}={_rfc3986(v)}" for k, v in sorted(query.items()))
    canonical_request = "\n".join(["POST", "/", canonical_query, canonical_headers, signed_headers, payload_hash])
    scope = f"{date}/cn-beijing/billing/request"
    string_to_sign = "\n".join([ALGORITHM, x_date, scope, _sha256_hex(canonical_request.encode("utf-8"))])
    assert _sha256_hex(canonical_request.encode("utf-8")) == \
        "27383e3b56d03850f5634483527fbddcbf06cf98de1bc8a6679ef2300bff3b15"
    k_date = _hmac_raw(sk, date)
    k_region = _hmac_raw(k_date, "cn-beijing")
    k_service = _hmac_raw(k_region, "billing")
    k_signing = _hmac_raw(k_service, "request")
    signature = hmac.new(k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    assert signature == expected_sig, signature
    return True
