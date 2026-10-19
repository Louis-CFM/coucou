#if !APPSTORE
import SwiftUI
import AppKit

// MARK: - WhatsApp card (WhatsApp pill)

/// WhatsApp's own green: the pill keeps it whatever, like the brand.
let whatsAppAccent = "#25D366"

/// The conversations with new messages, newest first: one row per conversation (never one
/// per message) with initials, name, the last message cut short and the unread count.
/// When the gateway isn't linked, the card says why and leads to Settings.
struct WhatsAppCardView: View {
    @ObservedObject private var wa = WhatsAppController.shared
    /// The conversation opened in the card (phase 2: read and reply).
    @State private var openChat: String? = nil

    var body: some View {
        Group {
            // Kept open through a missed check (the draft too): only gone when WhatsApp is off.
            if wa.link != .off, let chat = openChat, let conversation = wa.inbox.conversations[chat] {
                WhatsAppConversationView(conversation: conversation) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { openChat = nil }
                }
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if wa.link == .connected {
                        list
                    } else {
                        status
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: whatsAppAccent))
                .frame(width: 7, height: 7)
            Text(verbatim: "WhatsApp")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            let unread = wa.visibleConversations.reduce(0) { $0 + $1.unread }
            if unread > 0 {
                Text(String(format: String(localized: "%lld unread"), Int64(unread)))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: whatsAppAccent))
                    .monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color(hex: whatsAppAccent).opacity(0.14))
                    .clipShape(Capsule())
            }
            Spacer(minLength: 2)
        }
        .padding(.top, 6)
        .padding(.leading, 108)
        .padding(.trailing, 36)
    }

    @ViewBuilder private var list: some View {
        let conversations = wa.visibleConversations
        if conversations.isEmpty {
            Text("whatsapp.empty")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
                .padding(.top, 8)
                .padding(.leading, 116)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(conversations) { conversation in
                        WhatsAppRow(conversation: conversation) {
                            wa.open(conversation.id)
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                openChat = conversation.id
                            }
                        }
                    }
                }
            }
            .padding(.top, 5)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(WhatsAppStatus.dot(wa.link)).frame(width: 5, height: 5)
                Text(WhatsAppStatus.label(wa.link))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(1).truncationMode(.tail)
            }
            Button("Settings…") {
                NotificationCenter.default.post(name: .openFullSettings, object: "integrations")
            }
            .font(.system(size: 11))
            .foregroundColor(Color(hex: "#8E939C"))
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
        .padding(.leading, 108)
    }
}

/// What the link's state reads like, in the card and in Settings.
enum WhatsAppStatus {
    static func label(_ link: WhatsAppController.Link) -> String {
        switch link {
        case .off:               return String(localized: "whatsapp.status.off")
        case .connecting:        return String(localized: "whatsapp.status.connecting")
        case .needsQR:           return String(localized: "whatsapp.status.needs-qr")
        case .connected:         return String(localized: "whatsapp.status.connected")
        case .unreachable:       return String(localized: "whatsapp.status.unreachable")
        case .unauthorized:      return String(localized: "whatsapp.status.unauthorized")
        case .failed(let why):   return why
        }
    }

    static func dot(_ link: WhatsAppController.Link) -> Color {
        switch link {
        case .connected:                 return Color(hex: "#22C55E")
        case .connecting, .needsQR:      return Color(hex: "#F5B83D")
        case .off:                       return Color(hex: "#6B7079")
        default:                         return Color(hex: "#F4505E")
        }
    }
}

/// One conversation: initials, name, age, the last message, and how many are unread.
struct WhatsAppRow: View {
    let conversation: WAConversation
    var onOpen: (() -> Void)? = nil
    @State private var hovered = false

