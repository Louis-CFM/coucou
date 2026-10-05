import SwiftUI
import UIKit

/// Settings and About: how the iPhone is linked, the links Apple and people
/// look for, and the setup guide again.
struct AboutView: View {
    let link: PhoneLink
    @State private var showGuide = false

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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Coucou").font(.title3.weight(.semibold))
                        Text("Version \(version)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
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
                        .foregroundStyle(LiveActivityLink.shared.activitiesEnabled ? .secondary : .orange)
                }
                if link.notificationsAllowed == false || !LiveActivityLink.shared.activitiesEnabled {
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button("How to connect your Mac") { showGuide = true }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    MochiLive(state: .finished)
                        .frame(width: 88, height: 88)
                    Text("Your agents, in your pocket")
                        .font(.largeTitle.weight(.bold))
                    Text("Coucou on iPhone shows what Claude Code, Cursor, Codex and your services are doing on your Mac. Three things to set up, once.")
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Then, from here").font(.headline)
                    Text("• Allow or deny a command, with Face ID\n• See what Claude did, file by file\n• Write or dictate the next instruction (GitHub version on the Mac)\n• Mochi in your Dynamic Island when your Mac is locked")
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

    private func step(_ number: Int, _ title: String, _ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(number). \(title)").font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
