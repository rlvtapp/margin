import Foundation

/// Time zones as invitations and Microsoft name them.
///
/// An iCalendar `TZID` is just a label. Apple and Google use IANA names (`Europe/Amsterdam`);
/// Outlook and Exchange use Windows names (`W. Europe Standard Time`) or a display name
/// (`(UTC+01:00) Amsterdam, Berlin, …`); some older clients prefix the IANA name
/// (`/mozilla.org/20070129_1/Europe/Berlin`). The invite usually carries its own `VTIMEZONE`
/// rules as well, which are used when the label means nothing to us.
public enum CalendarTimeZones {
    /// The zone a `TZID` (or a Microsoft Graph `timeZone`) names, if it names one we know.
    public static func zone(named name: String) -> TimeZone? {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
        guard !trimmed.isEmpty else { return nil }
        if let zone = TimeZone(identifier: trimmed) { return zone }
        if let iana = windows[trimmed] ?? windowsLowercased[trimmed.lowercased()], let zone = TimeZone(identifier: iana) {
            return zone
        }
        // `/mozilla.org/20070129_1/Europe/Berlin`, `/softwarestudio.org/Olson_20011030_5/America/New_York`:
        // the IANA name is the last two or three parts.
        let parts = trimmed.split(separator: "/").map(String.init)
        for count in [3, 2] where parts.count > count {
            if let zone = TimeZone(identifier: parts.suffix(count).joined(separator: "/")) { return zone }
        }
        return nil
    }

    /// The `VTIMEZONE` definitions in a calendar, by `TZID`.
    static func definitions(in lines: [String]) -> [String: ZoneRules] {
        var result: [String: ZoneRules] = [:]
        var tzid: String?
        var observances: [ZoneRules.Observance] = []
        var current: [String: String]?
        var isDaylight = false
        for line in lines {
            let upper = line.uppercased()
            switch upper {
            case "BEGIN:VTIMEZONE": tzid = nil; observances = []
            case "END:VTIMEZONE":
                if let tzid, !observances.isEmpty { result[tzid] = ZoneRules(observances: observances) }
                tzid = nil
            case "BEGIN:STANDARD", "BEGIN:DAYLIGHT": current = [:]; isDaylight = upper == "BEGIN:DAYLIGHT"
            case "END:STANDARD", "END:DAYLIGHT":
                if let fields = current, let observance = ZoneRules.Observance(fields: fields, isDaylight: isDaylight) {
                    observances.append(observance)
                }
                current = nil
            case "BEGIN:VEVENT": return result
            default:
                guard let colon = CalendarInvite.valueColon(in: line) else { continue }
                let name = line[..<colon].split(separator: ";").first.map { String($0).uppercased() } ?? ""
                let value = String(line[line.index(after: colon)...])
                if var fields = current {
                    // RDATE may repeat; keep them all.
                    fields[name] = fields[name].map { $0 + "," + value } ?? value
                    current = fields
                } else if name == "TZID" {
                    tzid = value
                }
            }
        }
        return result
    }

