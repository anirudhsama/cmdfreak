import Testing
@testable import WAKit

@Suite struct SystemMessageTextTests {
    private let names = ["1@s.whatsapp.net": "Asha", "2@s.whatsapp.net": "Ben", "3@lid": "Chen"]
    private func render(_ type: String, _ params: [String], actor: String = "1@s.whatsapp.net", me: Bool = false) -> String {
        SystemMessageText.render(typeName: type, raw: params.joined(separator: "\u{1F}"), actor: actor, actorIsMe: me,
                                 name: { names[$0] ?? "Someone" })
    }

    @Test func groupMembership() {
        #expect(render("group_participant_add", ["2@s.whatsapp.net", "3@lid"]) == "Asha added Ben and Chen")
        #expect(render("group_participant_add", ["1@s.whatsapp.net"]) == "Asha joined")
        #expect(render("group_participant_remove", ["2@s.whatsapp.net"], me: true) == "You removed Ben")
        #expect(render("group_participant_leave", ["2@s.whatsapp.net"]) == "Ben left")
        #expect(render("group_participant_linked_group_join", ["3@lid"]) == "Chen joined using this group's invite link")
    }

    @Test func rawParametersNeverLeak() {
        #expect(render("block_contact", ["true"]) == "You blocked this contact.")
        #expect(render("block_contact", ["false"]) == "You unblocked this contact.")
        #expect(render("individual_change_number", ["9@lid", "8@s.whatsapp.net"]) == "Someone changed their phone number")
        #expect(render("group_change_subject", ["Trip"]) == "Asha changed the group name to “Trip”")
        #expect(render("some_new_stub", ["x@lid"]) == "Some new stub")
    }
}
