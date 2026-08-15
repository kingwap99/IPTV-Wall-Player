import AppKit
import CoreGraphics

private let assetRoot = URL(
    fileURLWithPath: "tvOS/GlobalNewsWallTV/Assets.xcassets",
    isDirectory: true
)

private let navy = NSColor(calibratedRed: 0.015, green: 0.045, blue: 0.082, alpha: 1)
private let blue = NSColor(calibratedRed: 0.02, green: 0.48, blue: 0.98, alpha: 1)
private let indigo = NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.72, alpha: 1)

private enum ArtworkLayer {
    case background
    case foreground
    case composite
}

private func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
}

private func makeContext(width: Int, height: Int, opaque: Bool) -> CGContext {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    if !opaque {
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    }
    context.setAllowsAntialiasing(true)
    return context
}

private func fillGradient(
    _ context: CGContext,
    rect: CGRect,
    colors: [NSColor],
    start: CGPoint,
    end: CGPoint
) {
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors.map(\.cgColor) as CFArray,
        locations: nil
    )!
    context.saveGState()
    context.addPath(roundedRect(rect, radius: min(rect.width, rect.height) * 0.08))
    context.clip()
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
    context.restoreGState()
}

private func drawGridCell(
    _ context: CGContext,
    rect: CGRect,
    row: Int,
    column: Int,
    canvasSize: CGSize
) {
    let highlighted = (row + column).isMultiple(of: 3)
    let top = highlighted
        ? NSColor(calibratedRed: 0.06, green: 0.32, blue: 0.58, alpha: 0.92)
        : NSColor(calibratedRed: 0.035, green: 0.16, blue: 0.28, alpha: 0.96)
    let bottom = NSColor(calibratedRed: 0.02, green: 0.075, blue: 0.13, alpha: 0.98)
    fillGradient(
        context,
        rect: rect,
        colors: [top, bottom],
        start: CGPoint(x: rect.minX, y: rect.minY),
        end: CGPoint(x: rect.maxX, y: rect.maxY)
    )
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    context.setLineWidth(max(1, min(canvasSize.width, canvasSize.height) * 0.002))
    context.addPath(roundedRect(rect, radius: min(rect.width, rect.height) * 0.08))
    context.strokePath()
}

private func drawBackground(
    _ context: CGContext,
    size: CGSize,
    square: Bool,
    gridDimension: Int
) {
    let bounds = CGRect(origin: .zero, size: size)
    let backgroundGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            navy.cgColor,
            NSColor(calibratedRed: 0.005, green: 0.015, blue: 0.035, alpha: 1).cgColor
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        backgroundGradient,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: size.width, y: size.height),
        options: []
    )

    let outerMargin = min(size.width, size.height) * (square ? 0.105 : 0.095)
    let gap = min(size.width, size.height) * 0.012
    let gridRect = bounds.insetBy(dx: outerMargin, dy: outerMargin)
    let gapCount = CGFloat(gridDimension - 1)
    let cellWidth = (gridRect.width - gap * gapCount) / CGFloat(gridDimension)
    let cellHeight = (gridRect.height - gap * gapCount) / CGFloat(gridDimension)

    for row in 0..<gridDimension {
        for column in 0..<gridDimension {
            let rect = CGRect(
                x: gridRect.minX + CGFloat(column) * (cellWidth + gap),
                y: gridRect.minY + CGFloat(row) * (cellHeight + gap),
                width: cellWidth,
                height: cellHeight
            )
            drawGridCell(
                context,
                rect: rect,
                row: row,
                column: column,
                canvasSize: size
            )
        }
    }
}

private func drawContinuousTopShelfBackground(_ context: CGContext, size: CGSize) {
    context.setFillColor(navy.cgColor)
    context.fill(CGRect(origin: .zero, size: size))

    let rowCount = 4
    let gap = size.height * 0.012
    let cellSide = (size.height - gap * CGFloat(rowCount - 1)) / CGFloat(rowCount)
    let stride = cellSide + gap
    let centerGapX = size.width / 2
    let columnsEachSide = Int(ceil((size.width / 2) / stride)) + 1

    for row in 0..<rowCount {
        let y = CGFloat(row) * stride
        for columnOffset in (-columnsEachSide)..<columnsEachSide {
            let x = centerGapX + gap / 2 + CGFloat(columnOffset) * stride
            let rect = CGRect(x: x, y: y, width: cellSide, height: cellSide)
            guard rect.maxX > 0, rect.minX < size.width else { continue }
            drawGridCell(
                context,
                rect: rect,
                row: row,
                column: columnOffset,
                canvasSize: size
            )
        }
    }
}

