# -*- coding: utf-8 -*-
"""coding-balance：火山方舟 Coding Plan 剩余额度 / 模型 / 费率 查看工具。

用法示例：
    python3 coding_balance.py auth-check                 # 验证 AK/SK 是否可用
    python3 coding_balance.py plan                       # 查询 CodingPlan / AgentPlan 套餐
    python3 coding_balance.py quota                      # 查看 Coding Plan 剩余额度（AFP）
    python3 coding_balance.py quota --watch 10           # 每 10 秒实时刷新剩余额度
    python3 coding_balance.py models --coding-plan       # Coding Plan 支持哪些模型
    python3 coding_balance.py models --search doubao     # 搜索模型
    python3 coding_balance.py pricing --search doubao    # 查看模型费率
    python3 coding_balance.py pricing --coding-plan      # Coding Plan 模型 AFP 抵扣系数
    python3 coding_balance.py ratelimit                  # 查看模型限流（RPM/TPM，QPS≈RPM/60）
    python3 coding_balance.py ratelimit --search doubao  # 搜索限流配置
    python3 coding_balance.py selftest                   # 校验本地签名实现

凭据来源（按优先级）：
    1. 环境变量 ARK_ACCESS_KEY / ARK_SECRET_KEY
    2. 当前目录 config.ini
    3. ~/.config/coding-balance/config.ini
"""

import argparse
import configparser
import os
import sys
import time
from datetime import datetime, timezone

import ark_client
from ark_client import ArkError

PROG = "coding-balance"

CONFIG_SEARCH = [
    os.path.join(os.getcwd(), "config.ini"),
    os.path.join(os.path.expanduser("~"), ".config", "coding-balance", "config.ini"),
]

WINDOW_LABELS = [
    ("AFPFiveHour", "近 5 小时"),
    ("AFPDaily",    "近 1 天"),
    ("AFPWeekly",   "近 1 周"),
    ("AFPMonthly",  "近 1 月"),
]

# Coding Plan 支持模型的 AFP 抵扣系数快照
# 来源：https://docs.volcengine.com/docs/82379/2516283 （套餐内 AFP 抵扣规则，文本生成/向量化）
# 抵扣公式：单次请求 AFP = (输入token × 输入系数 + 输出token × 输出系数) / 10000
CODING_PLAN_DEDUCT_SNAPSHOT = [
    ("doubao-seed-2.0-mini",      "0.25（不含音频）", "0.25（不含音频）", "文本生成（极速）"),
    ("doubao-seed-2.0-lite",      "0.5",             "0.5",             "文本生成（标准，即将下线）"),
    ("deepseek-v4-flash",         "0.5",             "0.5",             "文本生成（标准）"),
    ("doubao-seed-2.1-lite",      "0.5（不含音频）", "0.5（不含音频）", "文本生成（标准）"),
    ("glm-5.3-flash",             "0.5",             "0.5",             "文本生成（标准）"),
    ("doubao-seed-2.1-turbo",     "2.5",             "2.5",             "文本生成（进阶，即将下线）"),
    ("doubao-seed-evolving",      "2.5",             "2.5",             "文本生成（进阶）"),
    ("minimax-m3",                "2.5",             "2.5",             "文本生成（进阶）"),
    ("doubao-seed-2.1-pro",       "2.5",             "2.5",             "文本生成（进阶）"),
    ("kimi-k2.7-code",            "4.5",             "4.5",             "文本生成（进阶）"),
    ("kimi-k2.8-preview",         "8（限时 4.8）",  "8（限时 4.8）",   "文本生成（进阶）"),
    ("glm-5.3 (glm-latest)",      "4.5",             "4.5",             "文本生成（进阶）"),
    ("deepseek-v4-pro",           "5.5",             "5.5",             "文本生成（进阶）"),
    ("deepseek-v4.1-flash",       "2.5（限时 1.25）", "2.5（限时 1.25）", "文本生成（进阶）"),
    ("kimi-k3",                   "10",              "10",              "文本生成（进阶）"),
    ("doubao-embedding-vision",   "0.5",             "0.5",             "向量化"),
]

