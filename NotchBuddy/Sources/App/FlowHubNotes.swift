#if !APPSTORE
import AppKit
import SwiftUI

/// Coucou Flow → Notetaker: the calls on the left, the one chosen on the right.
struct HubNotesPage: View {
    @ObservedObject private var taker = NoteTaker.shared
    @ObservedObject private var parakeet = Parakeet.shared
    @State private var selected: UUID?

    private var shown: Note? {
        if let recording = taker.recording, selected == nil || selected == recording.id { return recording }
        if let selected, let note = taker.note(selected) { return note }
        return taker.notes.first
    }

    var body: some View {
        VStack(spacing: 0) {
        HubHero(page: .notes, title: String(localized: "hub.page.notes"),
                subtitle: String(localized: "hub.notes-promo"), compact: true)
            .padding(.horizontal, 28)
            .padding(.top, 24)
        HStack(spacing: 0) {
            HubNotesList(selected: $selected)
                .frame(width: 280)
                .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
            Group {
                if !parakeet.isReady && taker.notes.isEmpty && taker.recording == nil {
                    HubNotesSetup()
                } else if let note = shown {
                    if note.id == taker.recording?.id {
                        HubLiveNote(note: note)
                    } else {
                        HubNoteDetail(note: note)
                    }
                } else {
                    HubNotesEmpty()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        }
    }
}

// MARK: - List

private struct HubNotesList: View {
    @Binding var selected: UUID?
    @ObservedObject private var taker = NoteTaker.shared
    @ObservedObject private var parakeet = Parakeet.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubRecordButton {
                selected = nil
            }
            .padding(.top, 16)
            if let error = taker.startError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(groups) { group in
                        HubLabel(group.title)
                            .padding(.horizontal, 6)
                            .padding(.top, 12)
                            .padding(.bottom, 2)
                        ForEach(group.notes) { note in
                            HubNoteRow(note: note, selected: isSelected(note)) { selected = note.id }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 11))
                    .padding(.top, 1)
                Text("notes.legal")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(HubTheme.secondary)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(HubTheme.card))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func isSelected(_ note: Note) -> Bool {
        if let selected { return selected == note.id }
        return note.id == (taker.recording?.id ?? taker.notes.first?.id)
    }

    private var groups: [HubNoteGroup] {
        var out: [HubNoteGroup] = []
        for note in taker.notes {
            let title = HubHomePage.dayTitle(note.start)
            if let last = out.indices.last, out[last].title == title {
                out[last].notes.append(note)
            } else {
                out.append(HubNoteGroup(title: title, notes: [note]))
            }
        }
        return out
    }
}

private struct HubNoteGroup: Identifiable {
    let title: String
    var notes: [Note]
    var id: String { title }
}

/// "Record a call" / "Stop".
struct HubRecordButton: View {
    var onStart: () -> Void = {}
    @ObservedObject private var taker = NoteTaker.shared
    @ObservedObject private var parakeet = Parakeet.shared

    var body: some View {
        Button {
            if taker.isRecording {
                taker.stop()
            } else {
                onStart()
                Task { await taker.start() }
            }
        } label: {
            HStack(spacing: 8) {
                if taker.isRecording {
                    RoundedRectangle(cornerRadius: 2).fill(HubTheme.onAccent).frame(width: 10, height: 10)
                    Text("notes.stop")
                } else {
                    Circle().fill(HubTheme.onAccent).frame(width: 10, height: 10)
                    Text("hub.record-call")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(HubButtonStyle(primary: true))
        .disabled(!parakeet.isReady && !taker.isRecording)
    }
}

private struct HubNoteRow: View {
    let note: Note
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(note.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? HubTheme.text : Color(hex: "#D5D7DB"))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(note.status == .recording ? HubTheme.red : HubTheme.secondary)
                    Spacer(minLength: 4)
                    HStack(spacing: 3) {
                        ForEach(note.speakers.prefix(5)) { speaker in
                            Circle().fill(HubTheme.speaker(speaker.color)).frame(width: 8, height: 8)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(selected ? 0.07 : (hover ? 0.035 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var subtitle: String {
        let time = note.start.formatted(date: .omitted, time: .shortened)
        switch note.status {
        case .recording:  return String(localized: "notes.recording")
        case .processing: return time + " · " + String(localized: "notes.processing-short")
        case .failed:     return time + " · " + String(localized: "notes.failed-short")
        case .ready:
            let minutes = max(1, Int((note.duration / 60).rounded()))
            return time + " · " + String(format: String(localized: "hub.minutes %lld"), minutes)
        }
    }
}

// MARK: - States

private struct HubNotesSetup: View {
    @ObservedObject private var parakeet = Parakeet.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HubLiveMochi(color: "#3B9EFF", size: 54, outfit: .roundGlasses)
                .frame(height: 50)
            HubCard(padding: 20) {
                Text("notes.setup-title")
                    .font(.system(size: 15, weight: .bold))
                Text("notes.setup")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#C7CAD0"))
                    .fixedSize(horizontal: false, vertical: true)
                switch parakeet.state {
                case .unsupported:
                    Text("hub.engine.unsupported")
                        .font(.system(size: 13))
                        .foregroundColor(HubTheme.accent)
                case .downloading(let fraction):
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 320)
                default:
                    Button(String(localized: "notes.setup-download")) { parakeet.download() }
                        .buttonStyle(HubButtonStyle(primary: true))
                }
            }
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
    }
}

private struct HubNotesEmpty: View {
    var body: some View {
        HubEmptyState(text: String(localized: "notes.empty"), state: .idle, color: "#3B9EFF")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The call being recorded: the time, the two levels, the live transcript.
private struct HubLiveNote: View {
    let note: Note
    @ObservedObject private var taker = NoteTaker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Circle().fill(HubTheme.red).frame(width: 10, height: 10)
                TimelineView(.periodic(from: note.start, by: 1)) { context in
                    Text(NoteBuilder.clock(context.date.timeIntervalSince(note.start)))
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                }
                Spacer()
                Button(String(localized: "notes.stop")) { taker.stop() }
                    .buttonStyle(HubButtonStyle(primary: true))
            }
            HStack(spacing: 18) {
                HubLevel(label: String(localized: "notes.me"), level: taker.micLevel, color: HubTheme.speaker(0))
                HubLevel(label: String(localized: "notes.others"), level: taker.systemLevel, color: HubTheme.speaker(1))
            }
            HubLabel(String(localized: "notes.live"))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if note.lines.isEmpty {
                            Text("notes.live-empty")
                                .font(.system(size: 13))
                                .foregroundColor(HubTheme.secondary)
                        }
                        ForEach(note.lines) { line in
                            HubLineView(name: line.speaker == NoteBuilder.meID ? String(localized: "notes.me") : String(localized: "notes.others"),
                                        color: HubTheme.speaker(line.speaker == NoteBuilder.meID ? 0 : 1),
                                        line: line)
                                .id(line.id)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .onChange(of: note.lines.count) {
                    if let last = note.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
    }
}

private struct HubLevel: View {
    let label: String
    let level: Float
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(HubTheme.secondary)
                .frame(width: 80, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule().fill(color)
                        .frame(width: max(4, geo.size.width * CGFloat(min(1, sqrt(Double(level)) * 3))))
                        .animation(.easeOut(duration: 0.3), value: level)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One line of a transcript: who, when, what.
private struct HubLineView: View {
    let name: String
    let color: Color
    let line: NoteLine

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black.opacity(0.8))
                .frame(width: 24, height: 24)
                .background(Circle().fill(color))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(color)
                    Text(NoteBuilder.clock(line.start))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(HubTheme.muted)
                }
                Text(line.text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundColor(HubTheme.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - A noted call

private struct HubNoteDetail: View {
    let note: Note
    @ObservedObject private var taker = NoteTaker.shared
    @State private var tab = 0
    @State private var title = ""
    @State private var copied = false
    @State private var renaming: NoteSpeaker?
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if note.status == .processing || taker.working.contains(note.id) && note.lines.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("notes.processing")
                            .font(.system(size: 13))
                            .foregroundColor(HubTheme.secondary)
                    }
                } else if note.status == .failed {
                    failed
                } else {
                    speakers
                    Picker("", selection: $tab) {
                        Text("notes.summary").tag(0)
                        Text("notes.transcript").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if tab == 0 { summary } else { transcript }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 30)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .onAppear { title = note.title }
        .onChange(of: note.id) { title = note.title; tab = 0 }
        .onChange(of: note.title) { title = note.title }
        .alert(String(localized: "notes.rename-speaker"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(String(localized: "notes.rename-placeholder"), text: $newName)
            Button(String(localized: "hub.save")) {
                if let speaker = renaming { taker.rename(note.id, speaker: speaker.id, to: newName) }
                renaming = nil
            }
            Button(String(localized: "hub.cancel"), role: .cancel) { renaming = nil }
        }
        .alert(String(localized: "notes.delete-confirm"), isPresented: $confirmDelete) {
            Button(String(localized: "hub.delete"), role: .destructive) { taker.delete(note.id) }
            Button(String(localized: "hub.cancel"), role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .bold))
                    .onSubmit { taker.rename(note.id, title: title) }
                Text(dateLine)
                    .font(.system(size: 13))
                    .foregroundColor(HubTheme.secondary)
            }
            Spacer(minLength: 0)
            if note.status == .ready {
                Button {
                    NSPasteboard.copyText(taker.markdown(note))
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? String(localized: "notes.copied") : String(localized: "notes.copy-markdown"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(HubButtonStyle())
            }
            Menu {
                if note.status == .ready {
                    Button(String(localized: "notes.export")) { taker.export(note) }
                    Button(String(localized: "notes.summarize-again")) { Task { await taker.summarize(note.id) } }
                        .disabled(taker.summaryEngine == .off || note.lines.isEmpty)
                    Divider()
                }
                Button(String(localized: "hub.delete"), role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: "#1D1E22")))
        }
    }

    private var dateLine: String {
        var parts = [note.start.formatted(.dateTime.weekday(.wide).day().month(.wide))]
        let end = note.end ?? Date()
        parts.append(note.start.formatted(date: .omitted, time: .shortened) + " → " + end.formatted(date: .omitted, time: .shortened))
        if let app = note.app, !app.isEmpty { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    private var failed: some View {
        HubCard {
            Text("notes.failed")
                .font(.system(size: 14, weight: .semibold))
            if let error = note.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.secondary)
            }
            if taker.hasAudio(note.id) {
                Button(String(localized: "hub.engine.retry")) { Task { await taker.process(note.id) } }
                    .buttonStyle(HubButtonStyle(primary: true))
            }
        }
    }

    private var speakers: some View {
        let shares = note.shares
        return HubWrap(spacing: 8) {
            ForEach(note.speakers) { speaker in
                Button {
                    newName = speaker.name
                    renaming = speaker
                } label: {
                    HStack(spacing: 7) {
                        Text(String(speaker.name.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.black.opacity(0.8))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(HubTheme.speaker(speaker.color)))
                        Text(speaker.name + (shares[speaker.id].map { " · " + $0.formatted(.percent.precision(.fractionLength(0))) } ?? ""))
                            .font(.system(size: 13))
                            .foregroundColor(HubTheme.speaker(speaker.color))
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundColor(HubTheme.speaker(speaker.color).opacity(0.7))
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 10)
                    .frame(height: 30)
                    .background(Capsule().fill(HubTheme.speaker(speaker.color).opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(String(localized: "notes.rename-speaker"))
            }
        }
    }

    @ViewBuilder private var summary: some View {
        if taker.working.contains(note.id) && note.summary == nil {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("notes.summarizing")
                    .font(.system(size: 13))
                    .foregroundColor(HubTheme.secondary)
            }
        } else if note.summary == nil && note.keyPoints.isEmpty && note.todos.isEmpty {
            HubCard {
                Text(note.lines.isEmpty ? String(localized: "notes.nothing-heard") : String(localized: "notes.no-summary"))
                    .font(.system(size: 13))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !note.lines.isEmpty {
                    HubSummaryEnginePicker()
                    Button(String(localized: "notes.summarize")) { Task { await taker.summarize(note.id) } }
                        .buttonStyle(HubButtonStyle(primary: true))
                        .disabled(taker.summaryEngine == .off)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    if let text = note.summary, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .foregroundColor(HubTheme.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !note.keyPoints.isEmpty {
                        HubLabel(String(localized: "notes.key-points"))
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(note.keyPoints, id: \.self) { point in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(verbatim: "•").foregroundColor(HubTheme.muted)
                                    Text(point)
                                        .font(.system(size: 14))
                                        .foregroundColor(Color(hex: "#D5D7DB"))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !note.todos.isEmpty {
                    HubTodos(note: note)
                        .frame(width: 280)
                }
            }
        }
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if note.lines.isEmpty {
                Text("notes.nothing-heard")
                    .font(.system(size: 13))
                    .foregroundColor(HubTheme.secondary)
            }
            ForEach(note.lines) { line in
                let speaker = note.speaker(line.speaker)
                HubLineView(name: speaker?.name ?? "?", color: HubTheme.speaker(speaker?.color ?? 1), line: line)
            }
        }
    }
}

private struct HubTodos: View {
    let note: Note
    @ObservedObject private var taker = NoteTaker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("notes.todos").font(.system(size: 14, weight: .bold))
                Spacer()
                Text(verbatim: "\(note.todos.filter(\.done).count) / \(note.todos.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(HubTheme.secondary)
            }
            ForEach(note.todos) { todo in
                Button { taker.toggle(note.id, todo: todo.id) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(todo.done ? HubTheme.accent : Color.clear)
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(todo.done ? Color.clear : Color(hex: "#5A5F68"), lineWidth: 1.5)
                            if todo.done {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundColor(HubTheme.onAccent)
                            }
                        }
                        .frame(width: 16, height: 16)
                        .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(todo.text)
                                .font(.system(size: 13))
                                .strikethrough(todo.done)
                                .foregroundColor(todo.done ? HubTheme.muted : Color(hex: "#E1E3E6"))
                                .fixedSize(horizontal: false, vertical: true)
                            let extra = [todo.owner, todo.due].compactMap { $0 }.joined(separator: " · ")
                            if !extra.isEmpty {
                                Text(extra)
                                    .font(.system(size: 12))
                                    .foregroundColor(HubTheme.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.line))
    }
}

/// Who writes the summaries: Claude, Apple Intelligence, or nobody.
struct HubSummaryEnginePicker: View {
    @ObservedObject private var taker = NoteTaker.shared

    var body: some View {
        HubRow(title: String(localized: "notes.engine")) {
            Picker("", selection: $taker.summaryEngine) {
                ForEach(NoteSummaryEngine.allCases) { engine in
                    Text(engine.label).tag(engine)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}
#endif
