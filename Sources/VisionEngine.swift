import Vision
import CoreImage
import CoreVideo
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

        let selectedInstances = selectForegroundInstances(from: observation)
        print(" -> Selected instances for mask: \(Array(selectedInstances).sorted()) out of all: \(Array(observation.allInstances).sorted())")

        let buffer = try observation.generateScaledMaskForImage(forInstances: selectedInstances, from: handler)
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)

        guard let gray = ImageFiles.context.createCGImage(ciImage, from: extent) else {
            throw PrecisionError.message("Unable to render Apple Vision gray mask.")
        }

        return try grayBytes(gray, width: image.width, height: image.height)
    }

    private func selectForegroundInstances(from observation: VNInstanceMaskObservation) -> IndexSet {
        let all = observation.allInstances
        guard all.count > 1 else { return all }

        let maskBuffer = observation.instanceMask
        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(maskBuffer)
        let height = CVPixelBufferGetHeight(maskBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        let format = CVPixelBufferGetPixelFormatType(maskBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(maskBuffer) else {
            return all
        }

        var instancePixelCounts: [Int: Int] = [:]
        for inst in all {
            instancePixelCounts[inst] = 0
        }

        if format == kCVPixelFormatType_OneComponent8 {
            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = ptr.advanced(by: y * bytesPerRow)
                for x in 0..<width {
                    let val = Int(row[x])
                    if val > 0 && instancePixelCounts[val] != nil {
                        instancePixelCounts[val]! += 1
                    }
                }
            }
        } else {
            for inst in all {
                if let singleMask = try? observation.generateMask(forInstances: IndexSet(integer: inst)) {
                    CVPixelBufferLockBaseAddress(singleMask, .readOnly)
                    let sWidth = CVPixelBufferGetWidth(singleMask)
                    let sHeight = CVPixelBufferGetHeight(singleMask)
                    let sRow = CVPixelBufferGetBytesPerRow(singleMask)
                    if let sBase = CVPixelBufferGetBaseAddress(singleMask) {
                        let sPtr = sBase.assumingMemoryBound(to: UInt8.self)
                        var count = 0
                        for y in 0..<sHeight {
                            let row = sPtr.advanced(by: y * sRow)
                            for x in 0..<sWidth {
                                if row[x] > 128 { count += 1 }
                            }
                        }
                        instancePixelCounts[inst] = count
                    }
                    CVPixelBufferUnlockBaseAddress(singleMask, .readOnly)
                }
            }
        }

        print(" -> Instance pixel counts: \(instancePixelCounts)")
        guard let maxEntry = instancePixelCounts.max(by: { $0.value < $1.value }), maxEntry.value > 0 else {
            return all
        }

        let maxCount = Double(maxEntry.value)
        var selected = IndexSet()
        for (inst, count) in instancePixelCounts {
            let ratio = Double(count) / maxCount
            if ratio >= 0.20 {
                selected.insert(inst)
            } else {
                print(" -> Filtered out minor clutter instance #\(inst) (ratio: \(String(format: "%.1f%%", ratio * 100)))")
            }
        }

        return selected.isEmpty ? all : selected
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
