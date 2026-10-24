# Coding Balance

<p align="center">
  <img src="docs/logo.png" width="88" height="88" alt="Coding Balance logo">
</p>

<p align="center">
  <strong>火山方舟 Coding Plan 额度 &amp; Venice 余额 · macOS 菜单栏实时监控</strong>
</p>

<p align="center">
  <a href="https://github.com/boommanpro/coding-balance/actions/workflows/build.yml"><img src="https://github.com/boommanpro/coding-balance/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <a href="https://boommanpro.github.io/coding-balance/"><img src="https://github.com/boommanpro/coding-balance/actions/workflows/pages.yml/badge.svg" alt="Pages"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey" alt="Platform">
  <img src="https://img.shields.io/badge/made_with-Swift-orange" alt="Swift">
</p>

<p align="center">
  <a href="https://boommanpro.github.io/coding-balance/">🌐 项目官网（下载 / 使用 / 更新历史）</a>
  ·
  <a href="https://github.com/boommanpro/coding-balance/releases">⬇ 下载最新版</a>
  ·
  <a href="CHANGELOG.md">📝 更新历史</a>
</p>

菜单栏实时监控额度与余额：**火山方舟**显示近 5 小时剩余进度环与百分比，**Venice** 显示美元余额；点击查看明细与模型列表，支持多平台多账户切换。数据来自各平台官方 API，与控制台 1:1。

![菜单栏状态项](docs/screenshots/menubar.png)

## 支持平台

