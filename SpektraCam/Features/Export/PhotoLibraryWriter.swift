import CoreLocation
import Foundation
import ImageIO
import Photos

nonisolated enum PhotoLibraryWriter {
    enum Failure: LocalizedError {
        case permission
        var errorDescription: String? {
            String(
                localized: "photo_library_writer.allow_adding_photos_in_settings_to_save",
                defaultValue: "Allow adding photos in Settings to save this image.")
        }
    }
    static func save(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.permission }
        let properties =
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
                CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
            } ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let captureDate = PhotoMetadata.captureDate(
            exif: properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            tiff: properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        var location: CLLocation?
        if let lat = gps?[kCGImagePropertyGPSLatitude] as? Double,
            let lon = gps?[kCGImagePropertyGPSLongitude] as? Double,
            lat.isFinite, lon.isFinite, (0...90).contains(lat), (0...180).contains(lon),
            ["N", "S"].contains(gps?[kCGImagePropertyGPSLatitudeRef] as? String ?? ""),
            ["E", "W"].contains(gps?[kCGImagePropertyGPSLongitudeRef] as? String ?? "")
        {
            let altitude = gps?[kCGImagePropertyGPSAltitude] as? Double ?? 0
            location = CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: gps?[kCGImagePropertyGPSLatitudeRef] as? String == "S" ? -lat : lat,
                    longitude: gps?[kCGImagePropertyGPSLongitudeRef] as? String == "W" ? -lon : lon),
                altitude: (gps?[kCGImagePropertyGPSAltitudeRef] as? Int == 1 ? -1 : 1)
                    * (altitude.isFinite ? altitude : 0),
                horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: captureDate ?? Date())
        }
        let capturedLocation = location
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.location = capturedLocation
            if let captureDate { request.creationDate = captureDate }
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}
