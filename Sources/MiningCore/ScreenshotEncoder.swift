import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotEncoder {
    public static func jpeg(from image: CIImage, contentRect: CGRect?, scaleFactor: CGFloat, context: CIContext) -> Data? {
        var crop = image.extent
        if let rect = contentRect {
            guard scaleFactor.isFinite, scaleFactor > 0,
                  [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
                  rect.width > 0, rect.height > 0 else { return nil }
            // ScreenCaptureKit uses top-origin points; Core Image uses bottom-origin pixels.
            let pixels = rect.applying(CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
            crop = CGRect(x: image.extent.minX + pixels.minX, y: image.extent.maxY - pixels.maxY,
                          width: pixels.width, height: pixels.height).intersection(image.extent)
            guard !crop.isNull, !crop.isEmpty else { return nil }
            crop = CGRect(x: ceil(crop.minX), y: ceil(crop.minY),
                          width: floor(crop.maxX) - ceil(crop.minX), height: floor(crop.maxY) - ceil(crop.minY))
        }
        guard crop.width >= 1, crop.height >= 1,
              let cgImage = context.createCGImage(image, from: crop) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
