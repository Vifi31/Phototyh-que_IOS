import UIKit
import ImageIO
import UniformTypeIdentifiers
import PhotothequeCore

/// Lecture des images avec ImageIO (JPEG, HEIC, PNG, TIFF, DNG et la plupart des RAW pris en charge par iOS).
enum ImageTools {
    /// Métadonnées EXIF / TIFF / GPS / IPTC du fichier.
    static func metadata(of url: URL) -> PhotoMetadata {
        var m = PhotoMetadata()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return m }
        if let type = CGImageSourceGetType(src) as String?, let ut = UTType(type) {
            m.format = (ut.preferredFilenameExtension ?? ut.identifier).uppercased()
            if m.format == "JPEG" || m.format == "JPE" { m.format = "JPG" }
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return m }
        var w = props[kCGImagePropertyPixelWidth] as? Int
        var h = props[kCGImagePropertyPixelHeight] as? Int
        if let o = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) { swap(&w, &h) }
        m.width = w
        m.height = h

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        let rawDate = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime] as? String)
        if let rawDate {
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            m.takenAt = exifDate(rawDate, offset: offset)
        }
        m.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String ?? "").trimmingCharacters(in: .whitespaces)
        m.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String ?? "").trimmingCharacters(in: .whitespaces)
        m.lens = (exif[kCGImagePropertyExifLensModel] as? String ?? "").trimmingCharacters(in: .whitespaces)

        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            m.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            m.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }

        m.title = (iptc[kCGImagePropertyIPTCObjectName] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        m.caption = (iptc[kCGImagePropertyIPTCCaptionAbstract] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let kws = iptc[kCGImagePropertyIPTCKeywords] as? [String] {
            m.keywords = kws.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else if let kw = iptc[kCGImagePropertyIPTCKeywords] as? String, !kw.isEmpty {
            m.keywords = kw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let r = iptc[kCGImagePropertyIPTCStarRating] as? Int { m.rating = max(0, min(5, r)) }
        return m
    }

    /// « 2024:07:14 18:30:05 » (heure locale de l'appareil, décalage EXIF si présent).
    static func exifDate(_ s: String, offset: String?) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let offset, !offset.isEmpty {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let d = f.date(from: s + offset) { return d }
        }
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: s)
    }

    /// Image réduite (orientation appliquée), sans décoder l'image entière.
    static func thumbnail(of url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Empreinte visuelle dHash : image réduite à 9 × 8 en niveaux de gris.
    static func dhash(of url: URL) -> String? {
        guard let small = thumbnail(of: url, maxPixel: 128) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 72)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(small, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        return ok ? DHash.compute(gray9x8: pixels) : nil
    }
}

/// Vignettes : cache mémoire + cache disque régénérable (Library/Caches/Vignettes).
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL

    private init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Vignettes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.countLimit = 600
    }

    func image(for url: URL, key: String, maxPixel: Int) async -> UIImage? {
        let k = "\(key)-\(maxPixel)" as NSString
        if let img = memory.object(forKey: k) { return img }
        let file = dir.appendingPathComponent("\(key)-\(maxPixel).jpg")
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let d = try? Data(contentsOf: file), let i = UIImage(data: d) { return i }
            guard let cg = ImageTools.thumbnail(of: url, maxPixel: maxPixel) else { return nil }
            let i = UIImage(cgImage: cg)
            if maxPixel <= 600, let jpg = i.jpegData(compressionQuality: 0.82) { try? jpg.write(to: file) }
            return i
        }.value
        if let img { memory.setObject(img, forKey: k) }
        return img
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var diskSize: Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
