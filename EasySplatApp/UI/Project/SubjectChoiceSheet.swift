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
        for pixelIndex in pixels.indices {
            let current = pixels[pixelIndex]
            if allowedLabels.contains(current),
               isBoundary(pixelIndex: pixelIndex, label: current) {
                alpha[pixelIndex] = 255
            }
        }
        return alpha
    }

    func outlineImage(allowedLabels: Set<UInt8>) -> NSImage? {
        outlineImage(alpha: outlineAlpha(allowedLabels: allowedLabels))
    }

    func outlineImage(alpha: [UInt8]) -> NSImage? {
        guard alpha.count == pixels.count else { return nil }
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

    func isBoundary(pixelIndex: Int, label current: UInt8) -> Bool {
        let x = pixelIndex % width
        let y = pixelIndex / width
        return x == 0
            || y == 0
            || x == width - 1
            || y == height - 1
            || label(x: x - 1, y: y) != current
            || label(x: x + 1, y: y) != current
            || label(x: x, y: y - 1) != current
            || label(x: x, y: y + 1) != current
    }
}

struct SubjectChoiceAspectFitTransform {
    let imageRect: CGRect

    init?(containerSize: CGSize, imageSize: CGSize) {
        guard containerSize.width.isFinite,
              containerSize.height.isFinite,
              imageSize.width.isFinite,
              imageSize.height.isFinite,
              containerSize.width > 0,
              containerSize.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return nil
        }

        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let size = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        imageRect = CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func normalizedImagePoint(at point: CGPoint) -> CGPoint? {
        guard imageRect.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - imageRect.minX) / imageRect.width,
            y: (point.y - imageRect.minY) / imageRect.height
        )
    }

    func point(for normalizedPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: imageRect.minX + normalizedPoint.x * imageRect.width,
            y: imageRect.minY + normalizedPoint.y * imageRect.height
        )
    }
}

struct SubjectChoiceCandidateAccessibility: Equatable {
    let ordinal: Int
    let totalCount: Int
    let anchor: SubjectAnchor
    let isSelected: Bool

    var identifier: String {
        "subjectChoice.candidate.\(ordinal)"
    }

    var label: String {
        "Subject candidate \(ordinal) of \(totalCount), \(positionDescription)"
    }

    var value: String {
        isSelected ? "Selected" : "Not selected"
    }

    let hint = "Selects this subject."

    private var positionDescription: String {
        let horizontal: String
        if anchor.normalizedX < 1.0 / 3.0 {
            horizontal = "left"
        } else if anchor.normalizedX >= 2.0 / 3.0 {
            horizontal = "right"
        } else {
            horizontal = "center"
        }
        let vertical: String
        if anchor.normalizedY < 1.0 / 3.0 {
            vertical = "upper"
        } else if anchor.normalizedY >= 2.0 / 3.0 {
            vertical = "lower"
        } else {
            vertical = "center"
        }
        return horizontal == "center" && vertical == "center"
            ? "center"
            : "\(vertical) \(horizontal)"
    }
}

struct SubjectChoiceCandidateOption: Identifiable, Equatable {
    let ordinal: Int
    let candidate: SubjectChoiceRequest.Candidate
    let anchor: SubjectAnchor

    var id: Int { ordinal }
}

struct SubjectChoiceInteractionState: Equatable {
    enum Event {
        case appeared(firstCandidateOrdinal: Int?)
        case activateCandidate(ordinal: Int, anchor: SubjectAnchor)
        case pointerSelection(SubjectAnchor?)
        case submit
        case cancel
    }

    enum Effect: Equatable {
        case isolate(SubjectAnchor)
        case cancel
    }

    private(set) var selectedAnchor: SubjectAnchor?
    private(set) var focusedCandidateOrdinal: Int?

    var canSubmit: Bool {
        selectedAnchor != nil
    }

