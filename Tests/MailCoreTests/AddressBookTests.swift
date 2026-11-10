import Foundation
import Testing
@testable import MailCore

@Suite struct AddressBookTests {
    @Test func ranksPeopleYouWriteToAndCompletesTheField() {
        let me = EmailAddress(address: "alex@example.com")
        let noor = EmailAddress(name: "Noor Haddad", address: "noor@postbox.example")
        let nick = EmailAddress(name: "Nick Vos", address: "nick@vos.example")
        let sent = MailMessage(id: "1", mailboxID: "Sent", from: me, to: [noor], subject: "Hi", date: Date())
        let received = MailMessage(id: "2", mailboxID: "INBOX", from: nick, to: [me], subject: "Hey", date: Date())
        let book = AddressBook(threads: [MailThread(id: "a", messages: [sent]), MailThread(id: "b", messages: [received])],
                               me: [me.address])
        #expect(book.suggestions(for: "n").map(\.address) == ["noor@postbox.example", "nick@vos.example"])
        #expect(book.suggestions(for: "had").map(\.address) == ["noor@postbox.example"])
        #expect(AddressBook.lastToken(of: "Sam <sam@k.example>, no") == "no")
        #expect(AddressBook.completing("Sam <sam@k.example>, no", with: noor) == "Sam <sam@k.example>, Noor Haddad <noor@postbox.example>, ")
    }
}
