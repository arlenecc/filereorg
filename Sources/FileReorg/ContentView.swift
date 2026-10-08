import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = OrganizerModel()

    private var pickerBinding: Binding<Bool> {
        Binding(
            get: { model.showDirectoryPicker },
            set: { model.showDirectoryPicker = $0 }
        )
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // 配置区：上部 1/3
                configSection
                    .frame(height: geo.size.height / 3, alignment: .top)
                Divider()
                // 处理过程区：下部 2/3
                processSection
            }
        }
        .fileImporter(
            isPresented: pickerBinding,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.setRoot(url)
            }
        }
    }

    // MARK: - 配置区（上 1/3）

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("文件重组织工具")
                    .font(.title2).bold()
                Spacer()
                phaseBadge
            }
            HStack(spacing: 10) {
                Text("目标目录:").foregroundStyle(.secondary)
                TextField("/path/to/directory", text: $model.rootPathText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isBusy)
                Button("选择目录…") { model.showDirectoryPicker = true }
                    .disabled(model.isBusy)
                analysisButton
            }
            Text("流程：选择目录 → 开始分析（遍历文件 + SHA-256 全局排重）→ 开始处理（按创建年份建立 4 位数字文件夹归档，保留原目录结构；重复文件将被删除；完成后自动清理变空的原始目录）")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
    }

    private var analysisButton: some View {
        Group {
            if model.phase == .scanning || model.phase == .hashing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("分析中…").foregroundStyle(.secondary)
                }
            } else {
                Button("开始分析") { model.startAnalysis() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartAnalysis)
            }
        }
    }

    private var phaseBadge: some View {
        let info: (String, Color) = {
            switch model.phase {
            case .idle: return ("空闲", .secondary)
            case .scanning: return ("扫描中", .blue)
            case .hashing: return ("排重中", .blue)
            case .ready: return ("待处理", .orange)
            case .organizing: return ("处理中", .blue)
            case .done: return ("已完成", .green)
            case .cancelled: return ("已取消", .secondary)
            case .failed: return ("失败", .red)
            }
        }()
        return Text(info.0)
            .font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(info.1.opacity(0.15), in: Capsule())
            .foregroundStyle(info.1)
    }

    // MARK: - 处理过程区（下 2/3）

    private var processSection: some View {
        VStack(spacing: 0) {
            statsHeader
                .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            logArea
            Divider()
            statusBar
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var statsHeader: some View {
        HStack(spacing: 24) {
            statGroup("分析结果") {
                StatItem(label: "文件数", value: "\(model.summary.scannedFiles)")
                StatItem(label: "总大小", value: ByteFmt.format(model.summary.scannedBytes))
            }
            headerDivider
            statGroup("排重结果") {
                StatItem(label: "保留文件", value: "\(model.summary.uniqueFiles)")
                StatItem(label: "重复文件", value: "\(model.summary.duplicateFiles)")
                StatItem(label: "可释放空间", value: ByteFmt.format(model.summary.wastedBytes), color: .orange)
            }
            headerDivider
            statGroup("预计处理后") {
                StatItem(label: "目录数", value: "\(model.summary.estDirCount)")
                StatItem(label: "文件数", value: "\(model.summary.estFileCount)")
                StatItem(label: "总大小", value: ByteFmt.format(model.summary.estBytes), color: .green)
            }
            Spacer(minLength: 16)
            Button("开始处理") { model.startProcessing() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canStartProcessing)
        }
    }

    private var headerDivider: some View {
        Divider().frame(height: 36)
    }

    @ViewBuilder
    private func statGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).bold().foregroundStyle(.secondary)
            HStack(spacing: 18) { content() }
        }
    }

    // MARK: - 过程日志

    private var logArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.logs.isEmpty {
                        Text("处理过程日志将显示在这里")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(model.logs) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(Fmt.time(entry.date))
                                .foregroundStyle(.tertiary)
                            Text(entry.text)
                                .foregroundStyle(color(for: entry.severity))
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .id(entry.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.logs.last?.id) { newValue in
                if let id = newValue {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.progressIndeterminate {
                ProgressView().controlSize(.small)
            } else {
                ProgressView(value: model.overallProgress)
                    .frame(width: 240)
                Text("\(Int((model.overallProgress * 100).rounded()))%")
                    .font(.callout).monospacedDigit()
                    .frame(width: 44, alignment: .leading)
            }
            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if model.isBusy {
                Button("取消") { model.cancelWork() }
                    .buttonStyle(.bordered)
            }
            if model.phase == .organizing {
                Text("已处理 \(model.summary.processedDone)/\(model.summary.processedTotal)")
                    .font(.footnote).monospacedDigit()
            }
        }
    }

    // MARK: - 工具

    private func color(for severity: LogSeverity) -> Color {
        switch severity {
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - 小组件

private struct StatItem: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded)).bold()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

enum Fmt {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