private func drawForeground(
    _ context: CGContext,
    size: CGSize,
    includeText: Bool,
    compactWordmark: Bool
) {
    // The TV icon is read from a distance; the mark needs the same visual weight
    // as the square iPad icon while keeping room for tvOS parallax.
    let isWideTVCanvas = size.width / size.height > 1.4
    let panelWidth = compactWordmark
        ? size.height * 0.75
        : size.width * (includeText ? 0.42 : (isWideTVCanvas ? 0.52 : 0.48))
    let panelHeight: CGFloat
    if compactWordmark {
        // Top Shelf uses four full-height rows; make the brand panel exactly two rows tall.
        let gridGap = size.height * 0.012
        let gridCellSide = (size.height - gridGap * 3) / 4
        panelHeight = gridCellSide * 2 + gridGap
    } else {
        panelHeight = size.height * (includeText ? 0.42 : (isWideTVCanvas ? 0.52 : 0.48))
    }
    let panel = CGRect(
        x: (size.width - panelWidth) / 2,
        y: (size.height - panelHeight) / 2,
        width: panelWidth,
        height: panelHeight
    )

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: size.height * 0.015),
        blur: min(size.width, size.height) * 0.055,
        color: blue.withAlphaComponent(0.55).cgColor
    )
    fillGradient(
        context,
        rect: panel,
        colors: [blue, indigo],
        start: CGPoint(x: panel.minX, y: panel.minY),
        end: CGPoint(x: panel.maxX, y: panel.maxY)
    )
    context.restoreGState()

    let markScale = compactWordmark ? 0.28 : (includeText ? 0.31 : (isWideTVCanvas ? 0.46 : 0.43))
    let markSize = panel.height * markScale
    let markY = panel.midY - markSize / 2 - (includeText ? panel.height * 0.08 : 0)
    let markRect = CGRect(
        x: panel.midX - markSize / 2,
        y: markY,
        width: markSize,
        height: markSize
    )
    let markGap = markSize * 0.105
    let markCell = (markSize - markGap) / 2
    for row in 0..<2 {
        for column in 0..<2 {
            let rect = CGRect(
                x: markRect.minX + CGFloat(column) * (markCell + markGap),
                y: markRect.minY + CGFloat(row) * (markCell + markGap),
                width: markCell,
                height: markCell
            )
            context.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
            context.addPath(roundedRect(rect, radius: markCell * 0.16))
            context.fillPath()
        }
    }

    guard includeText else { return }

    let fontSize = panel.height * 0.105
    let titleFont = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let playerFont = NSFont.systemFont(ofSize: fontSize * 0.78, weight: .semibold)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let text = NSMutableAttributedString(
        string: "IPTV WALL",
        attributes: [
            .font: titleFont,
            .foregroundColor: NSColor.white,
            .kern: fontSize * 0.12,
            .paragraphStyle: paragraph
        ]
    )
    text.append(
        NSAttributedString(
            string: " Player",
            attributes: [
                .font: playerFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.82),
                .kern: fontSize * 0.02,
                .paragraphStyle: paragraph
            ]
        )
    )
    let textRect = CGRect(
        x: panel.minX,
        y: panel.maxY - panel.height * 0.23,
        width: panel.width,
        height: fontSize * 1.5
    )
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    text.draw(in: textRect)
    NSGraphicsContext.restoreGraphicsState()
}

private func render(
    width: Int,
    height: Int,
    layer: ArtworkLayer,
    includeText: Bool = false,
    gridDimension: Int = 4,
    compactWordmark: Bool = false,
    continuousTopShelfGrid: Bool = false
) -> Data {
    let context = makeContext(width: width, height: height, opaque: layer != .foreground)
    let size = CGSize(width: width, height: height)
    if layer != .foreground {
        if continuousTopShelfGrid {
            drawContinuousTopShelfBackground(context, size: size)
        } else {
            drawBackground(
                context,
                size: size,
                square: width == height,
                gridDimension: gridDimension
            )
        }
    }
    if layer != .background {
        drawForeground(
            context,
            size: size,
            includeText: includeText,
            compactWordmark: compactWordmark
        )
    }
    let image = context.makeImage()!
    let bitmap = NSBitmapImageRep(cgImage: image)
    return bitmap.representation(using: .png, properties: [:])!
}

private func write(_ data: Data, _ relativePath: String) throws {
    let url = assetRoot.appendingPathComponent(relativePath)
    try data.write(to: url, options: .atomic)
    print("Updated \(relativePath)")
}

private func generateTVIcon(width: Int, height: Int, sizeName: String, scaleSuffix: String = "") throws {
    let base = "AppIcon.brandassets/App Icon - \(sizeName).imagestack"
    try write(
        render(width: width, height: height, layer: .background),
        "\(base)/Background.imagestacklayer/Content.imageset/icon-\(sizeName.lowercased())\(scaleSuffix).png"
    )
    try write(
        render(width: width, height: height, layer: .foreground, includeText: true),
        "\(base)/Foreground.imagestacklayer/Content.imageset/foreground-\(sizeName.lowercased())\(scaleSuffix).png"
    )
}

