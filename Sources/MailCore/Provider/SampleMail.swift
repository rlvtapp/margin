import Foundation

/// Made-up mail for the sample account. Every domain uses the reserved `.example` TLD.
enum SampleMail {
    /// A one-page PDF, so sample attachments open in Preview.
    static func pdf(titled title: String) -> Data {
        let text = "BT /F1 18 Tf 72 720 Td (\(title.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: ""))) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    /// Collects sample messages; `add` returns the message so replies can point at it.
    final class Builder {
        let me: EmailAddress
        let now: Date
        let prefix: String
        var list: [MailMessage] = []

        init(me: EmailAddress, now: Date, prefix: String) {
            self.me = me
            self.now = now
            self.prefix = prefix
        }

        @discardableResult
        func add(
            _ from: EmailAddress, _ subject: String, minutesAgo: Double, body: String,
            to: [EmailAddress]? = nil, read: Bool = false, starred: Bool = false, attachment: String? = nil,
            headers: [String: String] = [:], replyTo previous: MailMessage? = nil, folder: String = "INBOX", invite: String? = nil
        ) -> MailMessage {
            var flags: MessageFlags = []
            if read { flags.insert(.seen) }
            if starred { flags.insert(.flagged) }
            let number = list.count + 1
            let message = MailMessage(
                id: "\(folder)/\(prefix)\(number)", mailboxID: folder, messageID: "sample-\(prefix)\(number)@margin.example",
                inReplyTo: previous?.messageID, references: previous.map { $0.references + [$0.messageID!] } ?? [],
                from: from, to: to ?? [me], subject: subject, date: now.addingTimeInterval(-minutesAgo * 60),
                snippet: HTMLText.snippet(body), flags: flags, hasAttachments: attachment != nil, listHeaders: headers,
                body: MessageBody(
                    text: body,
                    html: SampleHTML.html(for: subject),
                    attachments: attachment.map { [AttachmentInfo(filename: $0, mimeType: "application/pdf", data: SampleMail.pdf(titled: $0))] } ?? [],
                    invite: invite.flatMap(CalendarInvite.parse)
                )
            )
            list.append(message)
            return message
        }
    }

    static func messages(me: EmailAddress, now: Date) -> [MailMessage] {
        let mail = Builder(me: me, now: now, prefix: "w")
        func add(
            _ from: EmailAddress, _ subject: String, minutesAgo: Double, body: String,
            to: [EmailAddress]? = nil, read: Bool = false, starred: Bool = false, attachment: Bool = false,
            headers: [String: String] = [:], replyTo previous: MailMessage? = nil, folder: String = "INBOX"
        ) -> MailMessage {
            mail.add(from, subject, minutesAgo: minutesAgo, body: body, to: to, read: read, starred: starred,
                     attachment: attachment ? "plan-v3.pdf" : nil, headers: headers, replyTo: previous, folder: folder)
        }

        let maya = EmailAddress(name: "Maya Lindqvist", address: "maya@studionorth.example")
        let sam = EmailAddress(name: "Sam Okafor", address: "sam@kettle.example")
        let ines = EmailAddress(name: "Inès Moreau", address: "ines@moreau.example")
        let jun = EmailAddress(name: "Jun Park", address: "jun@fieldwork.example")
        let lena = EmailAddress(name: "Lena Fischer", address: "lena@harbor.example")

        let plan = add(maya, "Launch plan for March", minutesAgo: 600, body: """
        Hi,

        Attached is the third version of the launch plan. The main change is that we move the press day to the 12th, so the site has a full week live before anyone writes about it.

        Could you look at the timeline on page 2 and tell me if the dates work on your side?

        Maya
        """, read: true, attachment: true)
        let planReply = add(me, "Re: Launch plan for March", minutesAgo: 420, body: """
        The 12th works. One question: who owns the FAQ page? It's not on the timeline yet.
        """, to: [maya], read: true, replyTo: plan, folder: "INBOX")
        _ = add(maya, "Re: Launch plan for March", minutesAgo: 14, body: """
        Good catch. Sam said he'd take the FAQ, I've added it to the plan for the 8th.

        If that's fine with you I'll send the final version to everyone tomorrow morning.

        Maya
        """, replyTo: planReply)

        _ = add(sam, "Invoice question", minutesAgo: 95, body: """
        Hey! Quick one: the October invoice lists 14 seats, but we removed two people mid-month. Is that pro-rated on the next one, or should I ask for a corrected invoice?

        Thanks,
        Sam
        """)
        _ = add(ines, "Coffee next week?", minutesAgo: 180, body: """
        I'm in town Tuesday to Thursday. Want to grab a coffee and catch up? Any morning works for me.

        Inès
        """, starred: true)
        let interview = add(jun, "Interview notes from Tuesday", minutesAgo: 1500, body: """
        Here are my notes from the three customer interviews.

        - Everyone mentioned search first. They want to find a thread by what was said, not who said it.
        - Two of three use keyboard shortcuts daily.
        - Nobody uses folders anymore; they archive everything.

        Happy to walk through them on a call.
        Jun
        """, read: true)
        _ = add(lena, "Re: Interview notes from Tuesday", minutesAgo: 1380, body: """
        Really useful, thanks Jun. The folder point matches what we saw last year too.
        """, to: [jun, me], read: true, replyTo: interview)

        let bot = EmailAddress(name: "Harbor Cloud", address: "no-reply@harbor.example")
        _ = add(bot, "Your deployment finished", minutesAgo: 40, body: """
        Deployment #4821 to production finished in 2m 14s.

        All checks passed.
        """, headers: ["auto-submitted": "auto-generated"])
        _ = add(EmailAddress(name: "Fieldwork Bank", address: "notifications@fieldworkbank.example"), "Card payment of €42.10", minutesAgo: 260, body: """
        A payment of €42.10 to Corner Bakery was made with your card ending 4410.
        """, read: true)
        _ = add(EmailAddress(name: "Kettle", address: "security@kettle.example"), "New sign-in from Safari on Mac", minutesAgo: 720, body: """
        We noticed a new sign-in to your account from Safari on macOS in Amsterdam.

        If this was you, there's nothing to do.
        """)

        _ = add(EmailAddress(name: "Kettle", address: "no-reply@kettle.example"), "Your Kettle sign-in code", minutesAgo: 3, body: """
        Use 482 913 to sign in to Kettle. The code expires in 10 minutes.

        If you didn't try to sign in, you can ignore this email.
        """, headers: ["auto-submitted": "auto-generated"])
        let list1 = ["list-unsubscribe": "<mailto:leave@weekly.example>, <https://weekly.example/leave/8812>",
                     "list-unsubscribe-post": "List-Unsubscribe=One-Click", "list-id": "<weekly.design.example>"]
        _ = add(EmailAddress(name: "The Design Weekly", address: "editor@weekly.example"), "Issue 212: Quiet interfaces", minutesAgo: 300, body: """
        This week: why calm software wins, a short history of the command palette, and five inboxes we liked.
        """, headers: list1)
        _ = add(EmailAddress(name: "Field Notes", address: "letters@fieldnotes.example"), "On writing shorter emails", minutesAgo: 2900, body: """
        Most emails are three sentences too long. Here's a method for finding which three.
        """, read: true, headers: ["list-unsubscribe": "<https://fieldnotes.example/leave>"])
        _ = add(EmailAddress(name: "Open Standards Digest", address: "digest@standards.example"), "JMAP adoption, month in review", minutesAgo: 5000, body: """
        More servers now speak JMAP for mail, contacts and calendars. A look at what changed this month.
        """, read: true, headers: ["list-id": "<digest.standards.example>"])

        _ = add(me, "Hiring plan draft", minutesAgo: 3000, body: "Draft attached, comments welcome.", to: [lena], read: true, folder: "Sent")
        _ = add(sam, "Offsite photos", minutesAgo: 9000, body: "Here are the photos from the offsite!", read: true, folder: "Archive")
        let planning = Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: now))!.addingTimeInterval(10 * 3600)
        let stamp = { (date: Date) -> String in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.string(from: date)
        }
        mail.add(lena, "Invitation: Quarterly planning", minutesAgo: 25, body: """
        Lena Fischer has invited you to Quarterly planning.

        Join on video: https://meet.google.com/abc-defg-hij
        """, invite: """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:quarterly-planning-2026@harbor.example
        SEQUENCE:0
        SUMMARY:Quarterly planning
        DTSTART:\(stamp(planning))
        DTEND:\(stamp(planning.addingTimeInterval(3600)))
        LOCATION:Harbor office\\, room 3
        ORGANIZER;CN=Lena Fischer:mailto:lena@harbor.example
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:\(me.address)
        DESCRIPTION:Join on video: https://meet.google.com/abc-defg-hij
        END:VEVENT
        END:VCALENDAR
        """)
        _ = add(me, "Contract renewal", minutesAgo: 6 * 1440, body: "Hi Sam, here is the renewal for next year. Could you sign by Friday?",
                to: [sam], read: true, folder: "Sent")
        _ = add(EmailAddress(name: "The Design Weekly", address: "editor@weekly.example"), "Issue 211: Paper and screens", minutesAgo: 7 * 1440,
                body: "Last week: what printed newspapers still teach interface designers.", read: true, headers: list1)
        // Older issues, archived without being opened: what the newsletter clean-up counts.
        let digest = EmailAddress(name: "Open Standards Digest", address: "digest@openstandards.example")
        for week in 1...22 {
            _ = add(digest, "Standards roundup, week \(week)", minutesAgo: Double(week) * 7 * 1440 + 600,
                    body: "This week in open mail standards.", read: week == 9,
                    headers: ["list-unsubscribe": "<https://openstandards.example/leave/2231>", "list-unsubscribe-post": "List-Unsubscribe=One-Click"],
                    folder: "Archive")
        }
        return mail.list
    }

    static func personal(me: EmailAddress, now: Date) -> [MailMessage] {
        let mail = Builder(me: me, now: now, prefix: "p")
        let mum = EmailAddress(name: "Mum", address: "helen.rivera@homemail.example")
        let noor = EmailAddress(name: "Noor Haddad", address: "noor@postbox.example")
        let trip = mail.add(noor, "Lisbon in May?", minutesAgo: 75, body: """
        Flights are cheap the second weekend of May. I found a flat near the river with two bedrooms.

        Are you in? I'd book tonight.
        """)
        mail.add(me, "Re: Lisbon in May?", minutesAgo: 52, body: "Yes! Book it, I'll send you my half.", to: [noor], read: true, replyTo: trip)
        mail.add(noor, "Re: Lisbon in May?", minutesAgo: 6, body: """
        Booked. Sending the confirmation in a minute. Also: we're going to that tile museum, no arguments.
        """, replyTo: trip)
        mail.add(mum, "Sunday lunch", minutesAgo: 200, body: """
        Are you coming on Sunday? Your aunt is bringing the dog, so wear something you don't mind getting hairy.

        Love, Mum
        """, starred: true)
        mail.add(EmailAddress(name: "Coastline Rail", address: "tickets@coastline.example"), "Your tickets for 14 May", minutesAgo: 400, body: """
        Your e-tickets are attached. Show them on your phone at the gate.
        """, attachment: "tickets.pdf", headers: ["auto-submitted": "auto-generated"])
        mail.add(EmailAddress(name: "Parcel Post", address: "noreply@parcelpost.example"), "Your parcel is out for delivery", minutesAgo: 140, body: """
        Expected between 14:00 and 16:00.
        """, read: true)
        mail.add(EmailAddress(name: "The Slow Cook", address: "letters@slowcook.example"), "Five soups for cold evenings", minutesAgo: 1800, body: """
        This week: a lentil soup that takes ten minutes, and four that are worth the wait.
        """, headers: ["list-unsubscribe": "<mailto:leave@slowcook.example>"])
        mail.add(me, "Flat keys", minutesAgo: 6000, body: "I left the spare keys with the neighbour.", to: [noor], read: true, folder: "Sent")
        let deals = EmailAddress(name: "Corner Bakery", address: "news@cornerbakery.example")
        for week in 1...14 {
            mail.add(deals, "This week's bakes", minutesAgo: Double(week) * 7 * 1440 + 300, body: "Fresh this week: rye, cardamom buns and a new sourdough.",
                     read: week == 3, headers: ["list-unsubscribe": "<mailto:leave@cornerbakery.example>"], folder: "Archive")
        }
        return mail.list
    }
}
