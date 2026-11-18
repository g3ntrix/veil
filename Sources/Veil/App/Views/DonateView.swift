import SwiftUI

struct DonateView: View {
    struct Coin: Identifiable {
        let id: String
        let name: String
        let network: String
        let address: String
        let warning: String
    }

    static let coins: [Coin] = [
        Coin(id: "usdt", name: "USDT", network: "BEP20",
             address: "0x71F41696c60C4693305e67eE3Baa650a4E3dA796",
             warning: "Send USDT on BNB Smart Chain (BEP20) only. Coins sent on another network are lost."),
        Coin(id: "ton", name: "TON", network: "TON",
             address: "UQCriHkMUa6h9oN059tyC23T13OsQhGGM3hUS2S4IYRBZgvx",
             warning: "Send TON on the TON network only."),
        Coin(id: "trx", name: "TRX", network: "TRON",
             address: "TFrCzU7bDey9WSh3fhqCBqhaiMzr8VhcUV",
             warning: "Send TRX on the TRON network only."),
    ]

    @State private var selected = coins[0].id
    private let coffee = Color(red: 0.84, green: 0.55, blue: 0.29)

    var body: some View {
        let coin = Self.coins.first { $0.id == selected } ?? Self.coins[0]
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                coinPicker
                HStack(alignment: .top, spacing: 16) {
                    qrPanel(coin).frame(width: 236)
                    addressPanel(coin)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(LinearGradient(colors: [coffee, Color(red: 0.55, green: 0.33, blue: 0.18)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: coffee.opacity(0.4), radius: 12, y: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Buy me a coffee").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Veil is free and open source, with no ads and no tracking. If it's useful to you, a coffee helps support its development.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link(destination: Brand.developerURL) {
                    Label("github.com/\(Brand.developer)", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.callout.weight(.medium))
                }
                .padding(.top, 2)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.045))
                .overlay(RadialGradient(colors: [coffee.opacity(0.18), .clear], center: UnitPoint(x: 0.08, y: 0.5),
                                        startRadius: 2, endRadius: 220))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var coinPicker: some View {
        HStack(spacing: 10) {
            ForEach(Self.coins) { c in
                let on = c.id == selected
                Button { withAnimation(.easeOut(duration: 0.15)) { selected = c.id } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(c.network).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(on ? coffee.opacity(0.16) : Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(on ? coffee.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(c.name) on \(c.network)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func panel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func qrPanel(_ coin: Coin) -> some View {
        panel {
            VStack(spacing: 10) {
                if let img = QRCode.image(coin.address, size: 180) {
                    Image(nsImage: img).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 156, height: 156)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
                        .accessibilityLabel("QR code for the \(coin.name) address")
                }
                Text("Scan with your wallet").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func addressPanel(_ coin: Coin) -> some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(coin.name) address").font(.headline)
                Text(verbatim: coin.address)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                CopyAddressButton(address: coin.address, tint: coffee)
                Label(coin.warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("Thank you for supporting Veil.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CopyAddressButton: View {
    let address: String
    let tint: Color
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied = false } }
        } label: {
            Label(copied ? "Address copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(copied ? .green : tint)
        .controlSize(.large)
    }
}
