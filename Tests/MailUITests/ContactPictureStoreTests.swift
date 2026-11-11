import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MailCore
@testable import MailUI

@Suite struct ContactPictureStoreTests {
    /// A plain square picture of the given size, as PNG.
    private func picture(side: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func store() -> ContactPictureStore {
        ContactPictureStore(folder: FileManager.default.temporaryDirectory.appending(path: "pictures-\(UUID().uuidString)"))
    }

    @Test func keepsASmallCopyUnderEachAddress() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        #expect(store.save(try picture(side: 900), for: ["Noor@postbox.example", "noor@work.example"]))
        let saved = try #require(store.data(for: "noor@postbox.example"))
        #expect(store.data(for: "NOOR@WORK.example") == saved)
        let source = try #require(CGImageSourceCreateWithData(saved as CFData, nil))
        let size = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(size[kCGImagePropertyPixelWidth] as? Int == 192)
        // The file names don't spell out who you know.
        let names = try FileManager.default.contentsOfDirectory(atPath: store.folder.path)
        #expect(names.allSatisfy { !$0.contains("noor") && !$0.contains("@") })
    }

    @Test func refusesWhatIsNotAPicture() {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        #expect(!store.save(Data("<html>not found</html>".utf8), for: ["sam@k.example"]))
        #expect(store.data(for: "sam@k.example") == nil)
    }

    @Test func remembersForAWeekThatSomeoneHasNone() {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        #expect(!store.isMarkedMissing("sam@k.example"))
        store.markMissing("sam@k.example")
        #expect(store.isMarkedMissing("sam@k.example"))
        #expect(!store.isMarkedMissing("sam@k.example", now: Date().addingTimeInterval(8 * 24 * 3600)))
    }

    @MainActor @Test func yourOwnMailboxPictureIsUsedForYourAddress() async throws {
        let model = MailModel(environment: .preview())
        let own = try #require(model.accounts.first)
        #expect(await model.pictureData(for: own.address.address) == own.picture)
        // Sample people have no address book behind them: initials.
        #expect(await model.pictureData(for: "noor@postbox.example") == nil)
    }
}
