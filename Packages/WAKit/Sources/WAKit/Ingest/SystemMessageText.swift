import Foundation

/// Turns a WhatsApp stub (history-sync system message: `typeName` plus raw parameters joined by
/// U+001F) into the sentence the chat shows. `name` resolves a JID to a display name.
enum SystemMessageText {
    static let paramSeparator: Character = "\u{1F}"

    static func render(typeName: String?, raw: String?, actor: String, actorIsMe: Bool, name: (String) -> String) -> String {
        let params = raw.map { $0.split(separator: paramSeparator, omittingEmptySubsequences: true).map(String.init) } ?? []
        let who = actorIsMe ? "You" : name(actor)
        let jids = params.filter { $0.contains("@") }
        let people = list(jids.map(name))
        let first = params.first ?? ""

        switch typeName ?? "" {
        case "e2e_encrypted", "e2e_encrypted_now":
            return "Messages and calls are end-to-end encrypted."
        case "block_contact":
            return first == "false" ? "You unblocked this contact." : "You blocked this contact."
        case "group_create":
            return first.isEmpty ? "\(who) created this group" : "\(who) created group “\(first)”"
        case "group_change_subject":
            return first.isEmpty ? "\(who) changed the group name" : "\(who) changed the group name to “\(first)”"
        case "group_change_description":
            return "\(who) changed the group description"
        case "group_change_icon":
            return "\(who) changed this group's icon"
        case "group_participant_add":
            // The actor and the added JID can be one person in LID and phone-number form.
            if people.isEmpty { return "\(who) added a participant" }
            return jids.count == 1 && (jids[0] == actor || people == who) && !actorIsMe ? "\(who) joined" : "\(who) added \(people)"
        case "group_participant_remove":
            return people.isEmpty ? "\(who) removed a participant" : "\(who) removed \(people)"
        case "group_participant_leave":
            return "\(people.isEmpty ? who : people) left"
        case "group_participant_invite", "group_participant_linked_group_join":
            return "\(people.isEmpty ? who : people) joined using this group's invite link"
        case "group_participant_promote":
            return "\(who) made \(people.isEmpty ? "a participant" : people) an admin"
        case "group_participant_demote":
            return "\(who) removed \(people.isEmpty ? "a participant" : people) as admin"
        case "group_participant_change_number", "individual_change_number":
            return "\(jids.first.map(name) ?? who) changed their phone number"
        case "change_username":
            return "\(who) changed their username"
        case "pinned_message_in_chat":
            return "\(who) pinned a message"
        case "admin_revoke":
            return "A message was deleted by an admin"
        case "ephemeral_setting", "change_ephemeral_setting":
            let seconds = Int(first) ?? 0
            return seconds == 0 ? "\(who) turned off disappearing messages" : "\(who) turned on disappearing messages"
        case "community_link_sub_group":
            return "This group was added to a community"
        case let t where t.hasPrefix("biz_"):
            return "This business uses a secure service to manage this chat."
        default:
            let words = (typeName ?? "update").replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// "A", "A and B", "A, B and C".
    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