    /// Windows time zone names → IANA (CLDR `windowsZones.xml`, territory 001, plus older names
    /// Exchange still sends).
    static let windows: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12",
        "UTC-11": "Etc/GMT+11",
        "Aleutian Standard Time": "America/Adak",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Marquesas Standard Time": "Pacific/Marquesas",
        "Alaskan Standard Time": "America/Anchorage",
        "UTC-09": "Etc/GMT+9",
        "Pacific Standard Time (Mexico)": "America/Tijuana",
        "UTC-08": "Etc/GMT+8",
        "Pacific Standard Time": "America/Los_Angeles",
        "US Mountain Standard Time": "America/Phoenix",
        "Mountain Standard Time (Mexico)": "America/Mazatlan",
        "Mexico Standard Time 2": "America/Chihuahua",
        "Mountain Standard Time": "America/Denver",
        "Yukon Standard Time": "America/Whitehorse",
        "Central America Standard Time": "America/Guatemala",
        "Central Standard Time": "America/Chicago",
        "Easter Island Standard Time": "Pacific/Easter",
        "Central Standard Time (Mexico)": "America/Mexico_City",
        "Mexico Standard Time": "America/Mexico_City",
        "Canada Central Standard Time": "America/Regina",
        "SA Pacific Standard Time": "America/Bogota",
        "Eastern Standard Time (Mexico)": "America/Cancun",
        "Eastern Standard Time": "America/New_York",
        "Haiti Standard Time": "America/Port-au-Prince",
        "Cuba Standard Time": "America/Havana",
        "US Eastern Standard Time": "America/Indiana/Indianapolis",
        "Turks And Caicos Standard Time": "America/Grand_Turk",
        "Paraguay Standard Time": "America/Asuncion",
        "Atlantic Standard Time": "America/Halifax",
        "Venezuela Standard Time": "America/Caracas",
        "Central Brazilian Standard Time": "America/Cuiaba",
        "SA Western Standard Time": "America/La_Paz",
        "Pacific SA Standard Time": "America/Santiago",
        "Newfoundland Standard Time": "America/St_Johns",
        "Tocantins Standard Time": "America/Araguaina",
        "E. South America Standard Time": "America/Sao_Paulo",
        "SA Eastern Standard Time": "America/Cayenne",
        "Argentina Standard Time": "America/Argentina/Buenos_Aires",
        "Greenland Standard Time": "America/Nuuk",
        "Montevideo Standard Time": "America/Montevideo",
        "Magallanes Standard Time": "America/Punta_Arenas",
        "Saint Pierre Standard Time": "America/Miquelon",
        "Bahia Standard Time": "America/Bahia",
        "UTC-02": "Etc/GMT+2",
        "Mid-Atlantic Standard Time": "Etc/GMT+2",
        "Azores Standard Time": "Atlantic/Azores",
        "Cape Verde Standard Time": "Atlantic/Cape_Verde",
        "UTC": "Etc/UTC",
        "Coordinated Universal Time": "Etc/UTC",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "Sao Tome Standard Time": "Africa/Sao_Tome",
        "Morocco Standard Time": "Africa/Casablanca",
        "W. Europe Standard Time": "Europe/Berlin",
        "Central Europe Standard Time": "Europe/Budapest",
        "Romance Standard Time": "Europe/Paris",
        "Central European Standard Time": "Europe/Warsaw",
        "W. Central Africa Standard Time": "Africa/Lagos",
        "Jordan Standard Time": "Asia/Amman",
        "GTB Standard Time": "Europe/Bucharest",
        "Middle East Standard Time": "Asia/Beirut",
        "Egypt Standard Time": "Africa/Cairo",
        "E. Europe Standard Time": "Europe/Chisinau",
        "Syria Standard Time": "Asia/Damascus",
        "West Bank Standard Time": "Asia/Hebron",
        "South Africa Standard Time": "Africa/Johannesburg",
        "FLE Standard Time": "Europe/Kiev",
        "Israel Standard Time": "Asia/Jerusalem",
        "South Sudan Standard Time": "Africa/Juba",
        "Kaliningrad Standard Time": "Europe/Kaliningrad",
        "Sudan Standard Time": "Africa/Khartoum",
        "Libya Standard Time": "Africa/Tripoli",
        "Namibia Standard Time": "Africa/Windhoek",
        "Arabic Standard Time": "Asia/Baghdad",
        "Turkey Standard Time": "Europe/Istanbul",
        "Arab Standard Time": "Asia/Riyadh",
        "Belarus Standard Time": "Europe/Minsk",
        "Russian Standard Time": "Europe/Moscow",
        "E. Africa Standard Time": "Africa/Nairobi",
        "Volgograd Standard Time": "Europe/Volgograd",
        "Iran Standard Time": "Asia/Tehran",
        "Arabian Standard Time": "Asia/Dubai",
        "Astrakhan Standard Time": "Europe/Astrakhan",
        "Azerbaijan Standard Time": "Asia/Baku",
        "Russia Time Zone 3": "Europe/Samara",
        "Mauritius Standard Time": "Indian/Mauritius",
        "Saratov Standard Time": "Europe/Saratov",
        "Georgian Standard Time": "Asia/Tbilisi",
        "Caucasus Standard Time": "Asia/Yerevan",
        "Armenian Standard Time": "Asia/Yerevan",
        "Afghanistan Standard Time": "Asia/Kabul",
        "West Asia Standard Time": "Asia/Tashkent",
        "Qyzylorda Standard Time": "Asia/Qyzylorda",
        "Ekaterinburg Standard Time": "Asia/Yekaterinburg",
        "Pakistan Standard Time": "Asia/Karachi",
        "India Standard Time": "Asia/Kolkata",
        "Sri Lanka Standard Time": "Asia/Colombo",
        "Nepal Standard Time": "Asia/Kathmandu",
        "Central Asia Standard Time": "Asia/Bishkek",
        "Bangladesh Standard Time": "Asia/Dhaka",
        "Omsk Standard Time": "Asia/Omsk",
        "Myanmar Standard Time": "Asia/Yangon",
        "SE Asia Standard Time": "Asia/Bangkok",
        "Altai Standard Time": "Asia/Barnaul",
        "W. Mongolia Standard Time": "Asia/Hovd",
        "North Asia Standard Time": "Asia/Krasnoyarsk",
        "N. Central Asia Standard Time": "Asia/Novosibirsk",
        "Tomsk Standard Time": "Asia/Tomsk",
        "China Standard Time": "Asia/Shanghai",
        "North Asia East Standard Time": "Asia/Irkutsk",
        "Singapore Standard Time": "Asia/Singapore",
        "Malay Peninsula Standard Time": "Asia/Singapore",
        "W. Australia Standard Time": "Australia/Perth",
        "Taipei Standard Time": "Asia/Taipei",
        "Ulaanbaatar Standard Time": "Asia/Ulaanbaatar",
        "Aus Central W. Standard Time": "Australia/Eucla",
        "Transbaikal Standard Time": "Asia/Chita",
        "Tokyo Standard Time": "Asia/Tokyo",
        "North Korea Standard Time": "Asia/Pyongyang",
        "Korea Standard Time": "Asia/Seoul",
        "Yakutsk Standard Time": "Asia/Yakutsk",
        "Cen. Australia Standard Time": "Australia/Adelaide",
        "AUS Central Standard Time": "Australia/Darwin",
        "E. Australia Standard Time": "Australia/Brisbane",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "West Pacific Standard Time": "Pacific/Port_Moresby",
        "Tasmania Standard Time": "Australia/Hobart",
        "Vladivostok Standard Time": "Asia/Vladivostok",
        "Lord Howe Standard Time": "Australia/Lord_Howe",
        "Bougainville Standard Time": "Pacific/Bougainville",
        "Russia Time Zone 10": "Asia/Srednekolymsk",
        "Magadan Standard Time": "Asia/Magadan",
        "Norfolk Standard Time": "Pacific/Norfolk",
        "Sakhalin Standard Time": "Asia/Sakhalin",
        "Central Pacific Standard Time": "Pacific/Guadalcanal",
        "Russia Time Zone 11": "Asia/Kamchatka",
        "Kamchatka Standard Time": "Asia/Kamchatka",
        "New Zealand Standard Time": "Pacific/Auckland",
        "UTC+12": "Etc/GMT-12",
        "Fiji Standard Time": "Pacific/Fiji",
        "Chatham Islands Standard Time": "Pacific/Chatham",
        "UTC+13": "Etc/GMT-13",
        "Tonga Standard Time": "Pacific/Tongatapu",
        "Samoa Standard Time": "Pacific/Apia",
        "Line Islands Standard Time": "Pacific/Kiritimati",
    ]

    private static let windowsLowercased = Dictionary(uniqueKeysWithValues: windows.map { ($0.key.lowercased(), $0.value) })
}

