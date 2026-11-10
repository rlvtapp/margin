import ImageIO
import MailCore
import NativeEditor
import SwiftUI

/// The block composer (Settings → Experimental): Relevate's native editor, with `/` for blocks
/// and handles to drag them, offering only blocks that make sense in email. What's written goes
/// into the draft as standard email (`MailDocument`): HTML plus a plain-text part. The signature
/// stays outside the editor and is added after it.
struct BlockComposer: View {
    @Binding var state: ComposeState
    @StateObject private var holder: BlockComposerDocument

    /// Blocks an email can carry. Pages and databases stay out of the menu.
    static let emailBlocks: Set<String> = ["paragraph", "h1", "h2", "h3", "bullet", "numbered", "todo", "quote", "callout",
                                           "code_block", "divider", "table", "image"]

    init(state: Binding<ComposeState>) {
        _state = state
        _holder = StateObject(wrappedValue: BlockComposerDocument(text: Self.body(of: state.wrappedValue)))
    }

    var body: some View {
        NativeBlockEditor(
            document: holder.document,
            imageURL: { holder.url(for: $0) },
            saveImage: { try holder.save($0) },
            fontDesign: "default",
            allowedBlocks: Self.emailBlocks
        )
        #if os(macOS)
        .environmentObject(holder.session)
        #endif
        .onReceive(holder.document.$revision) { _ in write() }
        .onChange(of: state.draft.text) { _, text in
            // A template or the assistant changed the text: show it in the editor.
            guard text != holder.lastWritten else { return }
            holder.load(Self.body(of: state))
        }
    }

    /// The draft's text above the signature.
    static func body(of state: ComposeState) -> String {
        let text = state.draft.text
        if let signature = state.signature, !signature.isEmpty, text.hasSuffix(signature) {
            return String(text.dropLast(signature.count)).trimmingCharacters(in: .newlines)
        }
        return text
    }

    private func write() {
        let blocks = (try? holder.document.blocks()) ?? []
        var draft = MailModel.applying(MailDocument(blocks: blocks, imageWidth: { holder.images[$0]?.width }),
                                       plain: holder.document.plainText, to: state.draft, signature: state.signature ?? "")
        // Pictures in the text go along inside the message, in the order they appear.
        let shown = blocks.compactMap { $0.kind.type == "image" ? $0.kind.asset : nil }
        draft.attachments = draft.attachments.filter { $0.contentID == nil }
            + shown.enumerated().compactMap { index, id in
                holder.images[id].map { OutgoingAttachment(filename: "picture-\(index + 1).\($0.ext)", mimeType: $0.mimeType, data: $0.data, contentID: id) }
            }
        holder.lastWritten = draft.text
        if draft != state.draft { state.draft = draft }
    }
}

/// Keeps the editor's document for one message.
@MainActor
final class BlockComposerDocument: ObservableObject {
    let document: EditorDocument
    #if os(macOS)
    /// The editor's Mac text fields expect a session above them; the composer is its own host.
    lazy var session = MacEditorSession(document: document)
    #endif
    /// The text this composer last put in the draft, to tell its own changes from others'.
    var lastWritten = ""
    /// Pictures added to the message, by the id the editor knows them by (also their Content-ID).
    var images: [String: Picture] = [:]
    private let folder = FileManager.default.temporaryDirectory.appending(path: "Margin Pictures/\(UUID().uuidString)", directoryHint: .isDirectory)

    struct Picture {
        var data: Data
        var mimeType: String
        var ext: String
        var width: Int?
    }

