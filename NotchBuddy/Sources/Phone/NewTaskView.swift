import SwiftUI

/// Start a task from the iPhone: pick the agent (only those installed on the Mac), a folder
/// the Mac worked in lately, write or dictate what to do; Face ID sends it, the Mac runs it in
/// the background and tells how it ended. GitHub build of Coucou only.
struct NewTaskView: View {
    let link: PhoneLink

    @Environment(\.dismiss) private var dismiss
    @AppStorage("newTaskAgent") private var agentID = PhoneAgent.claude.rawValue
    @AppStorage("newTaskProject") private var projectPath = ""
    @State private var text = ""
    @State private var sending = false
    @State private var sentTaskId: String?
    @State private var sentAgent: PhoneAgent?
    @State private var error: String?
    @State private var dictation = Dictation()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let mac = link.macAgents, !mac.agents.isEmpty {
                    form(mac)
                } else {
                    ContentUnavailableView {
                        Label("New tasks need your Mac", systemImage: "laptopcomputer")
                    } description: {
                        Text("Use Coucou from GitHub on your Mac and turn on “Let my iPhone send instructions” in its Settings. The App Store version can't start agents.")
                    }
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dictation.stop(); dismiss() }
                }
                if let mac = link.macAgents, !mac.agents.isEmpty, sentTaskId == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start") { Task { await send(mac) } }
                            .disabled(!canSend(mac) || sending)
                    }
                }
            }
            // A drag or a tap outside the field puts the keyboard away, like Notes.
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: dictation.transcript) { _, words in
                if dictation.isRecording { text = dictation.prefix + words }
            }
        }
    }

    // MARK: Form

    private func agent(_ mac: MacAgents) -> PhoneAgent {
        let chosen = PhoneAgent(rawValue: agentID) ?? .claude
        return mac.agents.contains(chosen) ? chosen : mac.agents[0]
    }

    private func project(_ mac: MacAgents) -> MacAgents.Project? {
        mac.projects.first { $0.path == projectPath } ?? mac.projects.first
    }

    private func canSend(_ mac: MacAgents) -> Bool {
        project(mac) != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private func form(_ mac: MacAgents) -> some View {
        let chosen = agent(mac)
        Form {
            if let sentTaskId, let sentAgent {
                progress(taskId: sentTaskId, agent: sentAgent)
            } else {
                Section {
                    Picker("Agent", selection: Binding(get: { chosen }, set: { agentID = $0.rawValue })) {
                        ForEach(mac.agents, id: \.self) { Text($0.name).tag($0) }
                    }
                    if mac.projects.isEmpty {
                        Text("No recent folder yet. Start can't send a task without one: work in a project with Claude Code or Codex on your Mac, it shows up here within a minute.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("Project", selection: Binding(get: { project(mac)?.path ?? "" },
                                                             set: { projectPath = $0 })) {
                            ForEach(mac.projects, id: \.path) { Text($0.name).tag($0.path) }
                        }
                    }
                } footer: {
                    Text(chosen.asksOnPhone
                         ? "Claude Code asks you here before each command, as usual."
                         : "\(chosen.name) can't ask you from here: it follows its own settings on your Mac. Without changes on your side, it doesn't edit files or run commands that need your OK.")
                }

                Section("What to do") {
                    HStack(alignment: .top) {
                        TextField("Fix the failing test, then explain why…", text: $text, axis: .vertical)
                            .lineLimit(4...12)
                            .focused($focused)
                        VStack(spacing: 14) {
                            Button {
                                Task { await dictation.toggle(startingFrom: text) }
                            } label: {
                                Image(systemName: dictation.isRecording ? "waveform" : "mic.fill")
                                    .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                                    .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                            }
                            // Puts the keyboard away, in the field's own style.
                            if focused {
                                Button {
                                    focused = false
                                } label: {
                                    Image(systemName: "keyboard.chevron.compact.down")
                                        .foregroundStyle(.secondary)
                                }
                                .transition(.opacity)
                                .accessibilityLabel("Hide keyboard")
                            }
                        }
                        .buttonStyle(.borderless)
                        .animation(.easeOut(duration: 0.2), value: focused)
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
        }
    }

    /// After sending: waiting for the Mac, then how it ended.
    @ViewBuilder private func progress(taskId: String, agent: PhoneAgent) -> some View {
        if let result = link.taskResults[taskId] {
            Section {
                Label(result.ok ? "\(agent.name) finished" : "\(agent.name) stopped",
                      systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.ok ? .green : .orange)
                LabeledContent("Project", value: result.project)
                LabeledContent("Ended", value: result.endedAt.formatted(date: .omitted, time: .shortened))
            }
            Section("Last words") {
                Text(result.summary)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            Section {
                Button("New task") {
                    sentTaskId = nil
                    self.sentAgent = nil
                }
            }
        } else {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sent to your Mac")
                        Text("It starts within 15 s. You can close this screen, the result lands in History.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Sending

    private func send(_ mac: MacAgents) async {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, let project = project(mac) else { return }
        let chosen = agent(mac)
        dictation.stop()
        focused = false
        sending = true
        defer { sending = false }
        error = nil
        guard await OwnerCheck.confirm(reason: "Start \(chosen.name) in \(project.name) on your Mac") else {
            error = "Face ID didn't confirm. Nothing was sent."
            Haptics.warning()
            return
        }
        if let id = await link.sendTask(task, agent: chosen, project: project) {
            agentID = chosen.rawValue
            projectPath = project.path
            text = ""
            sentAgent = chosen
            sentTaskId = id
            Haptics.success()
        } else {
            error = link.lastPong ?? "Couldn't reach iCloud."
            Haptics.error()
        }
    }
}