    @discardableResult
    mutating func reduce(_ event: Event) -> Effect? {
        switch event {
        case let .appeared(firstCandidateOrdinal):
            if selectedAnchor == nil, focusedCandidateOrdinal == nil {
                focusedCandidateOrdinal = firstCandidateOrdinal
            }
            return nil
        case let .activateCandidate(ordinal, anchor):
            selectedAnchor = anchor
            focusedCandidateOrdinal = ordinal
            return nil
        case let .pointerSelection(anchor):
            selectedAnchor = anchor
            return nil
        case .submit:
            return selectedAnchor.map(Effect.isolate)
        case .cancel:
            return .cancel
        }
    }
}

struct SubjectChoicePreview {
    private struct CandidateLabelState {
        var pixelCount = 0
        var sumX = 0.0
        var sumY = 0.0
        var isAdvertised = false
        var targetX = 0.0
        var targetY = 0.0
        var nearestX = -1
        var nearestY = -1
        var nearestDistanceSquared = Double.greatestFiniteMagnitude
    }

    let request: SubjectChoiceRequest
    let mask: SubjectChoiceLabelMask
    let options: [SubjectChoiceCandidateOption]
    let outlineAlpha: [UInt8]

    init?(
        request: SubjectChoiceRequest,
        mask: SubjectChoiceLabelMask,
        imagePixelSize: CGSize,
        onMaskPixelVisit: ((_ pass: Int, _ pixelIndex: Int) -> Void)? = nil
    ) {
        guard imagePixelSize.width == CGFloat(request.pixelWidth),
              imagePixelSize.height == CGFloat(request.pixelHeight),
              request.pixelWidth == mask.width,
              request.pixelHeight == mask.height,
              !request.candidates.isEmpty else {
            return nil
        }

        var labelStates = [CandidateLabelState](repeating: .init(), count: 256)
        for pixelIndex in mask.pixels.indices {
            onMaskPixelVisit?(1, pixelIndex)
            let label = Int(mask.pixels[pixelIndex])
            let x = pixelIndex % mask.width
            let y = pixelIndex / mask.width
            labelStates[label].pixelCount += 1
            labelStates[label].sumX += Double(x) + 0.5
            labelStates[label].sumY += Double(y) + 0.5
        }

        for candidate in request.candidates {
            let label = Int(candidate.instanceLabel)
            guard label != 0,
                  !labelStates[label].isAdvertised,
                  labelStates[label].pixelCount > 0 else {
                return nil
            }
            labelStates[label].isAdvertised = true
            labelStates[label].targetX = labelStates[label].sumX
                / Double(labelStates[label].pixelCount)
            labelStates[label].targetY = labelStates[label].sumY
                / Double(labelStates[label].pixelCount)
        }

        var resolvedOutlineAlpha = [UInt8](repeating: 0, count: mask.pixels.count)
        for pixelIndex in mask.pixels.indices {
            onMaskPixelVisit?(2, pixelIndex)
            let label = Int(mask.pixels[pixelIndex])
            guard labelStates[label].isAdvertised else { continue }
            let x = pixelIndex % mask.width
            let y = pixelIndex / mask.width
            let horizontal = Double(x) + 0.5 - labelStates[label].targetX
            let vertical = Double(y) + 0.5 - labelStates[label].targetY
            let distanceSquared = horizontal * horizontal + vertical * vertical
            if distanceSquared < labelStates[label].nearestDistanceSquared {
                labelStates[label].nearestX = x
                labelStates[label].nearestY = y
                labelStates[label].nearestDistanceSquared = distanceSquared
            }
            if mask.isBoundary(
                pixelIndex: pixelIndex,
                label: mask.pixels[pixelIndex]
            ) {
                resolvedOutlineAlpha[pixelIndex] = 255
            }
        }

        var resolvedOptions = [SubjectChoiceCandidateOption]()
        resolvedOptions.reserveCapacity(request.candidates.count)
        for (index, candidate) in request.candidates.enumerated() {
            let label = Int(candidate.instanceLabel)
            let labelState = labelStates[label]
            guard labelState.nearestX >= 0, labelState.nearestY >= 0 else {
                return nil
            }
            resolvedOptions.append(
                SubjectChoiceCandidateOption(
                    ordinal: index + 1,
                    candidate: candidate,
                    anchor: SubjectAnchor(
                        imageIdentity: request.keyframeImageURL.lastPathComponent,
                        instanceLabel: candidate.instanceLabel,
                        normalizedX: (Double(labelState.nearestX) + 0.5)
                            / Double(mask.width),
                        normalizedY: (Double(labelState.nearestY) + 0.5)
                            / Double(mask.height)
                    )
                )
            )
        }

        self.request = request
        self.mask = mask
        options = resolvedOptions
        outlineAlpha = resolvedOutlineAlpha
    }

