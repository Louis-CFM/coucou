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

    private var openMessage: MailMessage? {
        guard let openId else { return nil }
        return mail.messages.first { $0.id == openId }
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
                if let unread = mail.unreadCount, unread > 0 {
                    Text(String(format: String(localized: "%lld unread"), Int64(unread)))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: mailAccent))
                        .monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color(hex: mailAccent).opacity(0.14))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 2)
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            // Message rows: three in view, the rest a scroll away.
            if mail.messages.isEmpty {
                Group {
                    if mail.loaded { Text("No messages") } else { Text("Loading…") }
                }
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .padding(.top, 8)
                    .padding(.leading, 116)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(mail.messages) { message in
                            MailRow(message: message) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    openId = message.id
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

// MARK: - Mail detail

/// One message opened in the card: sender, subject, the start of its text, and actions.
struct MailDetailView: View {
    let message: MailMessage
    let onClose: () -> Void
    @ObservedObject private var mail = MailController.shared

    var body: some View {
        let accent = Color(hex: mailAccent)
        VStack(alignment: .leading, spacing: 4) {
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

                Circle()
                    .fill(message.isRead ? Color(hex: "#4D5159") : accent)
                    .frame(width: 6, height: 6)
                Text(message.senderName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                    .help(message.senderAddress)
                Spacer(minLength: 2)
                Text(message.timeAgo)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .fixedSize()
            }
            // The card's ↗ button sits in the top-right corner: keep the header clear of it
            // (36 pt from the edge, like every card header).
            .padding(.trailing, 24)

            Text(message.subject.isEmpty ? " " : message.subject)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1).truncationMode(.tail)

            // The start of the message, scrollable.
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if let text = mail.previews[message.id] {
                        Text(text.isEmpty ? " " : text)
                    } else {
                        Text("Loading…")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "#9398A1"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(height: 28)

            // Actions: each one is the user's own click. Nothing is ever sent from here.
            HStack(spacing: 12) {
                Button("Open in Mail") { mail.openInMail(message) }
                    .foregroundColor(accent.opacity(0.9))
                Button("Reply") { mail.reply(message) }
                    .foregroundColor(Color(hex: "#C5C8CD"))
                if !message.isRead {
                    Button("Mark as read") { mail.markAsRead(message) }
                        .foregroundColor(Color(hex: "#8E939C"))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
        .padding(.leading, 108)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onAppear { mail.loadPreview(message) }
    }
}
#endif
