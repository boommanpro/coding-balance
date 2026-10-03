# 更新历史

本项目采用 [语义化版本](https://semver.org/lang/zh-CN/)，`v*` 标签触发自动构建并发布到 GitHub Releases。

## v1.0.0 (2026-10-03)

首个正式版本。

**功能**
- 菜单栏圆形「近 5 小时剩余」指示环 + 百分比（绿 / 橙 / 红三级告警）
- 左键点击弹出详情面板：5h 大圆环主视觉、周/月剩余统计、三个额度窗口进度条与下次重置时间
- 右键点击快捷菜单：刷新 / 管理账户 / 退出
- 多账户支持：顶部选择器与账户总览双入口切换「当前使用账户」，切换即时刷新并持久化
- 每 60 秒自动刷新；支持 Coding Plan（百分比额度）与 Agent Plan（AFP 绝对额度）
- 账户数据本地保存，AK/SK 不离开本机（仅用于请求官方管控面 API）

**技术**
- 原生 macOS 菜单栏应用：SwiftUI 界面 + AppKit `NSStatusItem`，无第三方依赖
- 火山引擎 HMAC-SHA256 签名，官方管控面 API（`GetCodingPlanUsage` / `GetAFPUsage` / `GetPersonalPlan` 等）
- 平台抽象为 `Provider` 协议，便于后续扩展其他平台
