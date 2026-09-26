import SwiftUI
import WAKit

/// Centered glass card that walks through linking: QR (default) or phone-number code, then sync.
struct OnboardingView: View {
    let model: OnboardingModel

    private var session: SessionService { model.session }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(width: 360)
                .padding(32)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .syncing:
            syncing
        case .ready:
            syncing
        case .loggedOut(let reason):
            loggedOut(reason)
        case .unpaired, .pairing:
            switch model.method {
            case .qr: qr
            case .phoneEntry: phoneEntry
            case .code: code
            }
        }
    }

    // MARK: Screens

    private var qr: some View {
        VStack(spacing: 20) {
            header("Link with WhatsApp", "Open WhatsApp on your phone, tap Linked Devices, then scan this code.")
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white)
                    .frame(width: 240, height: 240)
                if let image = model.qrImage {
                    Image(decorative: image, scale: 2)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 216, height: 216)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Waiting for code…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.qrString)
            errorLine
            Button("Link with phone number instead") { model.showPhoneEntry() }
                .buttonStyle(.link)
        }
    }

    private var phoneEntry: some View {
        VStack(spacing: 20) {
            header("Link with phone number", "Enter the phone number of your WhatsApp account, with country code.")
            TextField("+1 555 123 4567", text: Bindable(model).phoneNumber)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 18))
                .multilineTextAlignment(.center)
                .frame(width: 240)
                .onSubmit { model.requestCode() }
            errorLine
            HStack(spacing: 12) {
                Button("Use QR code") { model.showQR() }
                Button("Get code") { model.requestCode() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
            }
        }
    }

    private var code: some View {
        VStack(spacing: 20) {
            header("Enter this code on your phone", "In WhatsApp, tap Linked Devices, Link a Device, then “Link with phone number instead”.")
            if let code = model.pairCode {
                Text(Self.grouped(code))
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .kerning(2)
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
            } else {
                ProgressView().padding(.vertical, 20)
            }
            errorLine
            Button("Use QR code instead") { model.showQR() }
                .buttonStyle(.link)
        }
    }

    private var syncing: some View {
        VStack(spacing: 20) {
            header("Linked", "Waiting for your chats to arrive. This can take a moment.")
            ProgressView().controlSize(.large).padding(.vertical, 8)
            if case .syncing(let p) = session.state, p.conversations > 0 {
                Text("Syncing chats… \(p.conversations) conversations").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Syncing chats…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func loggedOut(_ reason: String) -> some View {
        VStack(spacing: 20) {
            header("Logged out", reason.isEmpty ? "This Mac was unlinked from your WhatsApp account." : reason)
            Button("Link again") {
                model.showQR()
                model.start()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Pieces

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .padding(.bottom, 4)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func grouped(_ code: String) -> String {
        let raw = code.filter { $0.isLetter || $0.isNumber }
        guard raw.count == 8 else { return code }
        return raw.prefix(4) + "-" + raw.suffix(4)
    }
}

