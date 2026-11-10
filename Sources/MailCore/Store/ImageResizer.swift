import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes pictures smaller: account pictures, and photos before they're sent.
public enum ImageResizer {
    /// The picture scaled so its longer side is at most `maxPixels`, as PNG or JPEG.
    /// Returns nil when the data isn't a picture.
    public static func resized(_ data: Data, maxPixels: Int, asJPEG: Bool = false, quality: Double = 0.82) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        let type = (asJPEG ? UTType.jpeg : UTType.png).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, asJPEG ? [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The pixel size of a picture, or nil.
    public static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Photos larger than this are made smaller before sending, as most mail apps do.
    public static let sendingLimit = 2048

    /// An outgoing photo, made smaller when it's very large. Other files are left alone.
    public static func forSending(_ data: Data, mimeType: String) -> (data: Data, mimeType: String) {
        guard ["image/jpeg", "image/png", "image/heic", "image/heif"].contains(mimeType.lowercased()),
              let size = pixelSize(data), max(size.width, size.height) > sendingLimit,
              let smaller = resized(data, maxPixels: sendingLimit, asJPEG: true), smaller.count < data.count else { return (data, mimeType) }
        return (smaller, "image/jpeg")
    }
}