DEDUCT_DOC_URL = "https://docs.volcengine.com/docs/82379/2516283"


# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

def get_credentials():
    ak = os.environ.get("ARK_ACCESS_KEY") or os.environ.get("VOLC_ACCESSKEY")
    sk = os.environ.get("ARK_SECRET_KEY") or os.environ.get("VOLC_SECRETKEY")
    source = "环境变量"
    if not (ak and sk):
        for path in CONFIG_SEARCH:
            if os.path.exists(path):
                cp = configparser.ConfigParser()
                cp.read(path, encoding="utf-8")
                if cp.has_section("ark"):
                    ak = cp.get("ark", "access_key", fallback="") or None
                    sk = cp.get("ark", "secret_key", fallback="") or None
                    source = path
                    break
    if not (ak and sk):
        print("未找到访问密钥。请任选其一：")
        print("  1. 导出环境变量：export ARK_ACCESS_KEY=<AK>  ARK_SECRET_KEY=<SK>")
        print("  2. 复制 config.example.ini 为 config.ini 并填入 AK/SK")
        print("AK/SK 获取：https://console.volcengine.com/iam/keymanage")
        sys.exit(2)
    return ak, sk, source


def fmt_ts(epoch_ms):
    if not epoch_ms:
        return "-"
    return datetime.fromtimestamp(epoch_ms / 1000).strftime("%Y-%m-%d %H:%M")


def fmt_num(value):
    try:
        f = float(value)
        if f == int(f):
            return str(int(f))
        return f"{f:.2f}".rstrip("0").rstrip(".")
    except (TypeError, ValueError):
        return str(value)


def bar(used, quota, width=22):
    try:
        ratio = float(used) / float(quota) if float(quota) else 0.0
    except (TypeError, ValueError, ZeroDivisionError):
        ratio = 0.0
    ratio = max(0.0, min(1.0, ratio))
    filled = int(ratio * width)
    return "█" * filled + "░" * (width - filled)


def clear_screen():
    print("\033[H\033[J", end="")


def paginate(fetcher, total_key, page_size=100, max_items=None):
    """通用分页：fetcher(page_number, page_size) -> (items, total)。"""
    all_items, page = [], 1
    while True:
        items, total = fetcher(page, page_size)
        all_items.extend(items)
        if not items:
            break
        if max_items and len(all_items) >= max_items:
            break
        if total is not None and len(all_items) >= int(total):
            break
        if page >= 50:  # 安全上限
            break
        page += 1
    return all_items


# ---------------------------------------------------------------------------
# 命令实现
# ---------------------------------------------------------------------------

def cmd_selftest(_args):
    try:
        ark_client.selftest()
    except AssertionError as e:
        print(f"签名自检失败：{e}")
        return 1
    print("OK：HMAC-SHA256 签名实现与官方文档示例一致")
    return 0


def cmd_auth_check(args):
    ak, sk, source = get_credentials()
    print(f"使用凭据：{source}")
    try:
        result = ark_client.api_call(ak, sk, "ListModelActivations",
                                     {"PageNumber": 1, "PageSize": 1,
                                      "Filter": {}, "WithPrice": False, "WithFreeUsage": False})
        print(f"OK：凭据有效，共开通/可见模型 {result.get('TotalCount', '?')} 个")
        return 0
    except ArkError as e:
        print(f"凭据校验失败：{e}")
        if "SignatureDoesNotMatch" in (e.code or "") or "InvalidAccessKey" in (e.code or ""):
            print("提示：AK/SK 或签名可能不正确，请检查密钥。")
        return 1


def cmd_plan(args):
    ak, sk, _ = get_credentials()
    for plan in ["CodingPlan", "AgentPlan"]:
        print(f"== {plan} ==")
        try:
            r = ark_client.api_call(ak, sk, "GetPersonalPlan", {"Plan": plan})
        except ArkError as e:
            if "ResourceNotFound" in (e.code or ""):
                print("  未购买该套餐")
            else:
                print(f"  查询失败：{e}")
            continue
        status = r.get("Status", "-")
        status_mark = {"Running": "生效中", "Expired": "已过期"}.get(status, status)
        print(f"  档位      : {r.get('PlanType', '-')}")
        print(f"  状态      : {status_mark}")
        print(f"  生效时间  : {r.get('StartTime', '-')}")
        print(f"  到期时间  : {r.get('EndTime', '-')}")
        print(f"  自动续费  : {'是' if r.get('AutoRenew') else '否'}")
    return 0