    var body: some View {
        let accent = Color(hex: whatsAppAccent)
        let unread = conversation.unread > 0
        Button(action: { onOpen?() }) {
            HStack(spacing: 6) {
                WhatsAppAvatar(name: conversation.name, isGroup: conversation.isGroup, size: 16)
                Text(conversation.name)
                    .font(.system(size: 11, weight: unread ? .semibold : .regular))
                    .foregroundColor(Color(hex: unread ? "#E8E9EC" : "#9398A1"))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 92, alignment: .leading)
                    .layoutPriority(1)
                Text(waTimeAgo(conversation.lastActivity))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .fixedSize()
                if let last = conversation.messages.last {
                    Text(waPreview(last, isGroup: conversation.isGroup))
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: unread ? "#8E939C" : "#4D5159"))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if unread {
                    Text(verbatim: conversation.unread > 99 ? "99+" : "\(conversation.unread)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "#0B0C0E"))
                        .monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(accent)
                        .clipShape(Capsule())
                        .fixedSize()
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(unread ? accent.opacity(hovered ? 0.14 : 0.08) : Color.white.opacity(hovered ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("whatsapp.ignore-chat") { WhatsAppController.shared.ignore(conversation.id) }
        }
    }
}

// MARK: - Conversation

/// One conversation opened in the card: its last ten messages and a reply field.
/// Return sends, Shift-Return starts a new line, Escape goes back to the list.
/// Nothing is sent without the user's own Return or click.
struct WhatsAppConversationView: View {
    let conversation: WAConversation
    let onClose: () -> Void
    @ObservedObject private var wa = WhatsAppController.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var shown: [WAMessage] { Array(conversation.messages.suffix(10)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: back, initials, name
            HStack(spacing: 6) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                WhatsAppAvatar(name: conversation.name, isGroup: conversation.isGroup, size: 16)
                Text(conversation.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1).truncationMode(.tail)
                    .help(WAJID.displayNumber(conversation.id))
                Spacer(minLength: 2)
            }
            // The card's ↗ button sits in the top-right corner (36 pt, like every card header).
            .padding(.trailing, 24)

            // The last messages, newest at the bottom.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(shown) { message in
                            WhatsAppBubble(message: message, isGroup: conversation.isGroup)
                                .id(message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    if let last = shown.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: shown.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)

            // Reply
            HStack(spacing: 6) {
                TextField(String(localized: "whatsapp.reply.placeholder"), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .lineLimit(1...3)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand(perform: onClose)
                    .disabled(wa.sending)
                if wa.sending {
                    ProgressView().controlSize(.mini)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: whatsAppAccent)
                                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.3 : 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))

            if wa.link != .connected {
                Text(verbatim: WhatsAppStatus.label(wa.link))
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(hex: "#F5B83D"))
                    .lineLimit(1).truncationMode(.tail)
            } else if let error = wa.sendError {
                Text(verbatim: error)
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(hex: "#F4505E"))
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.top, 4)
        .padding(.leading, 108)
        .padding(.trailing, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onAppear { focused = true }
        .onChange(of: draft) { _, text in
            wa.composing = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onDisappear {
            wa.composing = false
            wa.close(conversation.id)
        }
    }

    /// Return: sends. Shift-Return: a new line instead.
    private func submit() {
        if NSEvent.modifierFlags.contains(.shift) {
            draft += "\n"
            focused = true
            return
        }
        send()
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await wa.send(text, to: conversation.id) { draft = "" }
            focused = true
        }
    }
}

/// One message in the conversation: theirs on the left, yours tinted green on the right.
struct WhatsAppBubble: View {
    let message: WAMessage
    let isGroup: Bool

    var body: some View {
        let preview = message.previewKey
        let value = preview.value
        let label: String? = preview.key.isEmpty ? nil : NSLocalizedString(preview.key, comment: "")
        HStack(spacing: 0) {
            if message.fromMe { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 1) {
                if isGroup && !message.fromMe && !message.senderName.isEmpty {
                    Text(message.senderName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(hex: whatsAppAccent).opacity(0.8))
                        .lineLimit(1)
                }
                if let label {
                    Label(label, systemImage: Self.icon(message.media))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "#9398A1"))
                }
                if !value.isEmpty {
                    Text(value)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: message.fromMe ? "#E8E9EC" : "#C5C8CD"))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(message.fromMe ? Color(hex: whatsAppAccent).opacity(0.16) : Color.white.opacity(0.06))
            )
            if !message.fromMe { Spacer(minLength: 40) }
        }
    }

    private static func icon(_ media: WAMedia) -> String {
        switch media {
        case .image:            return "photo"
        case .video:            return "video"
        case .audio, .voice:    return "waveform"
        case .document:         return "doc"
        case .sticker:          return "face.smiling"
        case .location:         return "mappin.and.ellipse"
        case .contact:          return "person.crop.circle"
        case .none, .other:     return "ellipsis.bubble"
        }
    }
}

