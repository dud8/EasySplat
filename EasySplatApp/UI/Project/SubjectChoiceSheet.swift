import AppKit
import EasySplatCore
import ImageIO
import SwiftUI

struct SubjectChoiceLabelMask: Equatable {
    enum LoadError: Error {
        case invalidDimensions
        case invalidPixelData
        case unreadableImage
    }

    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) throws {
        guard width > 0,
              height > 0,
              width <= Int.max / height,
              pixels.count == width * height else {
            throw LoadError.invalidDimensions
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(contentsOf url: URL, expectedWidth: Int, expectedHeight: Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == expectedWidth,
              image.height == expectedHeight,
              image.bitsPerComponent == 8,
              image.bitsPerPixel == 8,
              image.colorSpace?.model == .monochrome,
              let providerData = image.dataProvider?.data else {
            throw LoadError.unreadableImage
        }
        let bytes = Data(providerData as Data)
        guard image.bytesPerRow >= expectedWidth,
              bytes.count >= image.bytesPerRow * expectedHeight else {
            throw LoadError.invalidPixelData
        }
        var pixels = [UInt8]()
        pixels.reserveCapacity(expectedWidth * expectedHeight)
        for row in 0..<expectedHeight {
            let start = row * image.bytesPerRow
            pixels.append(contentsOf: bytes[start..<(start + expectedWidth)])
        }
        try self.init(
            width: expectedWidth,
            height: expectedHeight,
            pixels: pixels
        )
    }

    func label(x: Int, y: Int) -> UInt8? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return pixels[y * width + x]
    }

    func outlineAlpha(allowedLabels: Set<UInt8>) -> [UInt8] {
        var alpha = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<height {
            for x in 0..<width {
                guard let current = label(x: x, y: y),
                      allowedLabels.contains(current) else {
                    continue
                }
                let isBoundary = x == 0
                    || y == 0
                    || x == width - 1
                    || y == height - 1
                    || label(x: x - 1, y: y) != current
                    || label(x: x + 1, y: y) != current
                    || label(x: x, y: y - 1) != current
                    || label(x: x, y: y + 1) != current
                if isBoundary {
                    alpha[y * width + x] = 255
                }
            }
        }
        return alpha
    }

    func outlineImage(allowedLabels: Set<UInt8>) -> NSImage? {
        let alpha = outlineAlpha(allowedLabels: allowedLabels)
        var rgba = [UInt8](repeating: 0, count: pixels.count * 4)
        for index in alpha.indices where alpha[index] != 0 {
            let offset = index * 4
            rgba[offset] = 255
            rgba[offset + 1] = 255
            rgba[offset + 2] = 255
            rgba[offset + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: width, height: height)
        )
    }
}

enum SubjectChoiceSelectionResolver {
    static func anchor(
        at point: CGPoint,
        in containerSize: CGSize,
        request: SubjectChoiceRequest,
        mask: SubjectChoiceLabelMask
    ) -> SubjectAnchor? {
        guard request.pixelWidth == mask.width,
              request.pixelHeight == mask.height,
              let normalized = normalizedImagePoint(
                  at: point,
                  in: containerSize,
                  imageSize: CGSize(
                      width: request.pixelWidth,
                      height: request.pixelHeight
                  )
              ) else {
            return nil
        }

        let x = min(mask.width - 1, Int(normalized.x * CGFloat(mask.width)))
        let y = min(mask.height - 1, Int(normalized.y * CGFloat(mask.height)))
        guard let label = mask.label(x: x, y: y),
              label != 0,
              request.candidates.contains(where: {
                  $0.instanceLabel == label
              }) else {
            return nil
        }
        return SubjectAnchor(
            imageIdentity: request.keyframeImageURL.lastPathComponent,
            instanceLabel: label,
            normalizedX: Double(normalized.x),
            normalizedY: Double(normalized.y)
        )
    }

    private static func normalizedImagePoint(
        at point: CGPoint,
        in containerSize: CGSize,
        imageSize: CGSize
    ) -> CGPoint? {
        guard containerSize.width > 0,
              containerSize.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return nil
        }
        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let fittedSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        let origin = CGPoint(
            x: (containerSize.width - fittedSize.width) / 2,
            y: (containerSize.height - fittedSize.height) / 2
        )
        guard point.x >= origin.x,
              point.y >= origin.y,
              point.x < origin.x + fittedSize.width,
              point.y < origin.y + fittedSize.height else {
            return nil
        }
        return CGPoint(
            x: (point.x - origin.x) / fittedSize.width,
            y: (point.y - origin.y) / fittedSize.height
        )
    }
}

struct SubjectChoiceSheet: View {
    let request: SubjectChoiceRequest
    let onCancel: () -> Void
    let onIsolate: (SubjectAnchor) -> Void

    @State private var selection: SubjectAnchor?

    private let keyframeImage: NSImage?
    private let mask: SubjectChoiceLabelMask?
    private let outlineImage: NSImage?

    init(
        request: SubjectChoiceRequest,
        onCancel: @escaping () -> Void,
        onIsolate: @escaping (SubjectAnchor) -> Void
    ) {
        self.request = request
        self.onCancel = onCancel
        self.onIsolate = onIsolate
        keyframeImage = NSImage(contentsOf: request.keyframeImageURL)
        let loadedMask = try? SubjectChoiceLabelMask(
            contentsOf: request.combinedInstanceLabelMaskURL,
            expectedWidth: request.pixelWidth,
            expectedHeight: request.pixelHeight
        )
        mask = loadedMask
        outlineImage = loadedMask?.outlineImage(
            allowedLabels: Set(request.candidates.map(\.instanceLabel))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Choose the subject")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Click the object to keep.")
                .foregroundStyle(.secondary)

            if let keyframeImage, let mask {
                GeometryReader { proxy in
                    ZStack {
                        Image(nsImage: keyframeImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                        if let outlineImage {
                            Image(nsImage: outlineImage)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(contentMode: .fit)
                                .colorMultiply(.accentColor)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        selection = SubjectChoiceSelectionResolver.anchor(
                            at: location,
                            in: proxy.size,
                            request: request,
                            mask: mask
                        )
                    }
                    .accessibilityLabel("Subject selection image")
                    .accessibilityHint("Click the object to keep")
                }
                .frame(height: 360)
            } else {
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "photo",
                    description: Text("Cancel and try isolating the subject again.")
                )
                .frame(height: 240)
            }

            if selection != nil {
                Label("Selected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("subjectChoice.selection")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Isolate") {
                    if let selection {
                        onIsolate(selection)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
                .accessibilityIdentifier("subjectChoice.isolate")
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 560)
    }
}