# Coding Plan 个人版周期：GetCodingPlanUsage 返回的 Level -> 展示名
CODING_PLAN_LEVEL_LABELS = {
    "session": "近5小时",
    "5h": "近5小时",
    "fivehour": "近5小时",
    "weekly": "近一周",
    "monthly": "近一月",
    "day": "近1天",
    "daily": "近1天",
}

# Coding Plan / Agent Plan 公网 OpenAPI 入口（arkcli 同款）
OPEN_HOST = "open.volcengineapi.com"


def _show_window(title, win):
    """Agent Plan 的 AFP 窗口（有绝对值）。"""
    quota = fmt_num(win.get("Quota", 0))
    used = fmt_num(win.get("Used", 0))
    try:
        ratio = float(win.get("Used", 0)) / float(win.get("Quota", 0)) if float(win.get("Quota", 0)) else 0
    except (TypeError, ValueError, ZeroDivisionError):
        ratio = 0
    remain = float(win.get("Quota", 0)) - float(win.get("Used", 0)) if win.get("Quota") else 0
    print(f"  {title:<10} [{bar(win.get('Used', 0), win.get('Quota', 0))}] "
          f"已用 {used:>10} / 总额 {quota:<10}  剩余 {fmt_num(remain):>10} AFP  "
          f"({ratio * 100:.1f}%)")
    print(f"            窗口开始 {fmt_ts(win.get('SubscribeTime'))}  下次重置 {fmt_ts(win.get('ResetTime'))}")


def _show_percent_window(title, item):
    """Coding Plan 的周期窗口（后端只返已用百分比）。"""
    try:
        percent = float(item.get("Percent", 0) or 0)
    except (TypeError, ValueError):
        percent = 0
    remain = max(0.0, 100.0 - percent)
    reset = item.get("ResetTimestamp") or item.get("ResetTime")
    if isinstance(reset, (int, float)) and reset and reset < 10 ** 11:  # 秒 -> 毫秒
        reset = int(reset * 1000)
    print(f"  {title:<10} [{bar(percent, 100)}] 已用 {percent:.1f}%  剩余 {remain:.1f}%  "
          f"下次重置 {fmt_ts(reset)}")


def _show_usage_detail(ak, sk, days=1):
    """GetUsageDetails：套餐内模型调用明细（近 N 天，Agent Plan 才有）。"""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    start = datetime.fromtimestamp(
        time.time() - (days - 1) * 86400, tz=timezone.utc).strftime("%Y-%m-%d")
    try:
        r = ark_client.api_call(ak, sk, "GetUsageDetails",
                                {"QueryInterval": "Day",
                                 "Filter": {"StartTime": start, "EndTime": today}})
    except ArkError as e:
        print(f"  （套餐模型调用明细不可用：{e.code or e.message}）")
        return
    details = r.get("Details", [])
    if not details:
        print("  （套餐模型调用明细为空）")
        return
    rows = {}
    for d in details:
        key = (d.get("ObjectName"), d.get("Unit"), d.get("BillingType"))
        rows[key] = rows.get(key, 0) + int(d.get("Usage", 0))
    print("  模型调用明细（套餐内）:")
    for (name, unit, billing), usage in sorted(rows.items()):
        bt = "套餐内" if billing == "WithinPlan" else ("套餐外" if billing == "OutsideOfPlan" else str(billing))
        print(f"    {name:<32} {usage:>12} {unit:<8} {bt}")


