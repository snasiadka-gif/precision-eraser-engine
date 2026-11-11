import CoreML
import Vision
import CoreGraphics
import Foundation

final class MODNetPortraitMatting {
    private var cachedModel: VNCoreMLModel?
    private var temporaryCompiledURL: URL?

    deinit {
        if let url = temporaryCompiledURL { try? FileManager.default.removeItem(at: url) }
    }

    private func model() throws -> VNCoreMLModel {
        if let cachedModel { return cachedModel }
        
        let fileManager = FileManager.default
        let compiledCandidates = [
            "MODNet.mlmodelc",
            "Sources/MODNet.mlmodelc"
        ]
        let sourceCandidates = [
            "MODNet.mlmodel",
            "Sources/MODNet.mlmodel"
        ]

        var url: URL?
        for candidate in compiledCandidates {
            if fileManager.fileExists(atPath: candidate) {
                url = URL(fileURLWithPath: candidate)
                break
            }
        }

        if url == nil {
            for candidate in sourceCandidates {
                if fileManager.fileExists(atPath: candidate) {
                    let sourceURL = URL(fileURLWithPath: candidate)
                    let compiled = try MLModel.compileModel(at: sourceURL)
                    temporaryCompiledURL = compiled
                    url = compiled
                    break
                }
            }
        }

        guard let finalURL = url else {
            throw PrecisionError.message("MODNet model file not found in current directory or Sources/")
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let coreModel = try MLModel(contentsOf: finalURL, configuration: configuration)
        let visionModel = try VNCoreMLModel(for: coreModel)
        cachedModel = visionModel
        return visionModel
    }

    func mask(for original: CGImage) throws -> Data {
        let request = VNCoreMLRequest(model: try model())
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: original, orientation: .up)
        try handler.perform([request])
        
        guard let observations = request.results as? [VNCoreMLFeatureValueObservation],
              let matte = observations.first(where: { $0.featureName == "1252" })?.featureValue.multiArrayValue else {
            throw PrecisionError.message("Studio did not return a portrait alpha matte.")
        }
        return try alphaBytes(matte, width: original.width, height: original.height)
    }

    private func alphaBytes(_ matte: MLMultiArray, width: Int, height: Int) throws -> Data {
        let shape = matte.shape.map { $0.intValue }
        let strides = matte.strides.map { $0.intValue }
        guard matte.dataType == .float32, shape.count >= 2, shape.count == strides.count,
              shape.dropLast(2).allSatisfy({ $0 == 1 }),
              shape[shape.count - 2] == 512, shape[shape.count - 1] == 512,
              strides.allSatisfy({ $0 > 0 }), width > 0, height > 0 else {
            throw PrecisionError.message("Studio returned an unsupported alpha matte.")
        }
        let sourceWidth = shape[shape.count - 1]
        let sourceHeight = shape[shape.count - 2]
        let rowStride = strides[strides.count - 2]
        let columnStride = strides[strides.count - 1]
        let values = matte.dataPointer.assumingMemoryBound(to: Float.self)
        var alpha = [Float](repeating: 0, count: sourceWidth * sourceHeight)
        var maximum: Float = 0
        for y in 0..<sourceHeight {
            for x in 0..<sourceWidth {
                let value = values[y * rowStride + x * columnStride]
                let bounded = min(1, max(0, value))
                alpha[y * sourceWidth + x] = bounded
                maximum = max(maximum, bounded)
            }
        }
        guard maximum > 0.01 else {
            throw PrecisionError.message("Studio found no portrait; use general foreground detection.")
        }
        return try resizeAlpha(alpha, sourceWidth: sourceWidth, sourceHeight: sourceHeight, width: width, height: height)
    }

    private func resizeAlpha(_ alpha: [Float], sourceWidth: Int, sourceHeight: Int, width: Int, height: Int) throws -> Data {
        let scaleX = Float(sourceWidth) / Float(width)
        let scaleY = Float(sourceHeight) / Float(height)
        var output = Data(count: width * height)
        output.withUnsafeMutableBytes { raw in
            let outPtr = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let sy = min(Float(sourceHeight - 1), Float(y) * scaleY)
                let y0 = Int(sy)
                let y1 = min(sourceHeight - 1, y0 + 1)
                let fy = sy - Float(y0)
                let row0 = y0 * sourceWidth
                let row1 = y1 * sourceWidth
                let outRow = y * width

                for x in 0..<width {
                    let sx = min(Float(sourceWidth - 1), Float(x) * scaleX)
                    let x0 = Int(sx)
                    let x1 = min(sourceWidth - 1, x0 + 1)
                    let fx = sx - Float(x0)

                    let v00 = alpha[row0 + x0]
                    let v10 = alpha[row0 + x1]
                    let v01 = alpha[row1 + x0]
                    let v11 = alpha[row1 + x1]

                    let top = v00 * (1 - fx) + v10 * fx
                    let bottom = v01 * (1 - fx) + v11 * fx
                    let val = top * (1 - fy) + bottom * fy
                    outPtr[outRow + x] = UInt8((val * 255.0).rounded())
                }
            }
        }
        return output
    }
}
