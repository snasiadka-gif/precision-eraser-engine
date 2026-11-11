import Foundation
import CoreGraphics
import CoreImage

public struct MattingRefinementOptions {
    public var chokePixels: Int = 1
    public var blurRadius: Float = 1.2
    public var decontaminateRadius: Int = 16
    public var decontaminationStrength: Float = 0.85

    public init(
        chokePixels: Int = 1,
        blurRadius: Float = 1.2,
        decontaminateRadius: Int = 16,
        decontaminationStrength: Float = 0.85
    ) {
        self.chokePixels = chokePixels
        self.blurRadius = blurRadius
        self.decontaminateRadius = decontaminateRadius
        self.decontaminationStrength = decontaminationStrength
    }
}

public enum EdgeDecontamination {
    /// Refines a raw alpha mask and decontaminates the edge colors of an image
    /// to eliminate background bleeding (e.g. sofa upholstery on a dog or background fringe on hair).
    public static func refine(
        image: CGImage,
        mask: Data,
        options: MattingRefinementOptions = MattingRefinementOptions()
    ) throws -> (refinedMask: Data, decontaminatedImage: CGImage) {
        let width = image.width
        let height = image.height
        guard mask.count >= width * height else {
            throw NSError(domain: "EdgeDecontamination", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mask size mismatch"])
        }

        // 1. Convert mask to mutable Float array (0.0 ... 1.0)
        var alpha = [Float](repeating: 0, count: width * height)
        mask.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                alpha[i] = Float(ptr[i]) / 255.0
            }
        }

        // 2. Choke: morphological erosion for edge noise removal
        if options.chokePixels > 0 {
            alpha = erode(alpha: alpha, width: width, height: height, radius: options.chokePixels)
        }

        // 3. Smooth / Feather: box or gaussian blur on transition band
        if options.blurRadius > 0 {
            alpha = smoothEdges(alpha: alpha, width: width, height: height, radius: Int(options.blurRadius.rounded(.up)))
        }

        // 4. Color Decontamination: sample background around edge and unmix RGB
        let cleanedImage = try decontaminateRGB(
            image: image,
            alpha: alpha,
            radius: options.decontaminateRadius,
            strength: options.decontaminationStrength
        )

        // 5. Convert refined alpha back to 8-bit Data
        var outputData = Data(count: width * height)
        outputData.withUnsafeMutableBytes { raw in
            let outPtr = raw.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                let val = Int((alpha[i] * 255.0).rounded())
                outPtr[i] = UInt8(clamping: val)
            }
        }

        return (outputData, cleanedImage)
    }

    private static func erode(alpha: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var eroded = alpha
        let r = radius
        for y in r..<(height - r) {
            let row = y * width
            for x in r..<(width - r) {
                let current = alpha[row + x]
                if current > 0.05 && current < 0.99 {
                    var minVal: Float = 1.0
                    for dy in -r...r {
                        let sampleRow = (y + dy) * width
                        for dx in -r...r {
                            minVal = min(minVal, alpha[sampleRow + (x + dx)])
                        }
                    }
                    eroded[row + x] = minVal
                }
            }
        }
        return eroded
    }

    private static func smoothEdges(alpha: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var smoothed = alpha
        let r = radius
        for y in r..<(height - r) {
            let row = y * width
            for x in r..<(width - r) {
                let current = alpha[row + x]
                // Only smooth the edge boundary (transition zone)
                if current > 0.02 && current < 0.98 {
                    var sum: Float = 0
                    var count: Float = 0
                    for dy in -r...r {
                        let sampleRow = (y + dy) * width
                        for dx in -r...r {
                            sum += alpha[sampleRow + (x + dx)]
                            count += 1
                        }
                    }
                    smoothed[row + x] = sum / count
                }
            }
        }
        return smoothed
    }

    private static func decontaminateRGB(
        image: CGImage,
        alpha: [Float],
        radius: Int,
        strength: Float
    ) throws -> CGImage {
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
            return image
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Decontaminate edge pixels
        let r = max(4, radius)
        for y in 0..<height {
            let rowIdx = y * width
            let pixelRowIdx = y * bytesPerRow
            for x in 0..<width {
                let a = alpha[rowIdx + x]
                // Transition band: pixels containing both subject and background
                if a > 0.05 && a < 0.92 {
                    // Sample local background color
                    var bgR: Float = 0
                    var bgG: Float = 0
                    var bgB: Float = 0
                    var bgWeight: Float = 0

                    let minY = max(0, y - r)
                    let maxY = min(height - 1, y + r)
                    let minX = max(0, x - r)
                    let maxX = min(width - 1, x + r)

                    // Step through neighborhood
                    for sy in stride(from: minY, through: maxY, by: 2) {
                        let sRowIdx = sy * width
                        let sPixelRowIdx = sy * bytesPerRow
                        for sx in stride(from: minX, through: maxX, by: 2) {
                            let sa = alpha[sRowIdx + sx]
                            if sa < 0.05 {
                                let distSq = Float((sx - x) * (sx - x) + (sy - y) * (sy - y)) + 1.0
                                let w = 1.0 / distSq
                                let sOffset = sPixelRowIdx + sx * bytesPerPixel
                                bgR += Float(pixelData[sOffset]) * w
                                bgG += Float(pixelData[sOffset + 1]) * w
                                bgB += Float(pixelData[sOffset + 2]) * w
                                bgWeight += w
                            }
                        }
                    }

                    if bgWeight > 0 {
                        let avgBgR = bgR / bgWeight
                        let avgBgG = bgG / bgWeight
                        let avgBgB = bgB / bgWeight

                        let pOffset = pixelRowIdx + x * bytesPerPixel
                        let curR = Float(pixelData[pOffset])
                        let curG = Float(pixelData[pOffset + 1])
                        let curB = Float(pixelData[pOffset + 2])

                        // Unmix formula: C_fg = (C_obs - (1 - alpha) * C_bg) / alpha
                        let factor = (1.0 - a) * strength
                        let unmixedR = max(0, min(255, (curR - factor * avgBgR) / max(a, 0.1)))
                        let unmixedG = max(0, min(255, (curG - factor * avgBgG) / max(a, 0.1)))
                        let unmixedB = max(0, min(255, (curB - factor * avgBgB) / max(a, 0.1)))

                        pixelData[pOffset] = UInt8(unmixedR)
                        pixelData[pOffset + 1] = UInt8(unmixedG)
                        pixelData[pOffset + 2] = UInt8(unmixedB)
                    }
                }
            }
        }

        guard let outputCG = context.makeImage() else { return image }
        return outputCG
    }
}
