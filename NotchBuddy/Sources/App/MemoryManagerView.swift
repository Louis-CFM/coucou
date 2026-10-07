import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MemoryManagerModel: ObservableObject {
    @Published var filter = MemoryFilter()
    @Published var page = MemoryPage(items: [], total: 0, limit: 25, offset: 0)
    @Published var selected: MemoryRecord?
    @Published var safeDetail: SafeMemoryDetail?
    @Published var isLoading = false
    @Published var status: String?
    @Published var confirmedScope: ConfirmedMemoryScope?
    @Published var confirmedRetirement: ConfirmedMemoryRetirement?
    @Published private(set) var pendingQuery: String?
    @Published private(set) var pendingDocumentIds: [String] = []
    private var requestState = MemoryManagerRequestState()
    private var listTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    var config: HindsightConfig { AppState.shared.hindsightConfig }
    var canGoBack: Bool { page.offset > 0 }
    var canGoForward: Bool { page.offset + page.items.count < page.total }

    func setPendingQuery(_ query: String) { pendingQuery = query; pendingDocumentIds = [] }
    func setPendingDocumentIds(_ ids: [String]) { pendingDocumentIds = deduplicated(ids); pendingQuery = nil }

    func consumePendingQuery() {
        if !pendingDocumentIds.isEmpty { filter.documentId = nil; filter.query = nil; load(offset: 0); return }
        guard let query = pendingQuery else { return }
        pendingQuery = nil
        filter.documentId = nil
        filter.query = query
        load(offset: 0)
    }

    func load(offset: Int? = nil) {
        let requestedGeneration = requestState.beginList()
        listTask?.cancel()
        detailTask?.cancel()
        selected = nil
        safeDetail = nil
        isLoading = requestState.isListLoading
        status = nil
        let request = MemoryBrowseRequest(filter: filter, limit: page.limit, offset: offset ?? page.offset)
        listTask = Task {
            defer {
                if requestState.finishList(requestedGeneration) { isLoading = requestState.isListLoading }
            }
            do {
                let service = try HindsightService(config: config)
                let response: MemoryPage
                if pendingDocumentIds.isEmpty {
                    response = try await service.memoryList(request)
                } else {
                    let records = try await completeDocumentUnion(documentIds: pendingDocumentIds, pageSize: request.limit) { documentId, limit, pageOffset in
                        try await service.listMemories(options: MemoryListOptions(filter: request.filter, documentId: documentId, limit: limit, offset: pageOffset))
                    }
                    response = documentUnionPage(records, limit: request.limit, offset: request.offset)
                }
                guard !Task.isCancelled, requestedGeneration == requestState.listGeneration else { return }
                page = response
            } catch let error as HindsightServiceError where error.kind == .cancelled {
                return
            } catch {
                guard !Task.isCancelled, requestedGeneration == requestState.listGeneration else { return }
                status = error.localizedDescription
            }
        }
    }

    func select(_ memory: MemoryRecord) {
        let requestedGeneration = requestState.beginDetail(id: memory.id)
        detailTask?.cancel()
        selected = memory
        detailTask = Task {
            do {
                let service = try HindsightService(config: config)
                async let current = service.memoryGet(id: memory.id)
                async let safe = service.memorySafeDetail(id: memory.id)
                let values = try await (current, safe)
                guard !Task.isCancelled, requestState.acceptsDetail(requestedGeneration, id: memory.id) else { return }
                selected = values.0
                safeDetail = values.1
            } catch {
                guard !Task.isCancelled, requestState.acceptsDetail(requestedGeneration, id: memory.id) else { return }
                status = error.localizedDescription
            }
        }
    }

    func save(_ update: MemoryUpdate, overwrite: Bool = false) async -> MemoryUpdateResult? {
        guard let opened = selected else { return nil }
        do {
            let result = try await HindsightService(config: config).memoryUpdate(id: opened.id, opened: opened, update: update, overwrite: overwrite)
            if case .updated(let memory, _) = result { selected = memory; load() }
            return result
        } catch { status = error.localizedDescription; return nil }
    }

    func prepareRetire(_ memory: MemoryRecord) {
        do { confirmedRetirement = try ConfirmedMemoryRetirement(record: memory, config: config) }
        catch { status = error.localizedDescription }
    }

    func performRetire() {
        guard let confirmation = confirmedRetirement else { return }
        Task {
            do {
                _ = try await HindsightService(config: config).memoryRetire(confirmed: confirmation)
                confirmedRetirement = nil
                selected = nil
                load()
            } catch { status = error.localizedDescription }
        }
    }

    func restore(_ memory: MemoryRecord) {
        Task {
            do {
                _ = try await HindsightService(config: config).memoryRestore(id: memory.id)
                selected = nil
                load()
            } catch { status = error.localizedDescription }
        }
    }

    func prepareBulkRetire() {
        guard filter.state == .valid else { return }
        do { confirmedScope = try ConfirmedMemoryScope(request: .init(filter: filter, limit: page.limit, offset: page.offset), config: config) }
        catch { status = error.localizedDescription }
    }

    func performBulkRetire() {
        guard let scope = confirmedScope else { return }
        confirmedScope = nil
        Task {
            do {
                try scope.validate(current: config)
                let result = try await HindsightService(config: config).memoryBulkRetire(scope.request)
                load(offset: 0)
                if result.failed.isEmpty { status = "Retired \(result.succeeded.count) memories." }
                else { status = "Retired \(result.succeeded.count) of \(result.requested). Failed: " + result.failed.map { "\($0.id): \($0.message)" }.joined(separator: "; ") }
            } catch { status = error.localizedDescription }
        }
    }

    func export(_ format: MemoryExportFormat) {
        do {
            let credential = KeychainStore.shared.get(hindsightBearerTokenKey) ?? ""
            let exported = try MemoryExportFormatter.format(page.items, as: format, credential: credential)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = exported.filename
            panel.allowedContentTypes = format == .json ? [.json] : [.plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try exported.content.write(to: url, atomically: true, encoding: .utf8)
            status = "Exported \(page.items.count) loaded memories."
        } catch { status = error.localizedDescription }
    }
}

struct MemoryManagerView: View {
    @ObservedObject var model: MemoryManagerModel
    @State private var editor: MemoryEditor?
    @State private var conflict: MemoryRecord?

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            HSplitView {
                results.frame(minWidth: 340)
                detail.frame(minWidth: 360)
            }
            if let status = model.status { Text(status).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if model.pendingQuery != nil || !model.pendingDocumentIds.isEmpty { model.consumePendingQuery() }
            else if model.page.items.isEmpty { model.load(offset: 0) }
        }
        .onChange(of: model.pendingQuery) { _, query in if query != nil { model.consumePendingQuery() } }
        .onChange(of: model.pendingDocumentIds) { _, ids in if !ids.isEmpty { model.consumePendingQuery() } }
        .sheet(item: $editor) { value in editSheet(value) }
        .confirmationDialog("Retire matching valid memories?", isPresented: Binding(get: { model.confirmedScope != nil }, set: { if !$0 { model.confirmedScope = nil } })) {
            Button("Retire matching valid memories", role: .destructive) { model.performBulkRetire() }
            Button("Cancel", role: .cancel) { model.confirmedScope = nil }
        } message: {
            if let scope = model.confirmedScope { Text("Tenant: \(scope.tenant)\nBank: \(scope.bank)\nCurrent result count: \(model.page.total)\nFilters: \(scope.request.filter.summary)") }
        }
        .confirmationDialog("Retire 1 memory?", isPresented: Binding(get: { model.confirmedRetirement != nil }, set: { if !$0 { model.confirmedRetirement = nil } })) {
            Button("Retire 1 memory", role: .destructive) { model.performRetire() }
            Button("Cancel", role: .cancel) { model.confirmedRetirement = nil }
        } message: {
            if let confirmation = model.confirmedRetirement { Text("ID: \(confirmation.id)\nExcerpt: \(String(confirmation.text.prefix(160)))\nTenant: \(confirmation.tenant)\nBank: \(confirmation.bank)\nRetirement is reversible from the Retired view.") }
        }
    }

    private var filters: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search memories", text: Binding(get: { model.filter.query ?? "" }, set: { model.filter.query = $0.isEmpty ? nil : $0 }))
                Picker("State", selection: $model.filter.state) { Text("Valid").tag(MemoryState.valid); Text("Retired").tag(MemoryState.invalidated) }
                Picker("Type", selection: $model.filter.factType) { Text("Any type").tag(nil as MemoryFactType?); Text("World").tag(MemoryFactType.world as MemoryFactType?); Text("Experience").tag(MemoryFactType.experience as MemoryFactType?); Text("Observation").tag(MemoryFactType.observation as MemoryFactType?) }
                Picker("Platform", selection: $model.filter.platform) { Text("Any platform").tag(nil as MemoryPlatform?); Text("macOS").tag(MemoryPlatform.macos as MemoryPlatform?); Text("Windows").tag(MemoryPlatform.windows as MemoryPlatform?) }
                Button("Apply") { model.load(offset: 0) }
            }
            HStack {
                TextField("Start (ISO 8601)", text: optional($model.filter.startDate))
                TextField("End (ISO 8601)", text: optional($model.filter.endDate))
                Picker("Time", selection: $model.filter.timeField) { Text("Any time").tag(nil as MemoryTimeField?); ForEach([MemoryTimeField.createdAt, .updatedAt, .mentionedAt, .occurredStart, .occurredEnd, .editedAt], id: \.self) { Text($0.rawValue).tag($0 as MemoryTimeField?) } }
                Picker("Retention", selection: $model.filter.retentionKind) { Text("Any retention").tag(nil as RetentionKind?); Text("Explicit").tag(RetentionKind.explicit as RetentionKind?); Text("Inferred").tag(RetentionKind.inferred as RetentionKind?) }
                Picker("Source", selection: $model.filter.sourceKind) { Text("Any source").tag(nil as MemorySourceKind?); Text("Chat").tag(MemorySourceKind.chat as MemorySourceKind?); Text("Selected text").tag(MemorySourceKind.selectedText as MemorySourceKind?) }
            }
        }.padding(10)
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                Button("‹") { model.load(offset: max(0, model.page.offset - model.page.limit)) }.disabled(!model.canGoBack)
                Text(model.page.total == 0 ? "0–0 of 0" : "\(model.page.offset + 1)–\(min(model.page.offset + model.page.items.count, model.page.total)) of \(model.page.total)").monospacedDigit()
                Button("›") { model.load(offset: model.page.offset + model.page.limit) }.disabled(!model.canGoForward)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Menu("Export") { Button("JSON") { model.export(.json) }; Button("Markdown") { model.export(.markdown) } }
                Button("Retire all…", role: .destructive) { model.prepareBulkRetire() }.disabled(model.filter.state != .valid || model.page.total == 0)
            }.padding(8)
            List(model.page.items, id: \.id, selection: Binding(get: { model.selected?.id }, set: { id in if let memory = model.page.items.first(where: { $0.id == id }) { model.select(memory) } })) { memory in
                VStack(alignment: .leading, spacing: 3) { Text(memory.text).lineLimit(2); Text("\(memory.factType.rawValue) · \(memory.updatedAt ?? memory.createdAt ?? "unknown time")").font(.caption).foregroundStyle(.secondary) }.tag(memory.id)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let memory = model.selected, let safe = model.safeDetail {
            ScrollView { VStack(alignment: .leading, spacing: 12) {
                Text(safe.content).textSelection(.enabled).font(.title3)
                LabeledContent("ID", value: safe.id); LabeledContent("State", value: safe.state.rawValue); LabeledContent("Type", value: safe.factType.rawValue)
                LabeledContent("Tenant", value: safe.tenant); LabeledContent("Bank", value: safe.bank)
                if let context = safe.context { LabeledContent("Context", value: context) }
                LabeledContent("Tags", value: safe.tags.joined(separator: ", ")); LabeledContent("Entities", value: safe.entities.joined(separator: ", "))
                if let value = safe.documentId { LabeledContent("Document ID", value: value) }; if let value = safe.chunkId { LabeledContent("Chunk ID", value: value) }
                if !safe.sourceFactIds.isEmpty { LabeledContent("Source fact IDs", value: safe.sourceFactIds.joined(separator: ", ")) }
                ForEach(safe.metadata.keys.sorted(), id: \.self) { key in LabeledContent(key, value: safe.metadata[key] ?? "") }
                HStack { if memory.factType != .observation { Button("Edit") { editor = MemoryEditor(memory) } }; Button(memory.state == .valid ? "Retire…" : "Restore") { if memory.state == .valid { model.prepareRetire(memory) } else { model.restore(memory) } } }
            }.padding() }
        } else { ContentUnavailableView("Select a memory", systemImage: "brain") }
    }

    private func editSheet(_ value: MemoryEditor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(conflict == nil ? "Edit memory" : "Memory changed remotely").font(.headline)
            if let conflict { Text("Current server text: \(conflict.text)").textSelection(.enabled) }
            TextEditor(text: Binding(get: { editor?.text ?? "" }, set: { editor?.text = $0 })).frame(minHeight: 120)
            TextField("Context", text: Binding(get: { editor?.context ?? "" }, set: { editor?.context = $0 }))
            Picker("Type", selection: Binding(get: { editor?.factType ?? value.factType }, set: { editor?.factType = $0 })) { Text("World").tag(MemoryFactType.world); Text("Experience").tag(MemoryFactType.experience) }
            HStack { Button("Cancel") { editor = nil; conflict = nil }; Spacer(); Button(conflict == nil ? "Save" : "Overwrite") { Task { if let editor, let result = await model.save(editor.update, overwrite: conflict != nil) { if case .conflict(let current) = result { conflict = current } else { self.editor = nil; conflict = nil } } } }.buttonStyle(.borderedProminent).disabled((editor?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) }
        }.padding(20).frame(width: 520)
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> { Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }) }
}

private struct MemoryEditor: Identifiable {
    let id: String; var text: String; var context: String; var factType: MemoryFactType
    init(_ memory: MemoryRecord) { id = memory.id; text = memory.text; context = memory.context ?? ""; factType = memory.factType }
    var update: MemoryUpdate { .init(text: text, context: context.isEmpty ? nil : context, factType: factType) }
}

private extension MemoryFilter {
    var summary: String {
        let values = [
            "state=\(state.rawValue)",
            query.map { "text=\($0)" },
            documentId.map { "document=\($0)" },
            factType.map { "type=\($0.rawValue)" },
            startDate.map { "start=\($0)" },
            endDate.map { "end=\($0)" },
            timeField.map { "time=\($0.rawValue)" },
            platform.map { "platform=\($0.rawValue)" },
            retentionKind.map { "retention=\($0.rawValue)" },
            sourceKind.map { "source=\($0.rawValue)" },
        ].compactMap { $0 }
        return values.isEmpty ? "none" : values.joined(separator: ", ")
    }
}
