import Vision
import CoreImage
import Foundation

final class VisionEngine {
    static let shared = VisionEngine()
    private let portraitMatting = MODNetPortraitMatting()

    func process(
        image: CGImage,
        mode: String = "quick",
        refinement: MattingRefinementOptions = MattingRefinementOptions()
    ) throws -> (rawMask: Data, refinedMask: Data, cutout: CGImage) {
        var rawMaskData: Data?

        if mode == "studio" {
            do {
                rawMaskData = try portraitMatting.mask(for: image)
                print(" -> Studio (MODNet) matting succeeded.")
            } catch {
                print(" -> Studio (MODNet) unavailable for this subject: \(error.localizedDescription). Falling back to Apple Vision.")
            }
        }

        if rawMaskData == nil {
            rawMaskData = try appleVisionMask(image: image)
            print(" -> Apple Vision foreground detection succeeded.")
        }

        guard let rawMask = rawMaskData else {
            throw PrecisionError.message("Failed to generate mask.")
        }

        print(" -> Applying Edge Decontamination & Refinement (choke=\(refinement.chokePixels)px, blur=\(refinement.blurRadius), strength=\(refinement.decontaminationStrength))...")
        let (refinedMask, cleanedImage) = try EdgeDecontamination.refine(
            image: image,
            mask: rawMask,
            options: refinement
        )

        let finalCutout = try ImageFiles.composeWithMask(image: cleanedImage, mask: refinedMask)
        return (rawMask, refinedMask, finalCutout)
    }

    private func appleVisionMask(image: CGImage) throws -> Data {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])

        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw PrecisionError.message("No foreground subject found by Apple Vision.")
        }

        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)

        guard let gray = ImageFiles.context.createCGImage(ciImage, from: extent) else {
            throw PrecisionError.message("Unable to render Apple Vision gray mask.")
        }

        return try grayBytes(gray, width: image.width, height: image.height)
    }

    private func grayBytes(_ image: CGImage, width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var buffer = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw PrecisionError.message("Unable to allocate gray mask buffer.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(buffer)
    }
}