private func generateTVIconOnly(width: Int, height: Int, sizeName: String, scaleSuffix: String = "") throws {
    let base = "AppIcon.brandassets/App Icon - \(sizeName).imagestack"
    try write(
        render(width: width, height: height, layer: .foreground, includeText: false),
        "\(base)/Foreground.imagestacklayer/Content.imageset/foreground-\(sizeName.lowercased())\(scaleSuffix).png"
    )
}

private func writePreview(_ data: Data, _ filename: String) throws {
    let directory = URL(fileURLWithPath: "/tmp/iptvwall-tvos-icon-preview", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
    print("Updated \(directory.appendingPathComponent(filename).path)")
}

private func generateTVIconPreview() throws {
    try writePreview(
        render(width: 1280, height: 768, layer: .composite, includeText: false),
        "icon-large.png"
    )
    try writePreview(
        render(width: 400, height: 240, layer: .composite, includeText: false),
        "icon-small.png"
    )
}

private func generateTVWordmark(width: Int, height: Int, sizeName: String, scaleSuffix: String = "") throws {
    let base = "AppIcon.brandassets/App Icon - \(sizeName).imagestack"
    try write(
        render(width: width, height: height, layer: .foreground, includeText: true),
        "\(base)/Foreground.imagestacklayer/Content.imageset/foreground-\(sizeName.lowercased())\(scaleSuffix).png"
    )
}

private func generateTopShelfArtwork() throws {
    try write(
        render(
            width: 1920,
            height: 720,
            layer: .composite,
            includeText: true,
            compactWordmark: true,
            continuousTopShelfGrid: true
        ),
        "TVTopShelfPrimaryImage.imageset/TVTopShelfPrimaryImage.png"
    )
    try write(
        render(
            width: 3840,
            height: 1440,
            layer: .composite,
            includeText: true,
            compactWordmark: true,
            continuousTopShelfGrid: true
        ),
        "TVTopShelfPrimaryImage.imageset/TVTopShelfPrimaryImage@2x.png"
    )
    try write(
        render(
            width: 2320,
            height: 720,
            layer: .composite,
            includeText: true,
            compactWordmark: true,
            continuousTopShelfGrid: true
        ),
        "TVTopShelfPrimaryImageWide.imageset/TVTopShelfPrimaryImageWide.png"
    )
    try write(
        render(
            width: 4640,
            height: 1440,
            layer: .composite,
            includeText: true,
            compactWordmark: true,
            continuousTopShelfGrid: true
        ),
        "TVTopShelfPrimaryImageWide.imageset/TVTopShelfPrimaryImageWide@2x.png"
    )
}

if CommandLine.arguments.contains("--top-shelf-only") {
    try generateTopShelfArtwork()
} else if CommandLine.arguments.contains("--tvos-icon-only") {
    try generateTVIconOnly(width: 1280, height: 768, sizeName: "Large")
    try generateTVIconOnly(width: 400, height: 240, sizeName: "Small")
    try generateTVIconOnly(width: 800, height: 480, sizeName: "Small", scaleSuffix: "@2x")
} else if CommandLine.arguments.contains("--tvos-icon-preview") {
    try generateTVIconPreview()
} else if CommandLine.arguments.contains("--wordmark-only") {
    try generateTVWordmark(width: 1280, height: 768, sizeName: "Large")
    try generateTVWordmark(width: 400, height: 240, sizeName: "Small")
    try generateTVWordmark(width: 800, height: 480, sizeName: "Small", scaleSuffix: "@2x")
    try generateTopShelfArtwork()
} else {
    try generateTVIcon(width: 1280, height: 768, sizeName: "Large")
    try generateTVIcon(width: 400, height: 240, sizeName: "Small")
    try generateTVIcon(width: 800, height: 480, sizeName: "Small", scaleSuffix: "@2x")

    let macSizes = [16, 32, 128, 256, 512]
    for size in macSizes {
        try write(
            render(width: size, height: size, layer: .composite),
            "MacAppIcon.appiconset/icon_\(size)x\(size).png"
        )
        try write(
            render(width: size * 2, height: size * 2, layer: .composite),
            "MacAppIcon.appiconset/icon_\(size)x\(size)@2x.png"
        )
    }

    try write(
        render(width: 1024, height: 1024, layer: .composite),
        "iPadAppIcon.appiconset/IPTVWallPad-1024.png"
    )
    try generateTopShelfArtwork()
}
