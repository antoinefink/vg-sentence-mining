import CoreImage
import ImageIO
import Testing
@testable import MiningCore

@Test func screenshotsExcludeCapturePaddingAtRetinaScale() throws {
    let extent = CGRect(x: 0, y: 0, width: 200, height: 100)
    let black = CIImage(color: .black).cropped(to: extent)
    let game = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
        .cropped(to: CGRect(x: 0, y: 0, width: 180, height: 90))
        .composited(over: black)
    let data = try #require(ScreenshotEncoder.jpeg(from: game, contentRect: CGRect(x: 0, y: 5, width: 90, height: 45), scaleFactor: 2, context: CIContext()))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 180 && image.height == 90)
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    for index in stride(from: 0, to: pixels.count, by: 4) {
        #expect(pixels[index + 1] > 220)
    }
}

@Test func screenshotsKeepDarkGameContentAndHandleMissingOrInvalidMetadata() throws {
    let image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
    #expect(ScreenshotEncoder.jpeg(from: image, contentRect: nil, scaleFactor: 1, context: CIContext()) != nil)
    #expect(ScreenshotEncoder.jpeg(from: image, contentRect: .zero, scaleFactor: 1, context: CIContext()) == nil)
    #expect(ScreenshotEncoder.jpeg(from: image, contentRect: CGRect(x: 0, y: 0, width: 40, height: 20), scaleFactor: .nan, context: CIContext()) == nil)
}
