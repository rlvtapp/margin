import AuthenticationServices
import MailCore
import SwiftUI

/// New Meeting: who, when, where, and on Microsoft 365, a room. Sent through the account's
/// calendar when it's connected, otherwise as an invitation by email.
struct NewMeetingView: View {
    @Bindable var model: MailModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthentication

    @State private var accountID: UUID?
    @State private var title = ""
    @State private var start = NewMeetingView.nextSlot()
    @State private var minutes = 30
    @State private var people = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var rooms: [MeetingRoom] = []
    @State private var busy: [String: [BusyTime]] = [:]
    @State private var choosingRoom = false
    @State private var isSending = false
    @State private var problem: String?

    private var account: MailAccount? { model.account(accountID) ?? model.accounts.first }
    private var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }
    private var attendees: [EmailAddress] { EmailAddress.parseList(people) ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Title", table: "Calendar"), text: $title, prompt: Text("Meeting", tableName: "Calendar"))
                    if model.accounts.count > 1 {
                        Picker(String(localized: "From", table: "Calendar"), selection: Binding(get: { account?.id }, set: { accountID = $0 })) {
                            ForEach(model.accounts) { Text(verbatim: $0.address.address).tag(Optional($0.id)) }
                        }
                    }
                }
                Section {
                    DatePicker(String(localized: "Starts", table: "Calendar"), selection: $start, displayedComponents: [.date, .hourAndMinute])
                    Picker(String(localized: "Length", table: "Calendar"), selection: $minutes) {
                        ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text(Self.length($0)).tag($0) }
                    }
                    if !attendees.isEmpty {
                        SuggestedTimesRow(model: model, people: attendees, destination: account.map { .account($0.id) },
                                          start: $start, end: Binding(get: { end }, set: { _ in }), showsBusy: false)
                    }
                }
                Section {
                    TextField(String(localized: "People", table: "Calendar"), text: $people, prompt: Text("Names or addresses", tableName: "Calendar"))
                        .autocorrectionDisabled()
                    RecipientSuggestions(model: model, field: $people)
                    ForEach(attendees.filter { isBusy($0.address) }, id: \.address) { person in
                        Label(String(localized: "\(person.displayName) is busy then", table: "Calendar"), systemImage: "exclamationmark.circle")
                            .foregroundStyle(Status.danger)
                    }
                } header: {
                    Text("People", tableName: "Calendar")
                }
                roomsSection
                Section {
                    if rooms.isEmpty {
                        TextField(String(localized: "Location", table: "Calendar"), text: $location, prompt: Text("Place or video link", tableName: "Calendar"))
                    }
                    TextEditor(text: $notes).frame(minHeight: 70)
                } header: {
                    Text("Notes", tableName: "Calendar")
                } footer: {
                    if let problem { Text(verbatim: problem).foregroundStyle(Status.danger) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "New Meeting", table: "Calendar"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", table: "Calendar")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSending ? "Sending…" : "Send") { Task { await send() } }
                        .disabled(isSending || attendees.isEmpty && rooms.isEmpty || account == nil)
                }
            }
            .sheet(isPresented: $choosingRoom) {
                if let account {
                    RoomPicker(model: model, account: account, start: start, end: end, chosen: rooms.map(\.id)) { room in
                        rooms.append(room)
                    }
                }
            }
            .task(id: "\(people)|\(start)|\(minutes)|\(account?.id.uuidString ?? "")") { await checkBusy() }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    @ViewBuilder
    private var roomsSection: some View {
        if let account, model.oauthProvider(of: account) != nil {
            Section {
                ForEach(rooms) { room in
                    LabeledContent {
                        Button(String(localized: "Remove", table: "Calendar")) { rooms.removeAll { $0.id == room.id } }.buttonStyle(.borderless)
                    } label: {
                        SettingLabel(verbatim: room.name)
                    }
                }
                if model.canListRooms(account) {
                    Button(String(localized: "Add Room…", table: "Calendar")) { choosingRoom = true }
                } else if model.canAskForAccess(account) {
                    Button(model.usesAccountCalendar(account) ? "Show Rooms…" : "Connect Calendar and Rooms…") {
                        Task { await connect([.calendar, .rooms], account: account) }
                    }
                }
            } header: {
                Text("Room", tableName: "Calendar")
            } footer: {
                if !model.canListRooms(account) {
                    Text("Margin asks your account for your calendar and your organization's rooms. Some organizations need an admin to allow room lists.", tableName: "Calendar")
                }
            }
        }
    }

    private func isBusy(_ address: String) -> Bool {
        busy[address.lowercased()]?.contains { $0.overlaps(start, end) } ?? false
    }

    private func checkBusy() async {
        guard let account, model.usesAccountCalendar(account), !attendees.isEmpty else { busy = [:]; return }
        try? await Task.sleep(for: .milliseconds(500))
        busy = (try? await model.busyTimes(for: attendees.map(\.address), from: start, to: end, account: account)) ?? [:]
    }

    private func connect(_ access: Set<APIAccess>, account: MailAccount) async {
        do {
            try await model.requestAccess(access, for: account) { url, scheme in
                try await webAuthentication.authenticate(using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
            }
            if model.canListRooms(account) { choosingRoom = true }
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return
        } catch {
            problem = error.localizedDescription
        }
    }

    private func send() async {
        guard let account else { return }
        isSending = true
        defer { isSending = false }
        let meeting = MeetingRequest(
            title: title.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Meeting", table: "Calendar") : title,
            start: start, end: end, location: location.isEmpty ? nil : location, notes: notes,
            organizer: account.address, attendees: attendees, rooms: rooms
        )
        do {
            try await model.sendMeeting(meeting, from: account)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The next half hour.
    static func nextSlot(after date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: date)
        let rounded = calendar.date(bySetting: .second, value: 0, of: date) ?? date
        return calendar.date(byAdding: .minute, value: minute < 30 ? 30 - minute : 60 - minute, to: rounded) ?? date
    }

    static func length(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// The organization's rooms, with whether each is free for the meeting's time.
struct RoomPicker: View {
    let model: MailModel
    let account: MailAccount
    let start: Date
    let end: Date
    let chosen: [MeetingRoom.ID]
    let onChoose: (MeetingRoom) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rooms: [MeetingRoom] = []
    @State private var busy: [String: [BusyTime]] = [:]
    @State private var search = ""
    @State private var freeOnly = true
    @State private var loading = true
    @State private var problem: String?
    @State private var typed = ""

    private var shown: [MeetingRoom] {
        rooms.filter { room in
            !chosen.contains(room.id)
                && (search.isEmpty || room.name.localizedCaseInsensitiveContains(search) || (room.building ?? "").localizedCaseInsensitiveContains(search))
                && (!freeOnly || isFree(room))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack(spacing: Space.s) { ProgressView().controlSize(.small); Text("Finding rooms…", tableName: "Calendar").foregroundStyle(.secondary) }
                } else if let problem {
                    Text(verbatim: problem).foregroundStyle(Status.danger)
                } else if shown.isEmpty {
                    Text(freeOnly ? "No free rooms at that time." : "No rooms found.").foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        TextField(String(localized: "Room address", table: "Calendar"), text: $typed, prompt: Text("Add a room by its address", tableName: "Calendar"))
                            .autocorrectionDisabled()
                            .onSubmit(addTyped)
                        Button(String(localized: "Add", table: "Calendar"), action: addTyped).disabled(!EmailAddress.isValid(typed.trimmingCharacters(in: .whitespaces)))
                    }
                }
                ForEach(shown) { room in
                    Button {
                        onChoose(room)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: room.name).foregroundStyle(Ink.primary)
                                if let detail = detail(room) {
                                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(isFree(room) ? "Free" : "Busy")
                                .font(.caption)
                                .foregroundStyle(isFree(room) ? Status.done : Status.danger)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $search, prompt: Text("Search rooms", tableName: "Calendar"))
            .navigationTitle(String(localized: "Rooms", table: "Calendar"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", table: "Calendar")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Toggle(String(localized: "Free only", table: "Calendar"), isOn: $freeOnly) }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    private func addTyped() {
        let address = typed.trimmingCharacters(in: .whitespaces)
        guard EmailAddress.isValid(address) else { return }
        onChoose(MeetingRoom(email: address, name: rooms.first { $0.id == address.lowercased() }?.name ?? address))
        dismiss()
    }

    private func isFree(_ room: MeetingRoom) -> Bool {
        !(busy[room.id]?.contains { $0.overlaps(start, end) } ?? false)
    }

    private func detail(_ room: MeetingRoom) -> String? {
        var parts: [String] = []
        if let building = room.building { parts.append(building) }
        if let floor = room.floor { parts.append(floor) }
        if let capacity = room.capacity { parts.append(String(localized: "\(capacity) seats", table: "Calendar")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load() async {
        defer { loading = false }
        do {
            rooms = try await model.meetingRooms(for: account)
            // Free/busy is asked for in groups; a large organization has many rooms.
            for group in stride(from: 0, to: min(rooms.count, 200), by: 50).map({ Array(rooms[$0..<min($0 + 50, rooms.count)]) }) {
                let found = try await model.busyTimes(for: group.map(\.email), from: start, to: end, account: account)
                busy.merge(found) { $1 }
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}
