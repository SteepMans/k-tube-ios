import SwiftUI
import UIKit

/// First start: the gateway key (or the link with it). YouTube is reached only through the external gateway.
struct KeyView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    var prefill: String = ""
    var inSheet = false
    @State private var input = ""
    @State private var address = ""
    @State private var checking = false
    @State private var error: String?
    @State private var done: Gateway.Info?

    private var needsAddress: Bool {
        GatewayService.builtInGateway.isEmpty || GatewayService.builtInGateway.hasPrefix("$(")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                AppLogo(size: 96).padding(.top, 40)
                VStack(spacing: 8) {
                    Text("K-Tube").font(.largeTitle.bold())
                    Text("YouTube без рекламы через внешний прокси-шлюз.\nВставьте ключ шлюза (tc_…) или ссылку с ключом.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                VStack(spacing: 12) {
                    HStack {
                        SecureField("Ключ tc_… или ссылка с ключом", text: $input)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        Button {
                            if let s = UIPasteboard.general.string { input = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                        } label: { Image(systemName: "doc.on.clipboard") }
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    if needsAddress && Gateway.parseInput(input).url == nil {
                        TextField("Адрес шлюза (https://…)", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .padding(14)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                if let done {
                    Label("Ключ принят: \(done.description.isEmpty ? "шлюз" : done.description), отклик \(done.rttMs) мс", systemImage: "checkmark.seal.fill")
                        .font(.footnote).foregroundStyle(.green)
                }
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        if checking { ProgressView().tint(.white) }
                        Text(checking ? "Проверяем…" : "Продолжить").bold()
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(checking || input.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Ключ хранится только в Связке ключей этого iPhone. Видео, картинки и поиск идут через шлюз: напрямую YouTube в России не открывается.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .onAppear { if input.isEmpty && !prefill.isEmpty { input = prefill } }
        .toolbar {
            if inSheet { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }

    private func check() async {
        error = nil
        checking = true
        defer { checking = false }
        let parsed = Gateway.parseInput(input)
        guard let token = parsed.token else {
            error = "Это не похоже на ключ шлюза: он начинается с tc_ и длиной 46 символов"
            return
        }
        var gw = parsed.url ?? ""
        if gw.isEmpty, needsAddress {
            guard let a = Gateway.normalize(address) else {
                error = "Укажите адрес шлюза: https://…"
                return
            }
            gw = a
        }
        do {
            done = try await app.saveKey(token: token, gatewayURL: gw)
            if inSheet { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The K-Tube mark: a lavender circle with a white play sign (the desktop icon).
struct AppLogo: View {
    var size: CGFloat = 64
    var shadow = true
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: "bcaaf7"), Color(hex: "8470de")], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "play.fill").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white).offset(x: size * 0.04)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: "8470de").opacity(shadow ? 0.4 : 0), radius: size * 0.15, y: size * 0.06)
    }
}
