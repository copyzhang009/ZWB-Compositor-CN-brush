import AppKit

extension EditorSession {
    /// The layers a brand-new document starts with, the way Photoshop sets one up:
    /// an opaque white background with a transparent layer above it, so painting
    /// starts right away and the white never lands on the artwork.
    func newDocumentLayers(size: CGSize) -> [ImageLayer] {
        guard let white = Self.solidWhiteImage else {
            return [ImageLayer(name: "图层 1", blankSize: size)]
        }
        // A 1×1 white bitmap placed over the whole canvas: the renderer stretches
        // it to the layer's transform, so no full-size pixels are allocated here.
        let background = ImageLayer(id: UUID(),
                                    asset: ImportedImage(image: white, thumbnail: white, name: "背景"),
                                    name: "背景", isVisible: true,
                                    transform: LayerTransform(origin: .zero, size: size))
        let paint = ImageLayer(name: "图层 1", blankSize: size)
        return [background, paint]
    }

    private static let solidWhiteImage: CGImage? = {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
    }()
}
