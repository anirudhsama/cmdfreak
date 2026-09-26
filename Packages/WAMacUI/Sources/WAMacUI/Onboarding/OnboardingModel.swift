import CoreGraphics
import Observation
import WAKit

/// UI-side onboarding state layered over `SessionService`: which linking method is showing, the
/// phone number being entered, and errors thrown by bridge calls (as opposed to pairing errors
/// the bridge reports as events).
@MainActor @Observable
public final class OnboardingModel {
    public enum Method: Sendable {
        case qr
        case phoneEntry
        case code
    }

    public let client: WAClient
    public var session: SessionService { client.session }
    public private(set) var method: Method = .qr
    public var phoneNumber = ""
    public private(set) var localError: String?
    public private(set) var isBusy = false
    /// Code returned by `pairWithPhone`, shown until the bridge's own `pairCode` event confirms it.
    public private(set) var requestedCode: String?
    public private(set) var qrImage: CGImage?
    public private(set) var qrString: String?

    /// When true, no bridge calls are made (screenshot/debug mode).
    public var isInert = false

    @ObservationIgnored private var token: ObservationToken?

    public init(client: WAClient, initialMethod: Method = .qr) {
        self.client = client
        method = initialMethod
        token = WAMacUI.observe { [weak self] in self?.refreshQR() }
    }

    private func refreshQR() {
        let code: String? = if case .pairing(.qr(let s)) = session.state { s } else { nil }
        guard code != qrString else { return }
        qrString = code
        qrImage = code.flatMap { QRCode.image(for: $0, pixelSize: 480) }
    }

    /// Current pair code: the bridge's event wins over the value returned by the call.
    public var pairCode: String? {
        if case .pairing(.code(let c)) = session.state { return c }
        return requestedCode
    }

    public var errorMessage: String? { session.pairingError ?? localError }

    /// Connects and requests a QR code. Safe to call again after a logout.
    public func start() {
        guard !isInert else { return }
        localError = nil
        run {
            try await self.client.connect()
            try await self.client.startPairingQr()
        }
    }

    public func showPhoneEntry() {
        method = .phoneEntry
        localError = nil
    }

    public func showQR() {
        method = .qr
        requestedCode = nil
        localError = nil
        if case .pairing(.code) = session.state, !isInert {
            run {
                try await self.client.cancelPairing()
                try await self.client.startPairingQr()
            }
        }
    }

    public func requestCode() {
        let digits = phoneNumber.filter(\.isNumber)
        guard digits.count >= 7 else {
            localError = "Enter your full phone number, including the country code."
            return
        }
        localError = nil
        method = .code
        guard !isInert else { return }
        run {
            let code = try await self.client.pairWithPhone(digits)
            self.requestedCode = code
        }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do { try await body() } catch { localError = Self.describe(error) }
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let bridgeError = error as? BridgeError {
            switch bridgeError {
            case .NotImplemented(let what): return "Not available yet: \(what)"
            case .Network(let m): return "Network problem: \(m)"
            default: return String(describing: bridgeError)
            }
        }
        return error.localizedDescription
    }
}
