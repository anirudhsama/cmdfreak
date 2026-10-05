import SwiftUI
import WAKit

/// The group members matching the name typed after "@" in the compose editor.
@MainActor @Observable
final class MentionPickerModel {
    var members: [GroupMember] = [] { didSet { refilter() } }
    /// What follows the "@"; nil when no mention is being typed.
    var query: String? { didSet { if query != oldValue { refilter() } } }
    private(set) var results: [GroupMember] = []
    var selectedIndex = 0
    var onPick: ((GroupMember) -> Void)?

    var isShowing: Bool { query != nil && !results.isEmpty }
    var selected: GroupMember? { results.indices.contains(selectedIndex) ? results[selectedIndex] : nil }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    func pick(at index: Int) {
        guard results.indices.contains(index) else { return }
        onPick?(results[index])
    }

    /// Name matches best first (prefix, word prefix, initials, substring), then phone-number digits.
    /// Loose subsequence matches are left out: they would keep the list open over ordinary text.
    private func refilter() {
        selectedIndex = 0
        guard let query else { results = []; return }
        let q = FuzzyMatcher.normalize(query)
        guard !q.isEmpty else { results = members; return }
        let digits = FuzzyMatcher.digits(q)
        let scored = members.enumerated().compactMap { i, m -> (Int, Int)? in
            if let s = FuzzyMatcher.score(q, in: FuzzyMatcher.normalize(m.name)), s > FuzzyMatcher.subsequenceMax { return (i, s) }
            if digits.count >= 3, digits.count == q.count, let phone = m.phone, FuzzyMatcher.digits(phone).contains(digits) {
                return (i, FuzzyMatcher.substring)
            }
            return nil
        }
        results = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map { members[$0.0] }
    }
}

struct MentionPickerView: View {
    @Bindable var model: MentionPickerModel

    static let width: CGFloat = 300
    static let rowHeight: CGFloat = 36
    static let maxRows = 5
    static let padding: CGFloat = 6

    static func height(rows: Int) -> CGFloat {
        CGFloat(min(rows, maxRows)) * rowHeight + padding * 2
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, member in
                        MentionPickerRow(member: member, isSelected: index == model.selectedIndex)
                            .id(member.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.pick(at: index) }
                    }
                }
                .padding(Self.padding)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.selectedIndex) { _, index in
                guard model.results.indices.contains(index) else { return }
                proxy.scrollTo(model.results[index].id)
            }
        }
        .frame(width: Self.width, height: Self.height(rows: model.results.count))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct MentionPickerRow: View {
    let member: GroupMember
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            ContactAvatar(jid: member.jid, title: member.name, url: member.avatarURL, size: 24)
                .frame(width: 24, height: 24)
            Text(member.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let phone = member.phone, phone != member.name {
                Text(phone)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: MentionPickerView.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.waGreen)
            }
        }
    }
}
