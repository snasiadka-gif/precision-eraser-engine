import Foundation
import CoreGraphics

let fileManager = FileManager.default
let outputDir = URL(fileURLWithPath: "output")
try? fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

let testImages = [
    ("dog_test.jpg", "dog"),
    ("real_hair.jpg", "hair")
]

print("==================================================")
print("🚀 Precision Eraser Cloud Matting Test Runner")
print("==================================================")

for (filename, prefix) in testImages {
    let candidates = [
        "test_images/\(filename)",
        "../test_images/\(filename)",
        filename
    ]
    guard let foundPath = candidates.first(where: { fileManager.fileExists(atPath: $0) }) else {
        print("⚠️ Warning: Image \(filename) not found. Skipping.")
        continue
    }

    let imageURL = URL(fileURLWithPath: foundPath)
    print("\n📸 Processing: \(filename)...")

    do {
        let original = try ImageFiles.loadCGImage(imageURL)
        print(" -> Dimensions: \(original.width) x \(original.height)")

        // 1. Process Quick Mode (Apple Vision + Edge Decontamination)
        print(" [1/2] Running Quick Mode (Apple Vision)...")
        let startQuick = Date()
        let (rawMaskQuick, _, cutoutQuick) = try VisionEngine.shared.process(
            image: original,
            mode: "quick",
            refinement: MattingRefinementOptions(chokePixels: 1, blurRadius: 1.2, decontaminateRadius: 16, decontaminationStrength: 0.85)
        )
        let quickDuration = Date().timeIntervalSince(startQuick)
        print(" -> Finished in \(String(format: "%.2f", quickDuration))s")

        // Save raw (unrefined) cutout for before/after comparison
        let rawCutout = try ImageFiles.composeWithMask(image: original, mask: rawMaskQuick)
        try ImageFiles.savePNG(rawCutout, to: outputDir.appendingPathComponent("\(prefix)_before_raw.png"))
        try ImageFiles.savePNG(cutoutQuick, to: outputDir.appendingPathComponent("\(prefix)_after_refined_quick.png"))
        print(" -> Saved: \(prefix)_before_raw.png & \(prefix)_after_refined_quick.png")

        // 2. Process Studio Mode (MODNet CoreML + Edge Decontamination)
        print(" [2/2] Running Studio Mode (MODNet CoreML)...")
        let startStudio = Date()
        do {
            let (_, _, cutoutStudio) = try VisionEngine.shared.process(
                image: original,
                mode: "studio",
                refinement: MattingRefinementOptions(chokePixels: 0, blurRadius: 0.8, decontaminateRadius: 12, decontaminationStrength: 0.9)
            )
            let studioDuration = Date().timeIntervalSince(startStudio)
            print(" -> Finished in \(String(format: "%.2f", studioDuration))s")
            try ImageFiles.savePNG(cutoutStudio, to: outputDir.appendingPathComponent("\(prefix)_after_refined_studio.png"))
            print(" -> Saved: \(prefix)_after_refined_studio.png")
        } catch {
            print(" -> Studio mode could not run on \(filename): \(error.localizedDescription)")
        }

    } catch {
        print("❌ Error processing \(filename): \(error.localizedDescription)")
    }
}

print("\n==================================================")
print("✅ Test run completed successfully!")
print("==================================================")
