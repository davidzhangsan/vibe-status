import AppKit
import VibeStatusCore

enum StatusPalette {
    static let needsAttention = NSColor.systemYellow
    static let working = NSColor.systemBlue
    static let ready = NSColor.systemGreen
}

struct MenuBarStatusRenderer {
    private static let dotDiameter: CGFloat = 7
    private static let horizontalPadding: CGFloat = 5
    private static let groupSpacing: CGFloat = 6
    private static let imageHeight: CGFloat = 18

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
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]

        let textWidths = labels.map {
            ceil(($0 as NSString).size(withAttributes: attributes).width)
        }
        let groupsWidth = textWidths.reduce(0, +) + CGFloat(labels.count) * (dotDiameter + 3)
        let width = horizontalPadding * 2 + groupsWidth + groupSpacing * CGFloat(labels.count - 1)

        let image = NSImage(size: NSSize(width: width, height: imageHeight), flipped: false) { _ in
            var x = horizontalPadding

            for index in labels.indices {
                let dotY = floor((imageHeight - dotDiameter) / 2)
                colors[index].setFill()
                NSBezierPath(
                    ovalIn: NSRect(
                        x: x,
                        y: dotY,
                        width: dotDiameter,
                        height: dotDiameter
                    )
                ).fill()

                x += dotDiameter + 3
                let label = labels[index] as NSString
                let textSize = label.size(withAttributes: attributes)
                label.draw(
                    at: NSPoint(
                        x: x,
                        y: floor((imageHeight - textSize.height) / 2)
                    ),
                    withAttributes: attributes
                )
                x += textWidths[index]

                if index < labels.index(before: labels.endIndex) {
                    x += groupSpacing
                }
            }
            return true
        }

        image.isTemplate = false
        image.accessibilityDescription = accessibilityLabel(for: counts)
        return image
    }
}
