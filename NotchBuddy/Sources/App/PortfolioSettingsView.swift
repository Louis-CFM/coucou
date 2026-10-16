import SwiftUI

// MARK: - Portfolio settings section

/// Embedded in the Integrations settings panel.
/// Lets the user connect exchange accounts (read-only API key + secret) and
/// self-custody wallet addresses (BTC, ETH, SOL). Keys are stored in the Keychain;
/// addresses go to UserDefaults (they are public data).
struct PortfolioSettingsSection: View {
    @State private var showAddExchange = false
    @State private var showAddWallet = false
    @State private var wallets: [PortfolioWallet] = PortfolioSettings.wallets
    /// Whether each exchange is configured (keyed by rawValue).
    @State private var configured: [String: Bool] = Self.loadConfigured()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#FFD700")).frame(width: 8, height: 8)
                Text("Portfolio").font(.system(size: 12, weight: .semibold))
            }

            // Connected exchanges
            ForEach(ExchangeKind.allCases, id: \.rawValue) { ex in
                if configured[ex.rawValue] == true {
                    ExchangeRow(exchange: ex, onRemove: {
                        PortfolioSettings.remove(exchange: ex)
                        configured[ex.rawValue] = false
                        PortfolioController.shared.settingsChanged()
                    })
                }
            }

            // Connected wallets
            ForEach(wallets) { w in
                WalletRow(wallet: w, onRemove: {
                    PortfolioSettings.removeWallet(address: w.address)
                    wallets = PortfolioSettings.wallets
                    PortfolioController.shared.settingsChanged()
                })
            }

            // Add buttons
            HStack(spacing: 8) {
                Button(String(localized: "portfolio.add-exchange")) { showAddExchange = true }
                    .buttonStyle(.bordered)
                Button(String(localized: "portfolio.add-wallet")) { showAddWallet = true }
                    .buttonStyle(.bordered)
            }

            Text(String(localized: "portfolio.hint"))
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#8E939C"))
        }
        .sheet(isPresented: $showAddExchange) {
            AddExchangeSheet { ex in
                configured[ex.rawValue] = true
                PortfolioController.shared.settingsChanged()
            }
        }
        .sheet(isPresented: $showAddWallet) {
            AddWalletSheet {
                wallets = PortfolioSettings.wallets
                PortfolioController.shared.settingsChanged()
            }
        }
    }

    private static func loadConfigured() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: ExchangeKind.allCases.map {
            ($0.rawValue, PortfolioSettings.isConfigured($0))
        })
    }
}

// MARK: - Exchange row

private struct ExchangeRow: View {
    let exchange: ExchangeKind
    let onRemove: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).imageScale(.small)
            Text(verbatim: exchange.name).font(.system(size: 11))
            Text(String(localized: "portfolio.read-only"))
                .font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
            Spacer()
            Button(String(localized: "portfolio.remove")) { confirmRemove = true }
                .font(.system(size: 11))
                .foregroundColor(.red)
                .buttonStyle(.plain)
        }
        .alert(String(format: String(localized: "portfolio.remove-confirm %@"), exchange.name),
               isPresented: $confirmRemove) {
            Button(String(localized: "portfolio.remove"), role: .destructive) { onRemove() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }
}

// MARK: - Wallet row

private struct WalletRow: View {
    let wallet: PortfolioWallet
    let onRemove: () -> Void
    @State private var confirmRemove = false

    private var shortAddress: String {
        let a = wallet.address
        return a.count > 16 ? "\(a.prefix(8))…\(a.suffix(6))" : a
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).imageScale(.small)
            Text(verbatim: wallet.label.isEmpty ? shortAddress : wallet.label)
                .font(.system(size: 11))
            Text(verbatim: wallet.kind.name)
                .font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
            Spacer()
            Button(String(localized: "portfolio.remove")) { confirmRemove = true }
                .font(.system(size: 11))
                .foregroundColor(.red)
                .buttonStyle(.plain)
        }
        .alert(String(format: String(localized: "portfolio.remove-confirm %@"), wallet.label.isEmpty ? shortAddress : wallet.label),
               isPresented: $confirmRemove) {
            Button(String(localized: "portfolio.remove"), role: .destructive) { onRemove() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }
}

// MARK: - Add exchange sheet

private struct AddExchangeSheet: View {
    let onSave: (ExchangeKind) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedExchange = ExchangeKind.binance
    @State private var apiKey     = ""
    @State private var apiSecret  = ""
    @State private var passphrase = ""
    @State private var testing    = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            Text(String(localized: "portfolio.add-exchange"))
                .font(.system(size: 13, weight: .semibold))
                .padding(.bottom, 16)

            // Exchange dropdown (menu, not segmented — 5 items is too wide)
            HStack {
                Text(String(localized: "portfolio.exchange"))
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $selectedExchange) {
                    ForEach(ExchangeKind.allCases, id: \.rawValue) { ex in
                        Text(verbatim: ex.name).tag(ex)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: selectedExchange) { _, _ in error = nil; apiKey = ""; apiSecret = ""; passphrase = "" }
            }
            .padding(.bottom, 10)

