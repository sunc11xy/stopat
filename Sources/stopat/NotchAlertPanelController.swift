import AppKit
/// Geometry for panels that expand from a MacBook camera cutout.
@MainActor
enum NotchPresentationGeometry {
    static var screen: NSScreen? {
        NSScreen.screens.first {
            $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func expandedFrame(size: NSSize) -> NSRect? {
        guard let screen else { return nil }
        // visibleFrame ensures the final window is below the system's notch/menu-bar clipping
        // region, while retaining the exact horizontal center of the physical camera cutout.
        return NSRect(
            x: cameraCenterX(on: screen) - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - 6,
            width: size.width,
            height: size.height
        )
    }

    static func collapsedFrame() -> NSRect? {
        guard let screen else { return nil }
        let notchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(80, right.minX - left.maxX)
        } else {
            notchWidth = 160
        }
        let height = max(28, screen.safeAreaInsets.top)
        return NSRect(
            x: cameraCenterX(on: screen) - notchWidth / 2,
            y: screen.frame.maxY - height,
            width: notchWidth,
            height: height
        )
    }

    private static func cameraCenterX(on screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return (left.maxX + right.minX) / 2
        }
        return screen.frame.midX
    }
}
