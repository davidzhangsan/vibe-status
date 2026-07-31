import AppKit
import VibeStatusCore

enum StatusPalette {
    static let needsAttention = NSColor(
        srgbRed: 0.91,
        green: 0.70,
        blue: 0.24,
        alpha: 1
    )
    static let working = NSColor(
        srgbRed: 0.30,
        green: 0.56,
        blue: 0.82,
        alpha: 1
    )
    static let ready = NSColor(
        srgbRed: 0.32,
        green: 0.65,
        blue: 0.43,
        alpha: 1
    )
}

struct MenuBarStatusRenderer {
    private static let blockHeight: CGFloat = 17
    private static let blockCornerRadius: CGFloat = 4
    private static let minimumBlockWidth: CGFloat = 12
    private static let blockHorizontalPadding: CGFloat = 2
    private static let blockSpacing: CGFloat = 1
    private static let horizontalPadding: CGFloat = 0
    private static let imageHeight: CGFloat = 18
    private static let opticalTextOffsetY: CGFloat = -0.5

    static func accessibilityLabel(for counts: StatusCounts) -> String {
        "\(counts.needsAttention) needs attention, \(counts.working) working, \(counts.ready) ready"
    }

    static func image(for counts: StatusCounts) -> NSImage {
        let labels = [
            String(counts.needsAttention),
            String(counts.working),
            String(counts.ready),
        ]
        let colors = [
            StatusPalette.needsAttention,
            StatusPalette.working,
            StatusPalette.ready,
        ]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.black,
        ]

        let textWidths = labels.map {
            ceil(($0 as NSString).size(withAttributes: attributes).width)
        }
        let blockWidths = textWidths.map {
            max(minimumBlockWidth, $0 + blockHorizontalPadding * 2)
        }
        let width = horizontalPadding * 2
            + blockWidths.reduce(0, +)
            + blockSpacing * CGFloat(labels.count - 1)

        let image = NSImage(size: NSSize(width: width, height: imageHeight), flipped: false) { _ in
            var x = horizontalPadding
            let blockY = (imageHeight - blockHeight) / 2

            for index in labels.indices {
                colors[index].setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: x,
                        y: blockY,
                        width: blockWidths[index],
                        height: blockHeight
                    ),
                    xRadius: blockCornerRadius,
                    yRadius: blockCornerRadius
                ).fill()

                x += blockWidths[index] + blockSpacing
            }

            x = horizontalPadding

            for index in labels.indices {
                let label = labels[index] as NSString
                let textSize = label.size(withAttributes: attributes)
                label.draw(
                    at: NSPoint(
                        x: x + (blockWidths[index] - textSize.width) / 2,
                        y: (imageHeight - textSize.height) / 2 + opticalTextOffsetY
                    ),
                    withAttributes: attributes
                )
                x += blockWidths[index] + blockSpacing
            }

            return true
        }

        image.isTemplate = false
        image.accessibilityDescription = accessibilityLabel(for: counts)
        return image
    }
}
