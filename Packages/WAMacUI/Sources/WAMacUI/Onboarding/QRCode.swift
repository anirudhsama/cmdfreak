import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum QRCode {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Crisp QR image at `pixelSize` (nearest-neighbour scaling), or nil for an empty string.
    static func image(for string: String, pixelSize: CGFloat) -> CGImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = pixelSize / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