/// Initials on WhatsApp green: no photo is ever fetched (they live on WhatsApp's servers).
struct WhatsAppAvatar: View {
    let name: String
    let isGroup: Bool
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: whatsAppAccent).opacity(0.22))
            if isGroup && WAJID.initials(name) == "#" {
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundColor(Color(hex: whatsAppAccent))
            } else {
                Text(verbatim: WAJID.initials(name))
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundColor(Color(hex: whatsAppAccent))
            }
        }
        .frame(width: size, height: size)
    }
}

/// "Marie: see you", "You: ok", "Photo · look", "Voice": one line, media as a label only.
func waPreview(_ message: WAMessage, isGroup: Bool) -> String {
    let (key, value) = message.previewKey
    var line: String
    if key.isEmpty {
        line = value
    } else {
        let label = NSLocalizedString(key, comment: "")
        line = value.isEmpty ? label : "\(label) · \(value)"
    }
    line = line.replacingOccurrences(of: "\n", with: " ")
    if message.fromMe { return String(localized: "whatsapp.you") + ": " + line }
    if isGroup, !message.senderName.isEmpty { return message.senderName + ": " + line }
    return line
}

func waTimeAgo(_ date: Date) -> String {
    let diff = Date().timeIntervalSince(date)
    if diff < 60    { return String(localized: "mail.now") }
    if diff < 3600  { return "\(Int(diff / 60))m" }
    if diff < 86400 { return "\(Int(diff / 3600))h" }
    return "\(Int(diff / 86400))d"
}

// MARK: - Settings