    func option(
        at point: CGPoint,
        using transform: SubjectChoiceAspectFitTransform
    ) -> SubjectChoiceCandidateOption? {
        guard let normalized = transform.normalizedImagePoint(at: point) else {
            return nil
        }

        let x = min(mask.width - 1, Int(normalized.x * CGFloat(mask.width)))
        let y = min(mask.height - 1, Int(normalized.y * CGFloat(mask.height)))
        guard let label = mask.label(x: x, y: y) else { return nil }
        return options.first { $0.anchor.instanceLabel == label }
    }
}

enum SubjectChoiceSelectionResolver {
    static func anchor(
        at point: CGPoint,
        in containerSize: CGSize,
        request: SubjectChoiceRequest,
        mask: SubjectChoiceLabelMask
    ) -> SubjectAnchor? {
        guard let preview = SubjectChoicePreview(
            request: request,
            mask: mask,
            imagePixelSize: CGSize(width: request.pixelWidth, height: request.pixelHeight)
        ),
        let transform = SubjectChoiceAspectFitTransform(
            containerSize: containerSize,
            imageSize: CGSize(width: mask.width, height: mask.height)
        ) else {
            return nil
        }
        return preview.option(at: point, using: transform)?.anchor
    }
}

struct SubjectChoiceSheet: View {
    let request: SubjectChoiceRequest
    let onCancel: () -> Void
    let onIsolate: (SubjectAnchor) -> Void
    let onPreviewPresented: @MainActor () -> Void

    @State private var interaction = SubjectChoiceInteractionState()
    @State private var hasReportedPreviewPresentation = false
    @FocusState private var focusedCandidateOrdinal: Int?

    private let keyframeImage: NSImage?
    private let preview: SubjectChoicePreview?
    private let outlineImage: NSImage?

