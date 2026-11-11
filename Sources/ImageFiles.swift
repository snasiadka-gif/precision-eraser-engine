import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum PrecisionError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public enum ImageFiles {
    public static let context = CIContext(options: [.cacheIntermediates: false])

    public static func loadCGImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PrecisionError.message("Unable to load image from: \(url.path)")
        }
        return cgImage
    }

    public static func savePNG(_ cgImage: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PrecisionError.message("Unable to create PNG destination at: \(url.path)")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PrecisionError.message("Unable to finalize PNG at: \(url.path)")
        }
    }

    public static func composeWithMask(image: CGImage, mask: Data) throws -> CGImage {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw PrecisionError.message("Unable to allocate composition context")
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        mask.withUnsafeBytes { raw in
            let maskPtr = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let row = y * width
                let pRow = y * bytesPerRow
                for x in 0..<width {
                    let a = maskPtr[row + x]
                    let pOffset = pRow + x * bytesPerPixel
                    let curA = pixelData[pOffset + 3]
                    // Multiply alpha
                    let newA = UInt8((UInt32(curA) * UInt32(a)) / 255)
                    pixelData[pOffset + 3] = newA
                }
            }
        }

        guard let output = context.makeImage() else {
            throw PrecisionError.message("Unable to make final composed image")
        }
        return output
    }
}