| 平台 | 凭据 | 额度/余额展示 | 模型列表 | 默认刷新频率 |
|---|---|---|---|---|
| [火山方舟](https://www.volcengine.com/product/ark) | AK/SK（IAM 子账号即可） | Coding Plan 各周期已用百分比 / Agent Plan AFP 绝对值 | 套餐模型 + QPS/RPM/TPM 限流 + 元价格 | 60 秒 |
| [Venice](https://venice.ai) | API Key（[Inference/Admin 均可](https://venice.ai/settings/api)） | USD/DIEM/附赠余额、可消费状态、Key 层级与到期 | 当前 Key 可用的全模态模型 + RPM/TPM 限流 + $ 价格 | 20 分钟 |

> 各平台刷新频率可用 `defaults write com.codingbalance.menu codingbalance.refreshInterval.<ark|venice> -int <秒>` 覆盖；接入新平台只需实现 `Provider` 协议并在 `ProviderKind` / `makeProvider` 注册。

## 功能

- **菜单栏圆形指示**：近 5 小时剩余进度环 + 百分比（绿 ≥50%、橙 20–50%、红 <20%）
- **左键详情弹窗**：5h 大圆环主视觉 + 周/月统计 + 三个额度窗口明细（已用/剩余进度条、下次重置时间）
- **右键快捷菜单**：刷新 / 管理账户 / 退出
- **多平台**：火山方舟（AK/SK，套餐额度）与 Venice（API Key，按量美元余额）混用，账户编辑表单按平台自动切换
- **Venice 余额**：USD / DIEM / 附赠额度明细、可消费状态、Key 层级与到期时间、限额周期重置时间；菜单栏直接显示余额金额
- **Venice 模型**：展示当前 Key 可用的全部模态模型（文本/图像/视频/语音…），RPM/TPM 限流与价格（$/百万tokens，图像按张/档），支持模态过滤与模态徽标
- **多账户**：切换「当前使用账户」即刷新并持久化，账户总览一键切换
- **模型速查**：弹窗「模型」页展示套餐可用模型及 QPS（≈RPM/60）、RPM/TPM 限流与单价
- **自动刷新**：按平台差异化频率——方舟每 60 秒、Venice 每 20 分钟（可用 `defaults write com.codingbalance.menu codingbalance.refreshInterval.<平台> -int <秒>` 覆盖，默认优先）；支持 Coding Plan（百分比额度）与 Agent Plan（AFP 绝对值）
- **隐私安全**：凭据仅存本机，直接请求官方 API，不上传第三方

![详情弹窗](docs/screenshots/popover.png)

## 下载与安装

1. 前往 [GitHub Releases](https://github.com/boommanpro/coding-balance/releases) 下载 `CodingBalance-macOS-vX.Y.Z.zip`
2. 解压后将 `CodingBalance.app` 拖入「应用程序」
3. 首次打开在「系统设置 → 隐私与安全性」允许，或右键应用 → 打开
4. 点击菜单栏齿轮 ⚙ → 添加账户 → 填入 AK/SK → 测试连接 → 保存

> 从源码构建：`cd macos && ./make_app.sh`（需 Swift 工具链）。

## 使用说明

- **AK/SK 获取（方舟）**：[火山引擎 · API 访问密钥管理](https://console.volcengine.com/iam/keymanage)（建议 IAM 子账号并授予 `ark:GetCodingPlanUsage` 权限）
- **API Key 获取（Venice）**：[venice.ai/settings/api](https://venice.ai/settings/api) 生成，Inference / Admin 类型均可查询余额与限流
- **网络代理（Venice）**：api.venice.ai 需可直连；不可直连时在设置窗口「通用」区填写 HTTP 代理（如 `http://127.0.0.1:7897`），仅 Venice 请求使用，留空走系统代理
- **刷新频率**：默认方舟 60 秒、Venice 20 分钟；可后台覆盖，如 `defaults write com.codingbalance.menu codingbalance.refreshInterval.venice -int 600`（ark/venice，单位秒，<30 视为无效回落默认）
- **交互**：左键=详情，右键=菜单，悬停=账户名与 5h 剩余/余额，弹窗内切换多账户
- **数据源**：方舟 `GetCodingPlanUsage`（Coding Plan，5h/周/月 已用百分比）、`GetAFPUsage`（Agent Plan，AFP 绝对值）、`GetPersonalPlan`（套餐信息）；Venice `GET /api_keys/rate_limits`（余额/层级/每模型限流）、`GET /models?type=all`（模型目录与价格）

![管理账户](docs/screenshots/settings.png)

## Python CLI（可选）

环境要求：Python 3.8+（仅标准库）。

```bash
export ARK_ACCESS_KEY=<你的AK>  ARK_SECRET_KEY=<你的SK>
python3 coding_balance.py auth-check      # 验证凭据
python3 coding_balance.py quota           # 查看剩余额度
python3 coding_balance.py quota --watch 10  # 每 10 秒刷新
python3 coding_balance.py models --coding-plan
python3 coding_balance.py pricing --coding-plan
python3 coding_balance.py ratelimit            # 查看模型限流（RPM/TPM，QPS≈RPM/60）
python3 coding_balance.py ratelimit --search doubao
python3 coding_balance.py selftest        # 校验签名实现
```

## 实现原理

- **签名**：按官方《签名方法》实现火山引擎 HMAC-SHA256（AK/SK → 逐级派生 kSigning）
- **API**：`GetCodingPlanUsage`（公网 OpenAPI）、`GetAFPUsage`、`GetPersonalPlan`、`ListArkCodingPlanModel`、`ListFoundationModels`、`ListModelActivations`
- **桌面端**：SwiftUI + AppKit `NSStatusItem`，无第三方依赖
- **平台扩展**：`Provider` 协议抽象，`ProviderKind` / `makeProvider` 中注册新平台即可

## 版本更新历史

见 [CHANGELOG.md](CHANGELOG.md) 与 [GitHub Releases](https://github.com/boommanpro/coding-balance/releases)。

## 相关链接

- 项目官网：https://boommanpro.github.io/coding-balance/
- 官方 Ark CLI：https://ark.volcengine.com/region:cn-beijing/docs/ark/ark-cli
- 签名方法：https://www.volcengine.com/docs/6369/67269
- Base URL 及鉴权：https://docs.volcengine.com/docs/82379/1298459
- AFP 抵扣规则：https://docs.volcengine.com/docs/82379/2516283
- Venice API 文档：https://docs.venice.ai/api-reference/api-spec

## License

[MIT](LICENSE)
