import SwiftUI

/// 弹窗「模型」页：可用模型 + 限流（QPS≈RPM/60）+ 价格
struct ModelsView: View {
    @EnvironmentObject var appState: AppState

    private var account: Account? { appState.activeAccount }

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

    private func modelList(_ models: [ModelInfo], account: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(models.count) 个模型")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("QPS≈RPM/60")
                    .font(.caption2)
                    .foregroundColor(Color.secondary.opacity(0.6))
            }
            ForEach(models) { model in
                ModelRowView(model: model)
            }
        }
    }
}

/// 单个模型行：模型名 + 价格 + QPS/RPM/TPM/TPD 指标
struct ModelRowView: View {
    let model: ModelInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let price = model.price {
                    Text(price)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 12) {
                metric(label: "QPS", value: formatMetric(model.qps))
                metric(label: "RPM", value: formatMetric(model.rpm))
                metric(label: "TPM", value: formatMetric(model.tpm))
                if let tpd = model.tpd, tpd > 0 {
                    metric(label: "TPD", value: formatMetric(tpd))
                }
                Spacer()
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func metric(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundColor(Color.secondary.opacity(0.6))
            Text(value)
        }
    }

    private func formatMetric(_ value: Double?) -> String {
        guard let value = value else { return "-" }
        return formatCompact(value)
    }
}
