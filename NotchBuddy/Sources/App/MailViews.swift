#if !APPSTORE
import SwiftUI
import AppKit

// MARK: - Mail card (Apple Mail pill)

/// Accent of the Mail pill (the catalog colour, before any colour the user picked).
private let mailAccent = "#2F8CFF"

/// The latest messages of every inbox in Apple Mail, newest first, unread ones highlighted.
/// A click on a message opens it in the card (sender, subject, text) with Open in Mail,
/// Reply (Mail's own reply window: nothing is sent from Coucou) and Mark as read.
struct MailCardView: View {
    @ObservedObject private var mail = MailController.shared
    @State private var openId: String? = nil
    @State private var searchOpen = false
    @FocusState private var searchFocused: Bool

    private var openMessage: MailMessage? {
        guard let openId else { return nil }
        return mail.displayed.first { $0.id == openId }
    }

    var body: some View {
        Group {
            if let message = openMessage {
                MailDetailView(message: message) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { openId = nil }
                }
                .transition(.opacity)
            } else {
                list
                    .transition(.opacity)
            }
        }
        .onAppear { mail.refreshIfStale() }
        // A mail open: the notch grows so it can be read; back to the list, it shrinks.
        .onChange(of: openId) { _, id in setReading(id != nil) }
        .onDisappear { setReading(false) }
    }

    private func setReading(_ on: Bool) {
        let h: CGFloat? = on ? MailLayout.readingHeight : nil
        guard MailLayout.detailHeight != h else { return }
        MailLayout.detailHeight = h
        NotificationCenter.default.post(name: .islandResize, object: nil)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: mailAccent))
                    .frame(width: 7, height: 7)
                Text(verbatim: "Mail")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text("Inbox")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                if searchOpen {
                    // The search: free words, or "from:" / "subject:" (MailQuery).
                    TextField(String(localized: "mail.search.placeholder"), text: $mail.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#E8E9EC"))
                        .focused($searchFocused)
                        .onSubmit { mail.runSearch() }
                    if mail.searching { MailSpinner() }
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { searchOpen = false }
                        mail.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Close"))
                } else {
                    if let unread = mail.unreadCount, unread > 0 {
                        // Just the number, on one line: "1308" (the whole sentence in the tooltip).
                        Text(verbatim: unread > 9999 ? "9999+" : String(unread))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(hex: mailAccent))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color(hex: mailAccent).opacity(0.14))
                            .clipShape(Capsule())
                            .help(String(format: String(localized: "%lld unread"), Int64(unread)))
                    }
                    Spacer(minLength: 2)
                    if mail.searching { MailSpinner() }
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { searchOpen = true }
                        searchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .frame(width: 18, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "mail.search.help"))
                }
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            // Quick filters: All, Unread, Important, Today.
            // One line whatever the language: a longer set scrolls sideways, never wraps.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(MailFilter.allCases, id: \.self) { f in
                        MailFilterChip(title: f.title, on: mail.filter == f) { mail.setFilter(f) }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.leading, 108)
            .padding(.trailing, 12)

            // Message rows: three in view, the rest a scroll away.
            if mail.displayed.isEmpty {
                Group {
                    if mail.results != nil && mail.searching { Text("mail.searching") }
                    else if mail.results != nil { Text("mail.no-results") }
                    else if mail.loaded { Text("No messages") } else { Text("Loading…") }
                }
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .padding(.top, 8)
                    .padding(.leading, 116)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(mail.displayed) { message in
                            MailRow(message: message) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    openId = message.id
                                }
                            }
                        }
                        if mail.results == nil && mail.messages.count >= mail.shownCount
                            && mail.shownCount < MailController.maxShown {
                            Button { mail.loadMore() } label: {
                                Text("mail.load-more")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Color(hex: mailAccent).opacity(0.9))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 5)
                .padding(.leading, 108)
                .padding(.trailing, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }
}

