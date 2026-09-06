import Foundation

/// Performance knobs for capture.
///
/// The overlay shares a GPU with the game it is processing, so these are the
/// difference between a playable frame rate and an unusable one. They are read
/// when a capture session starts; changing them restarts capture.
final class CaptureSettings {
    static let shared = CaptureSettings()

    /// Multiplier on the target window's point size.
    ///
    /// 2.0 is native on a Retina display and the most expensive. 1.0 captures at
    /// point resolution — noticeably softer on Retina, but a quarter of the
    /// pixels, and the usual difference between playable and not.
    var scale: CGFloat = 1.0

    /// Upper bound on captured frames per second.
    var frameCap: Int = 60

    static let scaleOptions: [CGFloat] = [0.5, 1.0, 2.0]
    static let frameCapOptions: [Int] = [30, 60]

    static func label(forScale scale: CGFloat) -> String {
        switch scale {
        case 0.5: return "Half (fastest)"
        case 2.0: return "Native Retina (sharpest)"
        default: return "Points (balanced)"
        }
    }
}
