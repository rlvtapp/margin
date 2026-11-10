import MailCore
import SwiftUI

/// A key as printed on the keyboard, shown beside commands so shortcuts are learned by use.
public struct KeyCap: View {
    let keys: [String]

    public init(_ keys: String...) { self.keys = keys }
    public init(keys: [String]) { self.keys = keys }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(TypeScale.key)
                    .foregroundStyle(Ink.tertiary)
                    .frame(minWidth: 16, minHeight: 17)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(Fill.one, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Line.hairline))
            }
        }
    }
}

/// Initials on a solid disc in the person's own colour.
public struct Avatar: View {
    let address: EmailAddress
    var size: CGFloat = 24

    public init(_ address: EmailAddress, size: CGFloat = 24) {
        self.address = address
        self.size = size
    }

    public var body: some View {
        Text(initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.person(address.address), in: Circle())
    }

    /// One letter on small discs, two on larger ones.
    private var initials: String {
        let words = address.displayName.split(separator: " ").prefix(size < 22 ? 1 : 2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// A mailbox's mark: its first letter on a small square in its colour.
public struct AccountMark: View {
    let account: MailAccount
    var size: CGFloat = 16

    public init(_ account: MailAccount, size: CGFloat = 16) {
        self.account = account
        self.size = size
    }

    public var body: some View {
        if let data = account.picture, let image = Self.image(data) {
            image.resizable().scaledToFill().frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        } else {
            letter
        }
    }

    static func image(_ data: Data) -> Image? {
        #if canImport(AppKit)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }

    private var letter: some View {
        Text(account.label.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.6, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.account(account.colorIndex), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// A plain icon button with a hover fill and a tooltip that names its shortcut.
public struct IconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var isHovered = false

    public init(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(isHovered ? Ink.primary : Ink.tertiary)
                .frame(width: 28, height: 28)
                .background(isHovered ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
        .accessibilityLabel(help)
    }
}

/// How tall a full-width button is on a touch screen: comfortably above the 44-point minimum.
let touchButtonHeight: CGFloat = 50

/// The one filled button on a surface. `wide` fills the width at touch size, for the main
/// action at the bottom of an iPhone screen.
public struct InkButtonStyle: ButtonStyle {
    var wide = false
    public init(wide: Bool = false) { self.wide = wide }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(wide ? TypeScale.rowStrong.weight(.semibold) : TypeScale.rowStrong)
            .foregroundStyle(Ink.inverse)
            .padding(.horizontal, 12)
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: wide ? touchButtonHeight : 28)
            .contentShape(Rectangle())
            .background(Ink.primary.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// A quiet secondary button; `wide` as for `InkButtonStyle`.
public struct QuietButtonStyle: ButtonStyle {
    var wide = false
    public init(wide: Bool = false) { self.wide = wide }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.rowStrong)
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: wide ? touchButtonHeight : 28)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Fill.three : Fill.one, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Line.hairline))
    }
}

/// A text field that sits into the page.
public struct FieldStyle: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(TypeScale.row)
            .padding(.horizontal, 10)
            #if os(macOS)
            .frame(height: 30)
            #else
            .frame(minHeight: 44)
            #endif
            .background(Paper.field, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Line.hairline))
    }
}

extension View {
    public func fieldStyle() -> some View { modifier(FieldStyle()) }

    /// A field for a server name or user name: no capitals or corrections on iPhone and iPad.
    public func plainEntry() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }

    /// An email address field: the address keyboard, and no capital letters or corrections
    /// sneaking into the address on iPhone and iPad.
    public func emailAddressEntry() -> some View {
        #if os(iOS)
        self.textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.textContentType(.emailAddress)
        #endif
    }
}

/// Short relative dates for list rows: "10:42", "Tue", "3 Nov", "3 Nov 2025".
public enum RowDate {
    /// For message headers: "14:10", "Yesterday 09:30", "Tue 3 Nov, 09:30".
    public static func long(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday \(time)") }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + ", " + time
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year()) + ", " + time
    }

    public static func string(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 6 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
