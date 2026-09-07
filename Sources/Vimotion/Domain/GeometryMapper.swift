import CoreGraphics
import Foundation

/// Cua reports screen-absolute top-left logical points; AppKit is bottom-left.
/// Pure conversion, never any scaling (§3.22).
enum GeometryMapper {
    static func appKitRect(fromCua rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: mainDisplayHeight - (rect.minY + rect.height),
            width: rect.width,
            height: rect.height
        )
    }
}