def cmd_quota(args):
    ak, sk, _ = get_credentials()
    watch = args.watch

    def render(iteration=0):
        if watch:
            clear_screen()
            print(f"coding-balance · 实时刷新（每 {watch}s） Ctrl-C 退出 · "
                  f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        print("== Coding Plan 套餐 ==")
        try:
            p = ark_client.api_call(ak, sk, "GetPersonalPlan", {"Plan": "CodingPlan"})
            status = {"Running": "生效中", "Expired": "已过期"}.get(p.get("Status", "-"), p.get("Status", "-"))
            print(f"  档位 {p.get('PlanType', '-')} · {status} · 到期 {p.get('EndTime', '-')}"
                  f" · 自动续费{'开' if p.get('AutoRenew') else '关'}")
        except ArkError as e:
            if "ResourceNotFound" in (e.code or ""):
                print("  未购买 Coding Plan 个人版套餐")
            else:
                print(f"  查询失败：{e}")

        # Coding Plan 个人版走 GetCodingPlanUsage（公网 OpenAPI，仅百分比）
        coding_items, coding_err = None, None
        try:
            r = ark_client.api_call(ak, sk, "GetCodingPlanUsage", {}, host=OPEN_HOST)
            coding_items = r.get("QuotaUsage") or []
        except ArkError as e:
            coding_err = e

        if coding_items:
            print("\n== 剩余额度（Coding Plan，已用百分比）==")
            for item in coding_items:
                level = str(item.get("Level", "")).lower()
                label = CODING_PLAN_LEVEL_LABELS.get(level, level or "周期")
                _show_percent_window(label, item)
        elif coding_err is None:
            print("\n== 剩余额度 ==")
            print("  GetCodingPlanUsage 未返回额度数据（可能未订阅 Coding Plan）")
        else:
            print("\n== 剩余额度 ==")
            print(f"  GetCodingPlanUsage 查询失败：{coding_err}")
            print("  提示：请确认 IAM 账号具备 ark:GetCodingPlanUsage 权限；"
                  "可先用 `arkcli usage plan` 或控制台确认。")
            # 兜底：Agent Plan 的 GetAFPUsage
            try:
                r = ark_client.api_call(ak, sk, "GetAFPUsage")
                if r.get("PlanType"):
                    print(f"  档位：{r.get('PlanType')}")
                for key, label in WINDOW_LABELS:
                    win = r.get(key)
                    if win:
                        _show_window(label, win)
                    else:
                        print(f"  {label:<10} （无数据）")
            except ArkError as e2:
                print(f"  GetAFPUsage 兜底也失败：{e2}")

        print("\n== 套餐模型调用明细 ==")
        _show_usage_detail(ak, sk, args.days)
        print()

    try:
        if watch:
            i = 0
            while True:
                render(i)
                i += 1
                time.sleep(max(1, watch))
        else:
            render()
    except KeyboardInterrupt:
        print("已退出。")
    return 0


def cmd_models(args):
    ak, sk, _ = get_credentials()

    if args.coding_plan:
        print("== Coding Plan 支持的模型 ==")
        try:
            r = ark_client.api_call(ak, sk, "ListArkCodingPlanModel")
        except ArkError as e:
            print(f"  查询失败：{e}")
            return 1
        models = [d.get("ModelID") for d in r.get("Datas", []) if d.get("ModelID")]
        if args.search:
            models = [m for m in models if args.search.lower() in m.lower()]
        for m in sorted(models):
            print(f"  {m}")
        print(f"  共 {len(models)} 个")
        return 0

    def fetch(page, size):
        r = ark_client.api_call(ak, sk, "ListFoundationModels",
                                {"PageNumber": page, "PageSize": size, "Filter": {}})
        items = r.get("Items", [])
        return items, r.get("TotalCount")

    items = paginate(fetch, "TotalCount", page_size=100, max_items=args.limit)
    if args.search:
        q = args.search.lower()
        items = [i for i in items if q in (i.get("Name") or "").lower()
                 or q in (i.get("DisplayName") or "").lower()]
    if args.domain:
        q = args.domain.lower()
        items = [i for i in items
                 if q in ",".join((i.get("FoundationModelTag") or {}).get("Domains", [])).lower()]

    if not items:
        print("没有匹配的模型。")
        return 0
    print(f"{'Name':<34} {'DisplayName':<34} {'Domains':<28} {'任务类型':<20} 访问")
    print("-" * 140)
    for i in items:
        tag = i.get("FoundationModelTag") or {}
        domains = ",".join(tag.get("Domains", []))
        tasks = ",".join(tag.get("TaskTypes", []))
        print(f"{i.get('Name') or '-':<34} {i.get('DisplayName') or '-':<34} "
              f"{domains:<28} {tasks:<20} {i.get('AccessType') or '-'}")
    print(f"\n共 {len(items)} 个模型")
    return 0


def _charge_items_str(charge_items):
    parts = []
    for c in charge_items or []:
        price = fmt_num(c.get("Price"))
        unit = c.get("UnitCode") or c.get("Unit") or "-"
        ctype = c.get("Type") or "-"
        parts.append(f"{ctype} {price}/{unit}")
    return "; ".join(parts) if parts else "-"


def cmd_pricing(args):
    if args.coding_plan:
        print("== Coding Plan 模型 AFP 抵扣系数 ==")
        print("  抵扣公式：单次请求 AFP = (输入token×输入系数 + 输出token×输出系数) / 10000")
        print(f"  来源：{DEDUCT_DOC_URL}\n")
        print(f"{'模型':<32} {'输入系数':<22} {'输出系数':<22} 类别")
        print("-" * 100)
        for name, inp, out, cat in CODING_PLAN_DEDUCT_SNAPSHOT:
            if args.search and args.search.lower() not in name.lower():
                continue
            print(f"{name:<32} {inp:<22} {out:<22} {cat}")
        print("\n注：系数会随限时活动变化，快照仅供参考；以官方文档页为准。")
        return 0

    ak, sk, _ = get_credentials()

    def fetch(page, size):
        r = ark_client.api_call(ak, sk, "ListModelActivations",
                                {"PageNumber": page, "PageSize": size,
                                 "Filter": {"IncludeDeprecatedModels": False},
                                 "WithPrice": True, "WithFreeUsage": True})
        return r.get("Items", []), r.get("TotalCount")

    items = paginate(fetch, "TotalCount", page_size=100, max_items=args.limit)
    if args.search:
        q = args.search.lower()
        items = [i for i in items if q in (i.get("ModelName") or "").lower()
                 or q in (i.get("DisplayName") or "").lower()]

    if not items:
        print("没有匹配的模型。")
        return 0
    print(f"{'模型':<34} {'展示名':<30} {'状态':<12} 计费项（元/单位）")
    print("-" * 120)
    for i in items:
        state = i.get("State") or "-"
        name = i.get("ModelName") or i.get("Name") or "-"
        disp = i.get("DisplayName") or "-"
        print(f"{name:<34} {disp:<30} {state:<12} {_charge_items_str(i.get('ChargeItems'))}")
    print(f"\n共 {len(items)} 个模型（单价单位见各模型计费项，例如 /百万tokens）")
    return 0


def cmd_ratelimit(args):
    """ListModelRateLimit：查询账号下各基础模型限流（RPM/TPM/TPD），QPS≈RPM/60。
    价格来自 ListModelActivations（WithPrice=True）。"""
    ak, sk, _ = get_credentials()

    # 价格映射：FoundationModelName -> 计费项（查询失败不阻塞限流展示）
    price_map = {}

    def fetch_price(page, size):
        r = ark_client.api_call(ak, sk, "ListModelActivations",
                                {"PageNumber": page, "PageSize": size,
                                 "Filter": {"IncludeDeprecatedModels": False},
                                 "WithPrice": True, "WithFreeUsage": True})
        return r.get("Items", []), r.get("TotalCount")

    try:
        for i in paginate(fetch_price, "TotalCount", page_size=100):
            name = i.get("FoundationModelName") or i.get("Name")
            if name:
                price_map[name] = _charge_items_str(i.get("ChargeItems"))
    except ArkError:
        pass  # 价格缺失时显示 "-"

    try:
        r = ark_client.api_call(ak, sk, "ListModelRateLimit")
    except ArkError as e:
        print(f"查询失败：{e}")
        print("提示：ListModelRateLimit 需 IAM 账号具备对应 ark 管控面读权限。")
        return 1
    items = r.get("Items", [])
    if args.search:
        q = args.search.lower()
        items = [i for i in items if q in (i.get("FoundationModelName") or "").lower()]
    if args.limit:
        items = items[:args.limit]
    if not items:
        print("没有查询到模型限流信息。")
        return 0

    def qps(rpm):
        try:
            return f"{float(rpm) / 60:.1f}"
        except (TypeError, ValueError):
            return "-"

    print(f"{'基础模型':<34} {'QPS(≈)':<7} {'当前RPM':<9} {'当前TPM':<11} "
          f"{'默认RPM':<9} {'默认TPM':<11} {'TPD':<8} 价格（元/单位）")
    print("-" * 148)
    for i in items:
        name = i.get("FoundationModelName") or "-"
        cur = i.get("CurrentRateLimit") or {}
        dft = i.get("DefaultRateLimit") or {}
        rpm, tpm = cur.get("Rpm") or 0, cur.get("Tpm") or 0
        # 平台价格可能以 "-ga"（GA 稳定版）后缀登记，精确匹配失败时回退
        price = price_map.get(name) or price_map.get(name + "-ga", "-")
        if len(price) > 44:
            price = price[:44] + "…"
        print(f"{name:<34} {qps(rpm):<7} {fmt_num(rpm):<9} {fmt_num(tpm):<11} "
              f"{fmt_num(dft.get('Rpm') or 0):<9} {fmt_num(dft.get('Tpm') or 0):<11} "
              f"{fmt_num(i.get('CurrentTpd') or 0):<8} {price}")
    print(f"\n共 {len(items)} 个模型。RPM=每分钟请求数，QPS≈RPM/60；TPM=每分钟Token数；TPD=每日Token限额。")
    return 0


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        prog=PROG,
        description="火山方舟 Coding Plan 剩余额度 / 模型 / 费率 查看工具")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("selftest", help="校验本地签名实现与官方示例是否一致")
    sub.add_parser("auth-check", help="验证 AK/SK 凭据是否有效")

    sub.add_parser("plan", help="查询 CodingPlan / AgentPlan 个人版套餐信息")

    p_quota = sub.add_parser("quota", help="查看 Coding Plan 剩余额度（AFP）")
    p_quota.add_argument("--watch", type=int, metavar="秒", default=0,
                         help="每 N 秒实时刷新（例如 --watch 10）")
    p_quota.add_argument("--days", type=int, default=1, help="模型调用明细近 N 天（默认 1）")

    p_models = sub.add_parser("models", help="查看模型列表")
    p_models.add_argument("--coding-plan", action="store_true", help="仅显示 Coding Plan 支持的模型")
    p_models.add_argument("--search", metavar="关键词", help="按名称/展示名过滤")
    p_models.add_argument("--domain", metavar="领域", help="按能力领域过滤（LLM/Audio/...）")
    p_models.add_argument("--limit", type=int, default=None, help="最多返回条数")

    p_price = sub.add_parser("pricing", help="查看模型费率")
    p_price.add_argument("--coding-plan", action="store_true", help="显示 Coding Plan 模型 AFP 抵扣系数")
    p_price.add_argument("--search", metavar="关键词", help="按模型名过滤")
    p_price.add_argument("--limit", type=int, default=None, help="最多返回条数")

    p_rate = sub.add_parser("ratelimit", help="查看模型限流（RPM/TPM，QPS≈RPM/60）")
    p_rate.add_argument("--search", metavar="关键词", help="按基础模型名过滤")
    p_rate.add_argument("--limit", type=int, default=None, help="最多返回条数")

    args = parser.parse_args(argv)

    handlers = {
        "selftest": cmd_selftest,
        "auth-check": cmd_auth_check,
        "plan": cmd_plan,
        "quota": cmd_quota,
        "models": cmd_models,
        "pricing": cmd_pricing,
        "ratelimit": cmd_ratelimit,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