    /// Keeps a pasted, dropped or chosen picture, made a sensible size for mail.
    func save(_ data: Data) throws -> String {
        let type = Self.mimeType(of: data)
        var sized = ImageResizer.forSending(data, mimeType: type)
        // HEIC photos go out as JPEG: many mail apps can't show HEIC.
        if sized.mimeType == "image/heic", let jpeg = ImageResizer.resized(sized.data, maxPixels: 4096, asJPEG: true) {
            sized = (jpeg, "image/jpeg")
        }
        guard sized.data.count <= 15 * 1024 * 1024 else {
            throw EditorFailure(message: String(localized: "That picture is too large to send."))
        }
        let id = "\(UUID().uuidString.lowercased())@margin"
        let ext = sized.mimeType == "image/png" ? "png" : sized.mimeType == "image/gif" ? "gif" : "jpg"
        let width = CGImageSourceCreateWithData(sized.data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            .flatMap { $0[kCGImagePropertyPixelWidth] as? Int }
        images[id] = Picture(data: sized.data, mimeType: sized.mimeType, ext: ext, width: width.map { min($0, 600) })
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try sized.data.write(to: folder.appending(path: Self.fileName(id, ext)))
        return id
    }

    func url(for id: String) -> URL? {
        guard let picture = images[id] else { return nil }
        return folder.appending(path: Self.fileName(id, picture.ext))
    }

    static func fileName(_ id: String, _ ext: String) -> String { id.replacingOccurrences(of: "@", with: "-") + "." + ext }

    static func mimeType(of data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if head.count >= 12, String(decoding: head[4..<12], as: UTF8.self).hasPrefix("ftyphei") { return "image/heic" }
        return "image/jpeg"
    }

    init(text: String) {
        document = Self.sample() ?? (try? EditorDocument(text: text)) ?? (try! EditorDocument())
    }

    /// For screenshots of the editor's alignment (`-snapshot-blocks-sample`): a heading, a
    /// numbered list, a to-do, a bullet and an empty line.
    private static func sample() -> EditorDocument? {
        guard ProcessInfo.processInfo.arguments.contains("-snapshot-blocks-sample"),
              let sample = try? EditorDocument(text: "Plans for May\nBook the flights\nFind a flat\nTell Noor\nPack the bags\nTile museum\n")
        else { return nil }
        let kinds: [EditorBlockKind] = [.init("heading", level: 1), .init("numbered"), .init("numbered"), .init("numbered"),
                                        .init("todo", checked: false), .init("bullet"), .init("paragraph")]
        for (index, kind) in kinds.enumerated() { try? sample.setBlockKind(kind, at: index) }
        return sample
    }

    func load(_ text: String) {
        try? document.replace(NSRange(location: 0, length: document.lengthUTF16), with: text)
        document.clearHistory()
    }
}

extension MailDocument {
    /// The editor's blocks as an email document: email-safe blocks kept, nested lists flattened,
    /// empty lines dropped (spacing comes from the HTML), callouts sent as quotes.
    init(blocks: [EditorBlock], imageWidth: (String) -> Int? = { _ in nil }) {
        var result: [Block] = []
        func runs(_ block: EditorBlock) -> [Run] { MailDocument.runs(text: block.text, marks: block.marks) }
        for block in blocks {
            let type = block.kind.type
            if type == "paragraph", block.text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            switch type {
            case "heading":
                result.append(.heading(level: min(max(block.kind.level ?? 1, 1), 3), runs(block)))
            case "bullet":
                if case .bullets(let items)? = result.last { result[result.count - 1] = .bullets(items + [runs(block)]) }
                else { result.append(.bullets([runs(block)])) }
            case "numbered":
                if case .numbered(let items)? = result.last { result[result.count - 1] = .numbered(items + [runs(block)]) }
                else { result.append(.numbered([runs(block)])) }
            case "todo":
                let task = Task(done: block.kind.checked ?? false, text: runs(block))
                if case .tasks(let items)? = result.last { result[result.count - 1] = .tasks(items + [task]) }
                else { result.append(.tasks([task])) }
            case "quote", "callout":
                result.append(.quote(runs(block)))
            case "code_block":
                result.append(.code(block.text))
            case "divider":
                result.append(.divider)
            case "table":
                if let table = block.kind.table { result.append(.table(table.cells)) }
            case "image":
                if let asset = block.kind.asset {
                    result.append(.image(contentID: asset, alt: block.kind.alt ?? block.kind.caption ?? "", width: imageWidth(asset)))
                }
            case "paragraph":
                result.append(.paragraph(runs(block)))
            default:
                // Pages, databases and anything newer: their text, when they have some.
                if !block.text.isEmpty { result.append(.paragraph(runs(block))) }
            }
        }
        self.init(blocks: result)
    }

    /// A block's text cut into runs where its marks (bold, italic, code, strike, underline,
    /// links) start and end. Mark ranges count UTF-16 units.
    static func runs(text: String, marks: [EditorMark]) -> [Run] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }
        var cuts = Set([0, units.count])
        for mark in marks {
            cuts.insert(max(0, min(units.count, mark.range.start)))
            cuts.insert(max(0, min(units.count, mark.range.end)))
        }
        let points = cuts.sorted()
        return zip(points, points.dropFirst()).compactMap { start, end in
            guard end > start, let piece = String(utf16CodeUnits: Array(units[start..<end]), count: end - start) as String? else { return nil }
            let active = marks.filter { $0.range.start <= start && $0.range.end >= end }
            func has(_ kind: String) -> Bool { active.contains { $0.kind == kind } }
            let link = active.first { $0.kind == "link" }?.value.flatMap(URL.init(string:))
            return Run(piece, bold: has("bold"), italic: has("italic"), code: has("code"), link: link,
                       strike: has("strike"), underline: has("underline"))
        }
    }
}