/// A `VTIMEZONE`'s standard and daylight rules (RFC 5545 §3.6.5).
struct ZoneRules: Sendable {
    struct Observance: Sendable {
        /// When it first applies, as wall-clock time (read as if it were UTC).
        var start: Date
        var offsetFrom: Int
        var offsetTo: Int
        var isDaylight: Bool
        var rule: YearlyRule?
        var extraStarts: [Date]

        init?(fields: [String: String], isDaylight: Bool) {
            guard let start = fields["DTSTART"].flatMap(ZoneRules.wallTime),
                  let to = fields["TZOFFSETTO"].flatMap(ZoneRules.offset) else { return nil }
            self.start = start
            self.offsetTo = to
            self.offsetFrom = fields["TZOFFSETFROM"].flatMap(ZoneRules.offset) ?? to
            self.isDaylight = isDaylight
            self.rule = fields["RRULE"].flatMap(YearlyRule.init)
            self.extraStarts = (fields["RDATE"] ?? "").split(separator: ",").compactMap { ZoneRules.wallTime(String($0)) }
        }

        /// The moments it begins in and before `year`, as wall-clock time.
        func starts(through year: Int) -> [Date] {
            var result = [start] + extraStarts
            if let rule {
                let first = ZoneRules.calendar.component(.year, from: start)
                for candidate in max(first, year - 1)...max(first, year) {
                    if let date = rule.date(in: candidate, timeOf: start), date >= start,
                       rule.until.map({ date <= $0 }) ?? true {
                        result.append(date)
                    }
                }
            }
            return result
        }
    }