            // Instructions
            instructions(for: selectedExchange)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            // Fields
            fieldRow(label: selectedExchange.keyLabel, text: $apiKey)
            fieldRow(label: selectedExchange.secretLabel, text: $apiSecret, isSecret: true)
            if selectedExchange.needsPassphrase {
                fieldRow(label: "Passphrase", text: $passphrase, isSecret: true)
            }

            if let err = error {
                Text(verbatim: err)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#F4505E"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            Spacer().frame(height: 16)

            // Buttons
            HStack(spacing: 8) {
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task { await testAndSave() }
                } label: {
                    if testing {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.75).frame(width: 14, height: 14)
                            Text(String(localized: "portfolio.testing"))
                        }
                    } else {
                        Text(String(localized: "portfolio.test-save"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(testing || apiKey.isEmpty || apiSecret.isEmpty
                          || (selectedExchange.needsPassphrase && passphrase.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    @ViewBuilder
    private func fieldRow(label: String, text: Binding<String>, isSecret: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#8E939C"))
                .frame(width: 80, alignment: .leading)
            Group {
                if isSecret {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
        }
        .padding(.bottom, 8)
    }

    @MainActor
    private func testAndSave() async {
        testing = true
        error = nil
        let err = await PortfolioController.validate(
            exchange: selectedExchange,
            key: apiKey.trimmingCharacters(in: .whitespaces),
            secret: apiSecret.trimmingCharacters(in: .whitespaces),
            passphrase: passphrase.trimmingCharacters(in: .whitespaces)
        )
        testing = false
        if let err {
            error = err
        } else {
            PortfolioSettings.save(
                exchange: selectedExchange,
                key: apiKey.trimmingCharacters(in: .whitespaces),
                secret: apiSecret.trimmingCharacters(in: .whitespaces),
                passphrase: passphrase.trimmingCharacters(in: .whitespaces)
            )
            onSave(selectedExchange)
            dismiss()
        }
    }

    @ViewBuilder
    private func instructions(for ex: ExchangeKind) -> some View {
        switch ex {
        case .binance:
            Text(String(localized: "portfolio.instructions.binance"))
        case .okx:
            Text(String(localized: "portfolio.instructions.okx"))
        case .bybit:
            Text(String(localized: "portfolio.instructions.bybit"))
        case .kraken:
            Text(String(localized: "portfolio.instructions.kraken"))
        case .coinbase:
            Text(String(localized: "portfolio.instructions.coinbase"))
        }
    }
}

// MARK: - Add wallet sheet

private struct AddWalletSheet: View {
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind = WalletKind.bitcoin
    @State private var address      = ""
    @State private var label        = ""
    @State private var testing      = false
    @State private var error: String?

    private var isAddressPlausible: Bool {
        AddressValidator.isPlausible(address.trimmingCharacters(in: .whitespaces), kind: selectedKind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "portfolio.add-wallet"))
                .font(.system(size: 13, weight: .semibold))
                .padding(.bottom, 16)

            // Network picker — only 3 items, menu is cleaner
            HStack {
                Text(String(localized: "portfolio.network"))
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $selectedKind) {
                    ForEach(WalletKind.allCases, id: \.rawValue) { k in
                        Text(verbatim: k.name).tag(k)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: selectedKind) { _, _ in error = nil; address = "" }
            }
            .padding(.bottom, 12)

            // Address field
            HStack(alignment: .center, spacing: 8) {
                Text("Address")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .frame(width: 80, alignment: .leading)
                TextField(selectedKind.placeholder, text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
            .padding(.bottom, 8)

            // Label field
            HStack(alignment: .center, spacing: 8) {
                Text(String(localized: "portfolio.wallet-label"))
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .frame(width: 80, alignment: .leading)
                TextField("My wallet", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            .padding(.bottom, 10)

            Text(String(localized: "portfolio.wallet-hint"))
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
                .fixedSize(horizontal: false, vertical: true)

            if let err = error {
                Text(verbatim: err)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#F4505E"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            Spacer().frame(height: 16)

            HStack(spacing: 8) {
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task { await verifyAndSave() }
                } label: {
                    if testing {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.75).frame(width: 14, height: 14)
                            Text(String(localized: "portfolio.testing"))
                        }
                    } else {
                        Text(String(localized: "portfolio.verify-save"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(testing || !isAddressPlausible)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    @MainActor
    private func verifyAndSave() async {
        let addr  = address.trimmingCharacters(in: .whitespaces)
        let lbl   = label.trimmingCharacters(in: .whitespaces)
        let wallet = PortfolioWallet(kind: selectedKind, address: addr,
                                     label: lbl.isEmpty ? String(addr.prefix(12)) + "…" : lbl)
        testing = true
        error = nil
        let err = await PortfolioController.validate(wallet: wallet)
        testing = false
        if let err {
            error = err
        } else {
            PortfolioSettings.addWallet(wallet)
            onSave()
            dismiss()
        }
    }
}
