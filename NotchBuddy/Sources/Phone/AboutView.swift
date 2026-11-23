import SwiftUI
import UIKit

/// Settings and About: how the iPhone is linked, the links Apple and people
/// look for, and the setup guide again.
struct AboutView: View {
    let link: PhoneLink
    @State private var showGuide = false
    @AppStorage(PhoneSettings.notifyDoneKey) private var notifyDone = true
    @AppStorage(PhoneSettings.mochiSoundsKey) private var mochiSounds = true
    @AppStorage(PhoneSettings.quietHoursKey) private var quietHours = false
    @AppStorage(PhoneSettings.quietFromKey) private var quietFrom = 22 * 60
    @AppStorage(PhoneSettings.quietToKey) private var quietTo = 8 * 60
    @AppStorage(SpotlightIndex.enabledKey) private var spotlight = true
    @AppStorage(BotanBridge.enabledKey) private var botan = false
    @State private var currentIcon = AppIconChoice.current

    private var botanLinked: Bool {
        if case .linked = BotanBridge.shared.status { return true }
        return false
    }

    private var botanStatus: String {
        switch BotanBridge.shared.status {
        case .setup: return "No Botan yet"
        case .off, .searching: return "Looking for it nearby…"
        case .connecting: return "Linking…"
        case .pairing: return "Type the code shown on Botan"
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Allow Bluetooth in Settings → Botan"
        case .linked(let name): return "Linked to \(name)"
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    MochiLive(state: .idle)
                        .padding(6)
                        .frame(width: 64, height: 64)
                        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 6) {
                        Image("BotanWordmark")
                            .resizable().scaledToFit()
                            .frame(height: 22)
                            .accessibilityLabel("Botan")
                        Text("Version \(version)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Link with Botan", isOn: $botan)
                    .onChange(of: botan) { _, on in BotanBridge.shared.setEnabled(on) }
                if botan {
                    LabeledContent("Botan") {
                        Text(botanStatus).foregroundStyle(botanLinked ? Color.secondary : Color.botan)
                    }
                    if BotanBridge.shared.status == .setup {
                        Button("Find Botan") { BotanBridge.shared.findBotan() }
                    }
                    if let problem = BotanBridge.shared.problem {
                        Text(problem).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if BotanBridge.shared.knownName != nil {
                        Button("Forget this Botan") { BotanBridge.shared.forget() }
                    }
                }
            } header: {
                Label {
                    Text("Botan")
                } icon: {
                    BotanSign().foregroundStyle(Color.botan).frame(width: 15, height: 15)
                }
            } footer: {
                Text("Botan is the little screen with one button on the back of your iPhone. It shows what your agents are doing on your Mac, and its button allows a request or picks an answer without unlocking your iPhone. It stays linked with your iPhone locked, and on iOS 26 even after you close the app.")
            }

            Section("Connection") {
                LabeledContent("iCloud") {
                    Label(iCloudText, systemImage: link.status == .ready ? "checkmark.icloud" : "exclamationmark.icloud")
                        .foregroundStyle(link.status == .ready ? .green : .orange)
                }
                LabeledContent("Notifications") {
                    Text(link.notificationsAllowed == false ? "Off" : "On")
                        .foregroundStyle(link.notificationsAllowed == false ? .orange : .secondary)
                }
                LabeledContent("Live Activities") {
                    Text(LiveActivityLink.shared.activitiesEnabled ? "On" : "Off")
                        .foregroundStyle(LiveActivityLink.shared.activitiesEnabled ? Color.secondary : Color.orange)
                }
                if link.notificationsAllowed == false || !LiveActivityLink.shared.activitiesEnabled {
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button("How to connect your Mac") { showGuide = true }
            }


            Section {
                Toggle("When an agent finishes or fails", isOn: $notifyDone)
                Toggle("Mochi's sounds", isOn: $mochiSounds)
                    .onChange(of: mochiSounds) { link.soundsChanged() }
                Toggle("Quiet hours", isOn: $quietHours)
                if quietHours {
                    DatePicker("From", selection: time($quietFrom), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: time($quietTo), displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text(quietHours
                     ? "In the quiet hours, only what waits on you (a command to allow, a question) makes a sound. The rest arrives silently."
                     : "Approvals and questions always notify you. Mochi's sounds are the ones he makes in your Mac's notch.")
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(AppIconChoice.allCases) { choice in
                            Button {
                                AppIconChoice.apply(choice)
                                currentIcon = choice
                            } label: {
                                VStack(spacing: 6) {
                                    Image(choice.previewName)
                                        .resizable()
                                        .frame(width: 58, height: 58)
                                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .strokeBorder(currentIcon == choice ? Color.accentColor : .clear, lineWidth: 2.5)
                                            .padding(-4))
                                    Text(choice.title).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
                Toggle("Find my turns in Spotlight", isOn: $spotlight)
                    .onChange(of: spotlight) { _, on in if !on { SpotlightIndex.removeAll() } }
            } header: {
                Text("Look")
            } footer: {
                Text("The Home Screen icon follows your choice; dark and tinted icons follow the Home Screen style. Spotlight's index stays on this iPhone.")
            }

            Section("Coucou") {
                Link("Website", destination: URL(string: "https://louis-cfm.github.io/coucou/")!)
                Link("Support", destination: URL(string: "https://louis-cfm.github.io/coucou/support.html")!)
                Link("Privacy Policy", destination: URL(string: "https://louis-cfm.github.io/coucou/privacy.html")!)
                Link("Terms", destination: URL(string: "https://louis-cfm.github.io/coucou/terms.html")!)
            }

            Section {
                Text("No account, no analytics, no ads. Your sessions travel through your own private iCloud, encrypted with your keys.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showGuide) { OnboardingView() }
    }

    /// Minutes after midnight, as a time for the pickers.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes.wrappedValue * 60))
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    private var iCloudText: String {
        switch link.status {
        case .ready: "Linked"
        case .starting: "Connecting…"
        case .zoneMissing: "Waiting for your Mac"
        case .noAccount: "Not signed in"
        case .failed: "Can't reach iCloud"
        }
    }
}

/// First launch: what Coucou needs on the Mac to show anything here.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BotanBridge.enabledKey) private var botanOn = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    MochiLive(state: .finished)
                        .frame(width: 88, height: 88)
                    Text("Your agents, in your pocket")
                        .font(.largeTitle.weight(.bold))
                    Text("Botan shows what Claude Code, Cursor, Codex and your services are doing on your Mac, through Coucou. Three things to set up, once.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                step(1, "Coucou on your Mac",
                     "Install Coucou for Mac (Mac App Store or the website) and set up its Claude Code hooks.",
                     icon: "laptopcomputer")
                step(2, "Turn on the iPhone switch",
                     "On the Mac: Coucou Settings → General → iPhone → \"Show my agent sessions on my iPhone\".",
                     icon: "switch.2")
                step(3, "Same Apple Account",
                     "Sign in to iCloud with the same Apple Account on both. Your sessions go through your private iCloud, encrypted.",
                     icon: "icloud")
                botanStep
                VStack(alignment: .leading, spacing: 6) {
                    Text("Then, from here").font(.headline)
                    Text("• Allow or deny a command, right from the Lock Screen or with Botan's button\n• Answer Claude's questions\n• See what Claude did, file by file\n• Mochi in your Dynamic Island while your agents work")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .background(Color.black)
        .safeAreaInset(edge: .bottom) {
            Button {
                dismiss()
            } label: {
                Text("Got it").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
    }

    /// Step 4, for those who have the box: link it now (the system sheet), or skip.
    private var botanStep: some View {
        HStack(alignment: .top, spacing: 14) {
            BotanSign()
                .foregroundStyle(Color.botan)
                .padding(10)
                .frame(width: 44, height: 44)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            VStack(alignment: .leading, spacing: 8) {
                Text("4. Botan, if you have one").font(.headline)
                Text("The little screen with one button on the back of your iPhone: your agents at a glance, and a press to allow, iPhone locked.")
                    .font(.callout).foregroundStyle(.secondary)
                if botanOn {
                    Label("Linking is on", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Button("Link Botan") { BotanBridge.shared.setEnabled(true) }
                        .buttonStyle(.bordered)
                        .tint(.botan)
                }
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Same tile as Botan's step: deep black, Botan orange, a thin edge.
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.botan)
                .frame(width: 44, height: 44)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(number). \(title)").font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// The Home Screen icon: Botan's (the default), or Mochi in a color (alternate app icons).
enum AppIconChoice: String, CaseIterable, Identifiable {
    case orange = "", blue = "AppIcon-Blue", green = "AppIcon-Green", purple = "AppIcon-Purple",
         pink = "AppIcon-Pink", graphite = "AppIcon-Graphite"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .orange: "Botan"
        case .blue: "Blue"
        case .green: "Green"
        case .purple: "Purple"
        case .pink: "Pink"
        case .graphite: "Graphite"
        }
    }

    var previewName: String { self == .orange ? "IconPreview-Orange" : "IconPreview-\(title)" }

    @MainActor static var current: AppIconChoice {
        AppIconChoice(rawValue: UIApplication.shared.alternateIconName ?? "") ?? .orange
    }

    @MainActor static func apply(_ choice: AppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        UIApplication.shared.setAlternateIconName(choice == .orange ? nil : choice.rawValue)
    }
}
