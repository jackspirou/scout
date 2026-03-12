import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO

/// Extracts media metadata from image and video/audio files.
enum MediaMetadataExtractor {

    /// Extracts image metadata from the given URL using CGImageSource.
    /// Runs the extraction off the main thread. Returns nil if the file
    /// cannot be read or is not a valid image.
    static func extractImageMetadata(from url: URL) async -> ImageMetadata? {
        await Task.detached {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else { return nil }

            guard let rawProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }

            let exif = rawProps[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let tiff = rawProps[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            let gps = rawProps[kCGImagePropertyGPSDictionary as String] as? [String: Any]

            // Core properties
            let pixelWidth = rawProps[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            let pixelHeight = rawProps[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            let dpiX = rawProps[kCGImagePropertyDPIWidth as String] as? Double
            let dpiY = rawProps[kCGImagePropertyDPIHeight as String] as? Double
            let bitDepth = rawProps[kCGImagePropertyDepth as String] as? Int
            let hasAlpha = rawProps[kCGImagePropertyHasAlpha as String] as? Bool
            let profileName = rawProps[kCGImagePropertyProfileName as String] as? String
            let colorSpace = rawProps[kCGImagePropertyColorModel as String] as? String

            // TIFF properties (camera make/model often lives here)
            let cameraMake = (tiff?[kCGImagePropertyTIFFMake as String] as? String)?.trimmingCharacters(in: .whitespaces)
            let cameraModel = (tiff?[kCGImagePropertyTIFFModel as String] as? String)?.trimmingCharacters(in: .whitespaces)

            // EXIF properties
            let lensModel = (exif?[kCGImagePropertyExifLensModel as String] as? String)?.trimmingCharacters(in: .whitespaces)
            let focalLength = exif?[kCGImagePropertyExifFocalLength as String] as? Double
            let aperture = exif?[kCGImagePropertyExifFNumber as String] as? Double
            let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first

            // Shutter speed: ExposureTime is a double like 0.00833 (= 1/120)
            let shutterSpeed: String? = {
                guard let exposure = exif?[kCGImagePropertyExifExposureTime as String] as? Double else { return nil }
                if exposure >= 1.0 {
                    return String(format: "%.1fs", exposure)
                } else {
                    let denominator = Int(round(1.0 / exposure))
                    return "1/\(denominator)s"
                }
            }()

            // Flash
            let flash: Bool? = {
                guard let flashValue = exif?[kCGImagePropertyExifFlash as String] as? Int else { return nil }
                return (flashValue & 0x01) != 0 // bit 0 = flash fired
            }()

            // Date taken
            let dateTaken: Date? = {
                guard let dateString = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                return formatter.date(from: dateString)
            }()

            // GPS
            let gpsLatitude: Double? = {
                guard let lat = gps?[kCGImagePropertyGPSLatitude as String] as? Double,
                      let ref = gps?[kCGImagePropertyGPSLatitudeRef as String] as? String else { return nil }
                return ref == "S" ? -lat : lat
            }()
            let gpsLongitude: Double? = {
                guard let lon = gps?[kCGImagePropertyGPSLongitude as String] as? Double,
                      let ref = gps?[kCGImagePropertyGPSLongitudeRef as String] as? String else { return nil }
                return ref == "W" ? -lon : lon
            }()
            let gpsAltitude = gps?[kCGImagePropertyGPSAltitude as String] as? Double

            return ImageMetadata(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                dpiX: dpiX,
                dpiY: dpiY,
                colorSpace: profileName ?? colorSpace,
                bitDepth: bitDepth,
                hasAlpha: hasAlpha,
                profileName: profileName,
                cameraMake: cameraMake,
                cameraModel: cameraModel,
                lensModel: lensModel,
                focalLength: focalLength,
                aperture: aperture,
                shutterSpeed: shutterSpeed,
                iso: iso,
                flash: flash,
                dateTaken: dateTaken,
                gpsLatitude: gpsLatitude,
                gpsLongitude: gpsLongitude,
                gpsAltitude: gpsAltitude
            )
        }.value
    }

    /// Extracts video/audio metadata from the given URL using AVAsset.
    /// Works for both video and audio-only files. Returns nil if the
    /// file cannot be loaded.
    static func extractVideoMetadata(from url: URL) async -> VideoMetadata? {
        let asset = AVURLAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)
            guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }

            // Video track info
            var width: Int?
            var height: Int?
            var frameRate: Double?
            var videoCodec: String?
            var videoBitrate: Double?

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let videoTrack = videoTracks.first {
                let size = try await videoTrack.load(.naturalSize)
                let transform = try await videoTrack.load(.preferredTransform)
                // Apply transform to handle rotated video (e.g., portrait iPhone video)
                let transformedSize = size.applying(transform)
                width = Int(abs(transformedSize.width))
                height = Int(abs(transformedSize.height))

                frameRate = Double(try await videoTrack.load(.nominalFrameRate))
                videoBitrate = Double(try await videoTrack.load(.estimatedDataRate))

                let formatDescriptions = try await videoTrack.load(.formatDescriptions)
                if let desc = formatDescriptions.first {
                    videoCodec = codecName(from: CMFormatDescriptionGetMediaSubType(desc))
                }
            }

            // Audio track info
            var audioCodec: String?
            var audioBitrate: Double?
            var sampleRate: Double?
            var channelCount: Int?

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let audioTrack = audioTracks.first {
                audioBitrate = Double(try await audioTrack.load(.estimatedDataRate))

                let formatDescriptions = try await audioTrack.load(.formatDescriptions)
                if let desc = formatDescriptions.first {
                    audioCodec = codecName(from: CMFormatDescriptionGetMediaSubType(desc))

                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                        sampleRate = asbd.mSampleRate
                        channelCount = Int(asbd.mChannelsPerFrame)
                    }
                }
            }

            // Total bitrate
            var totalBitrate: Double?
            if let vb = videoBitrate, let ab = audioBitrate {
                totalBitrate = vb + ab
            } else {
                totalBitrate = videoBitrate ?? audioBitrate
            }

            return VideoMetadata(
                width: width,
                height: height,
                frameRate: frameRate,
                videoCodec: videoCodec,
                videoBitrate: videoBitrate,
                audioCodec: audioCodec,
                audioBitrate: audioBitrate,
                sampleRate: sampleRate,
                channelCount: channelCount,
                duration: durationSeconds,
                totalBitrate: totalBitrate
            )
        } catch {
            return nil
        }
    }

    // MARK: - Codec Name Mapping

    /// Maps a FourCC codec identifier to a human-readable name.
    private static func codecName(from fourCC: FourCharCode) -> String {
        switch fourCC {
        // Video
        case kCMVideoCodecType_H264:            return "H.264"
        case kCMVideoCodecType_HEVC:            return "HEVC (H.265)"
        case kCMVideoCodecType_VP9:             return "VP9"
        case kCMVideoCodecType_AV1:             return "AV1"
        case kCMVideoCodecType_MPEG4Video:      return "MPEG-4"
        case kCMVideoCodecType_MPEG2Video:      return "MPEG-2"
        case kCMVideoCodecType_AppleProRes4444:  return "ProRes 4444"
        case kCMVideoCodecType_AppleProRes422:   return "ProRes 422"
        case kCMVideoCodecType_AppleProRes422HQ: return "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes422LT: return "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422Proxy: return "ProRes 422 Proxy"
        // Audio
        case kAudioFormatMPEG4AAC:              return "AAC"
        case kAudioFormatMPEGLayer3:            return "MP3"
        case kAudioFormatAppleLossless:         return "Apple Lossless"
        case kAudioFormatLinearPCM:             return "PCM"
        case kAudioFormatFLAC:                  return "FLAC"
        case kAudioFormatOpus:                  return "Opus"
        case kAudioFormatAC3:                   return "AC-3"
        case kAudioFormatEnhancedAC3:           return "E-AC-3"
        default:
            // Fall back to FourCC string representation
            let chars = [
                Character(UnicodeScalar((fourCC >> 24) & 0xFF)!),
                Character(UnicodeScalar((fourCC >> 16) & 0xFF)!),
                Character(UnicodeScalar((fourCC >> 8) & 0xFF)!),
                Character(UnicodeScalar(fourCC & 0xFF)!),
            ]
            return String(chars).trimmingCharacters(in: .whitespaces)
        }
    }
}
