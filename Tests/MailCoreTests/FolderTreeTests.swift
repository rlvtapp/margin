import Testing
@testable import MailCore

@Suite struct FolderTreeTests {
    @Test func nestsFoldersAndFollowsTheChosenOrder() {
        let folders = [
            Mailbox(id: "Projects/2026", name: "2026", role: .other, parentID: "Projects"),
            Mailbox(id: "Clients", name: "Clients", role: .other),
            Mailbox(id: "Projects", name: "Projects", role: .other),
            Mailbox(id: "Projects/2025", name: "2025", role: .other, parentID: "Projects"),
        ]
        let tree = Mailbox.tree(folders)
        #expect(tree.map(\.mailbox.id) == ["Clients", "Projects", "Projects/2025", "Projects/2026"])
        #expect(tree.map(\.depth) == [0, 0, 1, 1])
        let ordered = Mailbox.tree(folders, order: ["Projects", "Clients", "Projects/2026"])
        #expect(ordered.map(\.mailbox.id) == ["Projects", "Projects/2026", "Projects/2025", "Clients"])
    }

    @Test func readsTheParentFromTheImapName() {
        let item = IMAPListItem([.atom("LIST"), .list([]), .quoted("/"), .quoted("Projects/2026")])
        #expect(item?.parent == "Projects")
        #expect(item?.shortName == "2026")
    }
}
