import AppKit
import SwiftUI
import WAKit

enum ChatListMetrics {
    static let minWidth: CGFloat = 260
    static let idealWidth: CGFloat = 320
    static let maxWidth: CGFloat = 480
}

/// Middle column: the chat list, with a status footer that appears while history sync runs or
/// the connection is down.
@MainActor
final class ChatListColumnViewController: NSViewController {
    let chatList: ChatListViewController
    private let footer: NSHostingView<SidebarFooter>
    private let session: SessionService
    private var footerHeight: NSLayoutConstraint!
    private var token: ObservationToken?

    init(chatList: ChatListViewController, session: SessionService) {
        self.chatList = chatList
        self.session = session
        footer = NSHostingView(rootView: SidebarFooter(session: session))
        super.init(nibName: nil, bundle: nil)
        addChild(chatList)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = ShellRootView()
        let listView = chatList.view
        for v in [listView, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        footer.sizingOptions = []
        footerHeight = footer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            listView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // Below the titlebar: the list column has no scroll-edge material behind the title.
            listView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            listView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footerHeight,
        ])
        view = root

        token = WAMacUI.observe { [weak self] in
            guard let self else { return }
            let visible = SidebarFooter.status(for: session) != nil
            footerHeight.constant = visible ? 28 : 0
        }
    }
}

private struct SidebarFooter: View {
    let session: SessionService

    enum Status: Equatable {
        case syncing(conversations: Int, percent: Int?)
        case offline
        case connecting
    }

    static func status(for session: SessionService) -> Status? {
        if case .syncing(let p) = session.state { return .syncing(conversations: p.conversations, percent: p.percent) }
        if let p = session.backgroundSync { return .syncing(conversations: p.conversations, percent: p.percent) }
        switch session.connection {
        case .connected: return nil
        case .connecting: return .connecting
        case .disconnected: return session.state == .ready ? .offline : nil
        }
    }

    var body: some View {
        if let status = Self.status(for: session) {
            HStack(spacing: 6) {
                switch status {
                case .syncing(let n, let percent):
                    ProgressView().controlSize(.mini)
                    Text(n == 0 ? "Syncing chats…" : "Syncing chats… \(n) conversations")
                    if let percent { Text("\(percent)%").monospacedDigit() }
                case .connecting:
                    ProgressView().controlSize(.mini)
                    Text("Connecting…")
                case .offline:
                    Image(systemName: "wifi.slash")
                    Text("Offline")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(height: 28)
        }
    }
}
