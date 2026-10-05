import SwiftUI

/// 弹窗「模型」页：可用模型 + 限流（QPS≈RPM/60）+ 价格（元/百万tokens）
/// 支持按来源过滤（全部/套餐内/其他），点击表头按 QPS/RPM/TPM/输入/输出价格排序（空值排末尾），
/// 点击模型行可复制模型名。
struct ModelsView: View {
    @EnvironmentObject var appState: AppState

    @State private var sourceFilter: SourceFilter = .all
    @State private var sortKey: SortKey = .name
    @State private var sortAscending = true
    @State private var copiedName: String?

    private var account: Account? { appState.activeAccount }

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case codingPlan = "套餐内"
        case other = "其他"
        var id: String { rawValue }
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case name = "模型"
        case qps = "QPS"
        case rpm = "RPM"
        case tpm = "TPM"
        case priceIn = "输入"
        case priceOut = "输出"
        var id: String { rawValue }
    }

    /// 数值列宽（与表头保持一致，保证对齐；数字窄列，给模型名留出更多空间）
    private let qpsCol: CGFloat = 32
    private let rpmCol: CGFloat = 38
    private let tpmCol: CGFloat = 36
    private let priceCol: CGFloat = 32

    var body: some View {
        Group {
            if let account = account {
                if let error = appState.modelErrors[account.id], !error.isEmpty {
                    errorCard(error, account: account)
                } else if let models = appState.modelInfos[account.id], !models.isEmpty {
                    modelList(models, account: account)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在加载 \(account.shortLabel) 的模型…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 10)
                }
            } else {
                Text("请先配置账户")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
    }

    private func errorCard(_ message: String, account: Account) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("模型数据获取失败", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(.red)
            Text(message)
                .font(.caption)
                .foregroundColor(.red)
            Button("重试") {
                Task { await appState.refreshModels(account: account) }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: 列表

    private func modelList(_ models: [ModelInfo], account: Account) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar(models: models)
                .padding(.bottom, 8)

            headerRow
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

            Divider()

            let rows = sorted(models)
            ForEach(rows) { model in
                ModelRowView(model: model,
                             copied: copiedName == model.name,
                             qpsCol: qpsCol, rpmCol: rpmCol, tpmCol: tpmCol, priceCol: priceCol) {
                    copy(name: model.name)
                }
                Divider()
            }
            if rows.isEmpty {
                Text("该分类下暂无模型")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func toolbar(models: [ModelInfo]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(filtered(models).count) 个模型")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("价格：元/百万tokens")
                    .font(.caption2)
                    .foregroundColor(Color.secondary.opacity(0.6))
            }
            HStack(spacing: 8) {
                Picker("", selection: $sourceFilter) {
                    ForEach(SourceFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                Spacer()
                Button {
                    sortKey = .name
                    sortAscending = true
                } label: {
                    Label("默认排序", systemImage: "arrow.uturn.backward")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("恢复为模型名称排序")
            }
        }
    }

    // MARK: 表头（点击排序）

    private var headerRow: some View {
        HStack(spacing: 8) {
            sortButton(.name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortButton(.qps).frame(width: qpsCol, alignment: .trailing)
            sortButton(.rpm).frame(width: rpmCol, alignment: .trailing)
            sortButton(.tpm).frame(width: tpmCol, alignment: .trailing)
            sortButton(.priceIn).frame(width: priceCol, alignment: .trailing)
            sortButton(.priceOut).frame(width: priceCol, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundColor(.secondary)
    }

    private func sortButton(_ key: SortKey) -> some View {
        Button {
            if sortKey == key {
                sortAscending.toggle()
            } else {
                sortKey = key
                sortAscending = true
            }
        } label: {
            HStack(spacing: 2) {
                Text(key.rawValue)
                Image(systemName: sortKey == key
                      ? (sortAscending ? "chevron.up" : "chevron.down")
                      : "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(sortKey == key ? 1 : 0.35)
            }
        }
        .buttonStyle(.plain)
        .help("按\(key.rawValue)\(sortKey == key ? (sortAscending ? "升序" : "降序") : "排序")（空值排末尾）")
    }

    // MARK: 过滤 / 排序

    private func filtered(_ models: [ModelInfo]) -> [ModelInfo] {
        switch sourceFilter {
        case .all: return models
        case .codingPlan: return models.filter { $0.isCodingPlan }
        case .other: return models.filter { !$0.isCodingPlan }
        }
    }

    private func sorted(_ models: [ModelInfo]) -> [ModelInfo] {
        var list = filtered(models)
        if sortKey == .name {
            list.sort { a, b in
                if a.isCodingPlan != b.isCodingPlan {
                    return sortAscending ? a.isCodingPlan : !a.isCodingPlan   // 套餐内优先（降序时靠后）
                }
                let cmp = a.name.localizedStandardCompare(b.name) == .orderedAscending
                return sortAscending ? cmp : !cmp
            }
            return list
        }
        list.sort { a, b in
            let ka = sortValue(a), kb = sortValue(b)
            switch (ka, kb) {
            case (nil, nil):
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case (nil, _): return false                    // 空值排末尾
            case (_, nil): return true
            case (let x?, let y?): return sortAscending ? x < y : x > y
            }
        }
        return list
    }

    private func sortValue(_ model: ModelInfo) -> Double? {
        switch sortKey {
        case .qps: return model.qps
        case .rpm: return model.rpm
        case .tpm: return model.tpm
        case .priceIn: return model.priceIn
        case .priceOut: return model.priceOut
        case .name: return nil
        }
    }

    // MARK: 复制

    private func copy(name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copiedName = name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedName == name { copiedName = nil }
        }
    }
}

/// 单个模型行（表格样式）：模型名（可复制）+ QPS/RPM/TPM + 输入/输出单价
struct ModelRowView: View {
    let model: ModelInfo
    let copied: Bool
    let qpsCol: CGFloat
    let rpmCol: CGFloat
    let tpmCol: CGFloat
    let priceCol: CGFloat
    let onCopy: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(model.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.isCodingPlan {
                    Text("套餐")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        .foregroundColor(.accentColor)
                }
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(copied ? .green : Color.secondary.opacity(0.55))
                    .opacity(copied || hovering ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(metric(model.qps)).frame(width: qpsCol, alignment: .trailing)
            Text(metric(model.rpm)).frame(width: rpmCol, alignment: .trailing)
            Text(metric(model.tpm)).frame(width: tpmCol, alignment: .trailing)
            Text(priceText(model.priceIn)).frame(width: priceCol, alignment: .trailing)
            Text(priceText(model.priceOut)).frame(width: priceCol, alignment: .trailing)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    private func metric(_ value: Double?) -> String {
        guard let value = value else { return "-" }
        return formatCompact(value)
    }

    private func priceText(_ value: Double?) -> String {
        guard let value = value else { return "-" }
        return formatPriceShort(value)
    }

    private var tooltip: String {
        // 第一行始终展示完整模型名（长名称被截断时悬停可看全）
        var parts = [model.name]
        if copied {
            parts.append("已复制到剪贴板")
        } else {
            parts.append("点击复制模型名")
        }
        if let tpd = model.tpd, tpd > 0 {
            parts.append("TPD \(formatCompact(tpd))")
        }
        if let extra = model.priceExtra, !extra.isEmpty {
            parts.append(extra)
        }
        return parts.joined(separator: "\n")
    }
}