    /// `FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU` and the older `BYDAY=SU;BYMONTHDAY=8,9,…,14`.
    struct YearlyRule: Sendable {
        var month: Int?
        var ordinal: Int?
        var weekday: Int?
        var monthDays: [Int]
        var until: Date?

        init?(_ text: String) {
            var parts: [String: String] = [:]
            for pair in text.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { parts[kv[0].uppercased()] = kv[1] }
            }
            guard parts["FREQ"]?.uppercased() == "YEARLY" else { return nil }
            month = parts["BYMONTH"].flatMap { Int($0) }
            monthDays = (parts["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
            until = parts["UNTIL"].flatMap(ZoneRules.wallTime)
            if let day = parts["BYDAY"]?.uppercased().split(separator: ",").first.map(String.init) {
                let codes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
                weekday = codes[String(day.suffix(2))]
                ordinal = Int(day.dropLast(2))
                if weekday == nil { return nil }
            }
        }

        func date(in year: Int, timeOf start: Date) -> Date? {
            let calendar = ZoneRules.calendar
            let time = calendar.dateComponents([.hour, .minute, .second], from: start)
            let month = month ?? calendar.component(.month, from: start)
            guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let days = calendar.range(of: .day, in: .month, for: first) else { return nil }
            let day: Int?
            if let weekday {
                let matching = days.filter { day in
                    calendar.component(.weekday, from: first.addingTimeInterval(Double(day - 1) * 86_400)) == weekday
                }
                if let ordinal, ordinal != 0 {
                    let index = ordinal > 0 ? ordinal - 1 : matching.count + ordinal
                    day = matching.indices.contains(index) ? matching[index] : nil
                } else if !monthDays.isEmpty {
                    day = matching.first { monthDays.contains($0) }
                } else {
                    day = matching.first
                }
            } else {
                day = monthDays.first ?? calendar.component(.day, from: start)
            }
            guard let day else { return nil }
            return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                      hour: time.hour, minute: time.minute, second: time.second))
        }
    }

    var observances: [Observance]

    /// The instant a wall-clock time in this zone stands for.
    func date(fromWallTime wall: Date) -> Date {
        let year = Self.calendar.component(.year, from: wall)
        let latest = observances
            .flatMap { observance in observance.starts(through: year).map { (start: $0, offset: observance.offsetTo) } }
            .filter { $0.start <= wall }
            .max { $0.start < $1.start }
        let offset = latest?.offset ?? observances.min { $0.start < $1.start }?.offsetFrom ?? 0
        return wall.addingTimeInterval(-Double(offset))
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `19701025T030000` (or with `Z`) read as wall-clock time.
    static func wallTime(_ text: String) -> Date? {
        let value = text.hasSuffix("Z") ? String(text.dropLast()) : text
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = value.count == 8 ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
        return formatter.date(from: value)
    }

    /// `+0100`, `-0530`, `+013000` in seconds.
    static func offset(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let digits = trimmed.dropFirst()
        guard digits.count == 4 || digits.count == 6, digits.allSatisfy(\.isNumber) else { return nil }
        let numbers = Array(digits).map { Int(String($0))! }
        let hours = numbers[0] * 10 + numbers[1], minutes = numbers[2] * 10 + numbers[3]
        let seconds = digits.count == 6 ? numbers[4] * 10 + numbers[5] : 0
        let total = hours * 3600 + minutes * 60 + seconds
        return sign == "-" ? -total : total
    }
}
