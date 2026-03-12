import Foundation

/// Metadata extracted from an image file via CGImageSource (ImageIO).
struct ImageMetadata {
    // Core image properties
    let pixelWidth: Int
    let pixelHeight: Int
    let dpiX: Double?
    let dpiY: Double?
    let colorSpace: String?       // e.g. "sRGB", "Display P3"
    let bitDepth: Int?
    let hasAlpha: Bool?
    let profileName: String?

    // EXIF (all optional — many images have none)
    let cameraMake: String?
    let cameraModel: String?
    let lensModel: String?
    let focalLength: Double?      // mm
    let aperture: Double?         // f-number
    let shutterSpeed: String?     // formatted string like "1/120"
    let iso: Int?
    let flash: Bool?
    let dateTaken: Date?
    let gpsLatitude: Double?
    let gpsLongitude: Double?
    let gpsAltitude: Double?

    // Computed helpers

    /// Aspect ratio as "W:H" in simplified form (e.g. "16:9", "4:3", "3:2").
    var aspectRatio: String {
        guard pixelWidth > 0, pixelHeight > 0 else { return "--" }
        let g = gcd(pixelWidth, pixelHeight)
        let w = pixelWidth / g
        let h = pixelHeight / g
        // If the simplified ratio has large numbers (e.g. 1920:1080 -> 16:9 is fine,
        // but 4032:3024 -> 168:126 is not useful), fall back to decimal.
        if w > 50 || h > 50 {
            let ratio = Double(pixelWidth) / Double(pixelHeight)
            return String(format: "%.2f:1", ratio)
        }
        return "\(w):\(h)"
    }

    /// Whether this image has any EXIF camera data worth showing.
    var hasExifData: Bool {
        cameraMake != nil || cameraModel != nil || lensModel != nil ||
        focalLength != nil || aperture != nil || shutterSpeed != nil ||
        iso != nil || dateTaken != nil
    }

    /// Whether this image has GPS coordinates.
    var hasGPS: Bool {
        gpsLatitude != nil && gpsLongitude != nil
    }

    /// Formatted GPS string like "37.7749°N, 122.4194°W"
    var formattedGPS: String? {
        guard let lat = gpsLatitude, let lon = gpsLongitude else { return nil }
        let latDir = lat >= 0 ? "N" : "S"
        let lonDir = lon >= 0 ? "E" : "W"
        return String(format: "%.4f°%@, %.4f°%@", abs(lat), latDir, abs(lon), lonDir)
    }

    private func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }
}