/// Settings → Integrations → WhatsApp (experimental). Off until turned on; the gateway's
/// address and credentials go to the Keychain; the QR to link WhatsApp shows right here.
struct WhatsAppSettingsSection: View {
    @ObservedObject private var wa = WhatsAppController.shared
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var installer = WhatsAppGOWAInstaller.shared
    @State private var showAdvanced = false
    @State private var enabled = WhatsAppSettings.enabled
    @State private var gateway = WhatsAppSettings.gateway
    @State private var url = KeychainStore.shared.get(WhatsAppSettings.urlKey) ?? ""
    @State private var credential = KeychainStore.shared.get(WhatsAppSettings.credentialKey) ?? ""
    @State private var port = String(WhatsAppSettings.port)
    @State private var respectFocus = WhatsAppSettings.respectFocus
    @State private var markReadOnOpen = WhatsAppSettings.markReadOnOpen
    @State private var autoStart = WhatsAppGOWAProcess.autoStart
    @State private var gowaPath = WhatsAppGOWAProcess.binaryPath
    @State private var testResult: String?
    @State private var testing = false
    @State private var ignoreEntry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: whatsAppAccent)).frame(width: 8, height: 8)
                Text("whatsapp.title").font(.system(size: 12, weight: .semibold))
            }

            Text("whatsapp.warning")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#F5B83D"))
                .fixedSize(horizontal: false, vertical: true)

            Toggle("whatsapp.enable", isOn: $enabled)
                .onChange(of: enabled) { _, on in wa.setEnabled(on) }

            if enabled {
                if !appState.activeIntegrations.contains(WhatsAppController.pillId) {
                    Text("whatsapp.no-slot")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#F4505E"))
                }

                // One click: Coucou downloads GOWA, checks it and starts it. No Terminal.
                if gateway == .gowa { installBlock }

                if showsLinkState { linkState }

                // Filters
                Toggle("whatsapp.mute-groups", isOn: Binding(
                    get: { wa.filters.muteGroups },
                    set: { wa.filters.muteGroups = $0 }))
                Toggle("whatsapp.respect-focus", isOn: $respectFocus)
                    .onChange(of: respectFocus) { _, on in
                        WhatsAppSettings.respectFocus = on
                        if on { wa.askFocus() }
                    }
                if respectFocus && wa.focusReadable == false {
                    Text("whatsapp.focus-unavailable")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("whatsapp.mark-read-on-open", isOn: $markReadOnOpen)
                    .onChange(of: markReadOnOpen) { _, on in WhatsAppSettings.markReadOnOpen = on }
                Text("whatsapp.mark-read.hint")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .fixedSize(horizontal: false, vertical: true)

                ignoredChats

                Text("whatsapp.privacy")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .fixedSize(horizontal: false, vertical: true)

                // Your own gateway (OpenWA, another address, a password, the port): folded away.
                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("whatsapp.gateway", selection: $gateway) {
                            ForEach(WAGatewayKind.allCases, id: \.self) { kind in
                                Text(verbatim: kind == .gowa ? "GOWA" : "OpenWA").tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)

                        TextField(gateway.defaultURL, text: $url)
                            .textFieldStyle(.roundedBorder)
                        SecureField(gateway == .gowa ? String(localized: "whatsapp.credential.gowa")
                                                     : String(localized: "whatsapp.credential.openwa"),
                                    text: $credential)
                            .textFieldStyle(.roundedBorder)
                        if gateway == .gowa { autoStartRow }
                        HStack(spacing: 6) {
                            Text("whatsapp.port").font(.system(size: 11))
                            TextField(String(WhatsAppSettings.defaultPort), text: $port)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Button("whatsapp.save") { save() }
                                .buttonStyle(.borderedProminent)
                            Button("whatsapp.test") {
                                save()
                                testing = true
                                Task {
                                    testResult = await wa.testConnection()
                                    testing = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(testing)
                            if testing { ProgressView().controlSize(.small) }
                        }
                        if let testResult {
                            Text(verbatim: testResult)
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#8E939C"))
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("whatsapp.advanced").font(.system(size: 11, weight: .medium))
                }
            }
        }
        .onChange(of: installer.step) { _, step in
            // Installed by Coucou: the fields follow what it set.
            if case .done = step {
                gateway = .gowa
                url = ""
                autoStart = true
                gowaPath = WhatsAppGOWAProcess.binaryPath
            }
        }
        .onChange(of: gateway) { old, new in
            // Still on the other gateway's default address: follow the switch.
            if url.isEmpty || url == old.defaultURL { url = new.defaultURL }
        }
    }

    /// The status and QR once there is a gateway to talk to (before the install, "the gateway
    /// doesn't answer" would only confuse).
    private var showsLinkState: Bool {
        if gateway != .gowa || WhatsAppGOWAInstaller.isInstalled || !url.isEmpty { return true }
        return wa.link == .connected || wa.link == .needsQR
    }

    /// Install WhatsApp (GOWA) in one click, or its state once installed.
    @ViewBuilder private var installBlock: some View {
        switch installer.step {
        case .checking, .downloading, .verifying, .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: installStepLabel).font(.system(size: 11))
            }
        default:
            if WhatsAppGOWAInstaller.isInstalled {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Color(hex: whatsAppAccent))
                    Text(verbatim: WhatsAppGOWAInstaller.installedVersion.map { String(format: String(localized: "whatsapp.install.ready %@"), $0) }
                         ?? String(localized: "whatsapp.install.ready-custom"))
                        .font(.system(size: 11))
                    Spacer()
                    Button("whatsapp.install.update") { installer.install() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                Button { installer.install() } label: {
                    Label("whatsapp.install", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: whatsAppAccent))
                Text("whatsapp.install.hint")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let why) = installer.step {
                Text(verbatim: why)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#F4505E"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var installStepLabel: String {
        switch installer.step {
        case .checking:                  return String(localized: "whatsapp.install.checking")
        case .downloading(let mb):       return String(format: String(localized: "whatsapp.install.downloading %lld"), Int64(mb))
        case .verifying:                 return String(localized: "whatsapp.install.verifying")
        case .installing:                return String(localized: "whatsapp.install.installing")
        default:                         return ""
        }
    }

    /// Linked or not, and the QR to scan when it's needed.
    @ViewBuilder private var linkState: some View {
        HStack(spacing: 5) {
            Circle().fill(WhatsAppStatus.dot(wa.link)).frame(width: 6, height: 6)
            if wa.link == .connected, let me = wa.me {
                Text(String(format: String(localized: "whatsapp.connected-as %@"), WAJID.displayNumber(me)))
                    .font(.system(size: 11))
            } else {
                Text(verbatim: WhatsAppStatus.label(wa.link))
                    .font(.system(size: 11))
            }
            Spacer()
        }
        if wa.link == .connected {
            Text(webhookLine)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#8E939C"))
                .fixedSize(horizontal: false, vertical: true)
        }
        if wa.link == .needsQR {
            if let png = wa.qrPNG, let image = NSImage(data: png) {
                HStack(alignment: .top, spacing: 10) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 168, height: 168)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("whatsapp.qr.hint")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Phase 3: Coucou starts the GOWA binary itself (GitHub build: the App Store build is
    /// sandboxed and never compiles this).
    @ViewBuilder private var autoStartRow: some View {
        Toggle("whatsapp.autostart", isOn: $autoStart)
            .onChange(of: autoStart) { _, on in
                WhatsAppGOWAProcess.autoStart = on
                wa.settingsChanged()
            }
        if autoStart {
            HStack(spacing: 6) {
                TextField(String(localized: "whatsapp.autostart.path"), text: $gowaPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { savePath() }
                Button("whatsapp.choose") { chooseBinary() }
            }
            Text("whatsapp.autostart.hint")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#8E939C"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        gowaPath = url.path
        savePath()
    }

    private func savePath() {
        WhatsAppGOWAProcess.binaryPath = gowaPath.trimmingCharacters(in: .whitespaces)
        wa.settingsChanged()
    }

    private var webhookLine: String {
        switch wa.webhook {
        case .registered:        return String(localized: "whatsapp.webhook.live")
        case .portBusy:          return String(format: String(localized: "whatsapp.webhook.port-busy %lld"), Int64(WhatsAppSettings.port))
        case .refused(let why):  return String(format: String(localized: "whatsapp.webhook.refused %@"), why)
        case .off, .listening:   return String(localized: "whatsapp.webhook.polling")
        }
    }

    @ViewBuilder private var ignoredChats: some View {
        Text("whatsapp.ignored").font(.system(size: 11, weight: .medium))
        ForEach(wa.filters.ignored.sorted(), id: \.self) { chat in
            HStack(spacing: 6) {
                Text(verbatim: wa.inbox.conversations[chat]?.name ?? WAJID.displayNumber(chat))
                    .font(.system(size: 11))
                Spacer()
                Button("whatsapp.remove") { wa.unignore(chat) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        }
        HStack(spacing: 6) {
            TextField(String(localized: "whatsapp.ignore-placeholder"), text: $ignoreEntry)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addIgnored)
            Button("whatsapp.add", action: addIgnored)
                .disabled(ignoreEntry.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addIgnored() {
        let raw = ignoreEntry.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        // A phone number ("+33 6 12…") or a full chat id ("…@g.us").
        let chat = raw.contains("@") ? raw : raw.filter(\.isNumber) + "@s.whatsapp.net"
        guard chat.count > "@s.whatsapp.net".count else { return }
        wa.ignore(chat)
        ignoreEntry = ""
    }

    private func save() {
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        if trimmedURL.isEmpty { KeychainStore.shared.remove(WhatsAppSettings.urlKey) }
        else { KeychainStore.shared.set(WhatsAppSettings.urlKey, value: trimmedURL) }
        let trimmedCredential = credential.trimmingCharacters(in: .whitespaces)
        if trimmedCredential.isEmpty { KeychainStore.shared.remove(WhatsAppSettings.credentialKey) }
        else { KeychainStore.shared.set(WhatsAppSettings.credentialKey, value: trimmedCredential) }
        WhatsAppSettings.gateway = gateway
        WhatsAppGOWAProcess.binaryPath = gowaPath.trimmingCharacters(in: .whitespaces)
        if let p = Int(port), (1024...65535).contains(p) { WhatsAppSettings.port = p }
        port = String(WhatsAppSettings.port)
        wa.settingsChanged()
    }
}
#endif