/// One message in the list: sender, age, subject. Unread ones are tinted, with a dot.
private struct MailRow: View {
    let message: MailMessage
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        let accent = Color(hex: mailAccent)
        Button(action: onOpen) {
            HStack(spacing: 5) {
                Circle()
                    .fill(message.isRead ? Color.clear : accent)
                    .overlay(Circle().stroke(Color(hex: "#4D5159"), lineWidth: message.isRead ? 1 : 0))
                    .frame(width: 5, height: 5)
                Text(message.senderName)
                    .font(.system(size: 11, weight: message.isRead ? .regular : .semibold))
                    .foregroundColor(Color(hex: message.isRead ? "#9398A1" : "#E8E9EC"))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 82, alignment: .leading)
                    .layoutPriority(1)
                if message.isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 7.5))
                        .foregroundColor(Color(hex: "#F5A524"))
                }
                Text(message.timeAgo)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .fixedSize()
                Text(message.subject)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: message.isRead ? "#4D5159" : "#8E939C"))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(message.isRead
                          ? Color.white.opacity(hovered ? 0.05 : 0)
                          : accent.opacity(hovered ? 0.14 : 0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A quick filter of the Mail card: a small word, filled when it is on.
private struct MailFilterChip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: on ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(Color(hex: on ? "#E8E9EC" : (hovered ? "#B0B5BE" : "#6B7079")))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(on ? Color(hex: mailAccent).opacity(0.22) : Color.white.opacity(hovered ? 0.06 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

extension MailFilter {
    var title: String {
        switch self {
        case .all: return String(localized: "mail.filter.all")
        case .unread: return String(localized: "mail.filter.unread")
        case .flagged: return String(localized: "mail.filter.flagged")
        case .today: return String(localized: "mail.filter.today")
        }
    }
}

// MARK: - Mail detail

/// The small turning circle of a search in progress (in the header: the filters keep their line).
private struct MailSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .scaleEffect(0.7)
            .frame(width: 12, height: 12)
    }
}

/// One message opened in the card: sender, subject, its text (the notch grows to read it,
/// MailLayout) and the actions in one row of icons, each with its name on hover.
struct MailDetailView: View {
    let message: MailMessage
    let onClose: () -> Void
    @ObservedObject private var mail = MailController.shared

    var body: some View {
        let accent = Color(hex: mailAccent)
        VStack(alignment: .leading, spacing: 5) {
            // Header: back, sender, age
            HStack(spacing: 6) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Back"))

                Circle()
                    .fill(message.isRead ? Color(hex: "#4D5159") : accent)
                    .frame(width: 6, height: 6)
                Text(message.senderName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                    .help(message.senderAddress)
                if message.isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 8))
                        .foregroundColor(Color(hex: "#F5A524"))
                }
                Spacer(minLength: 2)
                Text(message.timeAgo)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .fixedSize()
            }
            // The card's ↗ button sits in the top-right corner: keep the header clear of it
            // (36 pt from the edge, like every card header).
            .padding(.trailing, 24)

            // The subject in full, then the text: one scroll, in all the room left.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(message.subject.isEmpty ? " " : message.subject)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if let text = mail.previews[message.id] {
                            Text(text.isEmpty ? String(localized: "mail.preview-empty") : text)
                        } else if mail.previewFailed.contains(message.id) {
                            Text("mail.preview-failed")
                        } else {
                            HStack(spacing: 6) {
                                MailSpinner()
                                Text("Loading…")
                            }
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#9398A1"))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            }
            .frame(maxHeight: .infinity)

            // Actions: each one is the user's own click. Nothing is ever sent from here.
            HStack(spacing: 4) {
                Button { mail.openInMail(message) } label: {
                    Text("mail.open")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(accent)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(accent.opacity(0.16)))
                }
                .help(String(localized: "Open in Mail"))
                Spacer(minLength: 4)
                MailIconButton(symbol: "arrowshape.turn.up.left", help: String(localized: "Reply")) {
                    mail.reply(message)
                }
                if !message.isRead {
                    MailIconButton(symbol: "envelope.open", help: String(localized: "Mark as read")) {
                        mail.markAsRead(message)
                    }
                }
                MailIconButton(symbol: message.isFlagged ? "flag.slash" : "flag",
                               help: message.isFlagged ? String(localized: "mail.not-important") : String(localized: "mail.important"),
                               tint: "#F5A524") {
                    mail.toggleFlag(message)
                }
                MailIconButton(symbol: "xmark.bin", help: String(localized: "mail.junk")) {
                    mail.moveToJunk(message)
                    onClose()
                }
                Menu {
                    Button(String(localized: "mail.make-vip")) { mail.makeVIP(message) }
                    Button(String(localized: "mail.ignore-sender")) {
                        mail.ignoreSender(message)
                        onClose()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .frame(width: 22, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .padding(.top, 4)
        .padding(.leading, 108)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onAppear { mail.loadPreview(message) }
    }
}

/// An action of the open mail: an icon, its name on hover.
private struct MailIconButton: View {
    let symbol: String
    let help: String
    var tint: String = "#B0B5BE"
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: tint).opacity(hovered ? 1 : 0.8))
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(hovered ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
    }
}
#endif