    init(
        request: SubjectChoiceRequest,
        onCancel: @escaping () -> Void,
        onIsolate: @escaping (SubjectAnchor) -> Void,
        onPreviewPresented: @escaping @MainActor () -> Void = {}
    ) {
        self.request = request
        self.onCancel = onCancel
        self.onIsolate = onIsolate
        self.onPreviewPresented = onPreviewPresented
        let loadedImage = NSImage(contentsOf: request.keyframeImageURL)
        let loadedMask = try? SubjectChoiceLabelMask(
            contentsOf: request.combinedInstanceLabelMaskURL,
            expectedWidth: request.pixelWidth,
            expectedHeight: request.pixelHeight
        )
        let loadedPreview = loadedImage.flatMap { image in
            loadedMask.flatMap { mask in
                SubjectChoicePreview(
                    request: request,
                    mask: mask,
                    imagePixelSize: Self.pixelSize(of: image)
                )
            }
        }
        preview = loadedPreview
        keyframeImage = loadedPreview == nil ? nil : loadedImage
        outlineImage = loadedPreview.flatMap {
            $0.mask.outlineImage(alpha: $0.outlineAlpha)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Choose the subject")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Select the object to keep.")
                .foregroundStyle(.secondary)

            if let keyframeImage, let preview {
                GeometryReader { proxy in
                    if let transform = SubjectChoiceAspectFitTransform(
                        containerSize: proxy.size,
                        imageSize: CGSize(width: preview.mask.width, height: preview.mask.height)
                    ) {
                        ZStack {
                            Image(nsImage: keyframeImage)
                                .resizable()
                                .frame(
                                    width: transform.imageRect.width,
                                    height: transform.imageRect.height
                                )
                                .position(
                                    x: transform.imageRect.midX,
                                    y: transform.imageRect.midY
                                )
                                .accessibilityHidden(true)
                            if let outlineImage {
                                Image(nsImage: outlineImage)
                                    .resizable()
                                    .interpolation(.none)
                                    .frame(
                                        width: transform.imageRect.width,
                                        height: transform.imageRect.height
                                    )
                                    .position(
                                        x: transform.imageRect.midX,
                                        y: transform.imageRect.midY
                                    )
                                    .colorMultiply(.accentColor)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    send(.pointerSelection(
                                        preview.option(
                                            at: location,
                                            using: transform
                                        )?.anchor
                                    ))
                                }
                                .accessibilityIdentifier("subjectChoice.gesture")
                                .accessibilityHidden(true)
                            candidateControls(
                                preview: preview,
                                transform: transform
                            )
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .onAppear {
                            send(.appeared(
                                firstCandidateOrdinal: preview.options.first?.ordinal
                            ))
                            if !hasReportedPreviewPresentation {
                                hasReportedPreviewPresentation = true
                                Task { @MainActor in
                                    onPreviewPresented()
                                }
                            }
                        }
                    }
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

            if interaction.selectedAnchor != nil {
                Label("Selected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("subjectChoice.selection")
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    send(.cancel)
                }
                .keyboardShortcut(.cancelAction)
                Button("Isolate") {
                    send(.submit)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!interaction.canSubmit)
                .accessibilityIdentifier("subjectChoice.isolate")
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 560)
    }

    @ViewBuilder
    private func candidateControls(
        preview: SubjectChoicePreview,
        transform: SubjectChoiceAspectFitTransform
    ) -> some View {
        ZStack {
            ForEach(preview.options) { option in
                candidateButton(option, totalCount: preview.options.count)
                    .position(transform.point(for: CGPoint(
                        x: option.anchor.normalizedX,
                        y: option.anchor.normalizedY
                    )))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subject candidates")
        .accessibilityIdentifier("subjectChoice.candidates")
    }

    private func candidateButton(
        _ option: SubjectChoiceCandidateOption,
        totalCount: Int
    ) -> some View {
        let isSelected = interaction.selectedAnchor == option.anchor
        let isFocused = focusedCandidateOrdinal == option.ordinal
        let accessibility = SubjectChoiceCandidateAccessibility(
            ordinal: option.ordinal,
            totalCount: totalCount,
            anchor: option.anchor,
            isSelected: isSelected
        )
        return Button {
            send(.activateCandidate(ordinal: option.ordinal, anchor: option.anchor))
        } label: {
            Group {
                if isSelected {
                    Image(systemName: "checkmark")
                } else {
                    Text(String(option.ordinal))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 28, height: 28)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background {
                Circle().fill(
                    isSelected
                        ? Color.accentColor
                        : Color(nsColor: .controlBackgroundColor)
                )
            }
            .overlay {
                Circle().stroke(
                    isFocused ? Color.primary : Theme.border,
                    lineWidth: isFocused ? 2 : 1
                )
                .padding(isFocused ? -3 : 0)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .focusable(interactions: .edit)
        .focused($focusedCandidateOrdinal, equals: option.ordinal)
        .onKeyPress(.space) {
            send(.activateCandidate(ordinal: option.ordinal, anchor: option.anchor))
            return .handled
        }
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        .accessibilityHint(accessibility.hint)
        .accessibilityIdentifier(accessibility.identifier)
    }

    private func send(_ event: SubjectChoiceInteractionState.Event) {
        var nextInteraction = interaction
        let effect = nextInteraction.reduce(event)
        interaction = nextInteraction
        focusedCandidateOrdinal = nextInteraction.focusedCandidateOrdinal

        switch effect {
        case let .isolate(anchor):
            onIsolate(anchor)
        case .cancel:
            onCancel()
        case nil:
            break
        }
    }

    private static func pixelSize(of image: NSImage) -> CGSize {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            return .zero
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }
}
