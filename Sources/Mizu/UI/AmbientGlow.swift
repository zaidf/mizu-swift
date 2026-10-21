#if canImport(UIKit)
import SwiftUI

/// The report sheet's background: the plain sheet colour with a few faint pools of blue, violet and rose drifting
/// across it, slowly enough that you notice it has moved rather than see it move. Still when Reduce Motion is on.
struct AmbientGlow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One pool of colour: where it rests (as a fraction of the sheet), how far and how slowly it wanders.
    private struct Pool {
        let color: Color
        let rest: CGPoint
        let reach: CGSize
        /// Seconds per loop, different for each pool and each axis so the pattern never visibly repeats.
        let period: (x: Double, y: Double)
        let radius: CGFloat
    }

    /// All three gather around the question (top left) and drift only a little, so the rest of the sheet stays white.
    private let pools = [
        Pool(color: Color(red: 0.36, green: 0.56, blue: 1.00), rest: CGPoint(x: 0.22, y: 0.07),
             reach: CGSize(width: 0.12, height: 0.03), period: (29, 37), radius: 0.62),
        Pool(color: Color(red: 0.62, green: 0.45, blue: 1.00), rest: CGPoint(x: 0.55, y: 0.11),
             reach: CGSize(width: 0.10, height: 0.04), period: (41, 31), radius: 0.52),
        Pool(color: Color(red: 1.00, green: 0.55, blue: 0.62), rest: CGPoint(x: 0.12, y: 0.20),
             reach: CGSize(width: 0.08, height: 0.04), period: (47, 53), radius: 0.45),
    ]

    /// 96×96 pixels of random grey, one per screen pixel.
    private static let grain: UIImage = {
        let side = 96
        var pixels = (0..<side * side).map { _ in UInt8.random(in: 0...255) }
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
        guard let image else { return UIImage() }
        return UIImage(cgImage: image, scale: UIScreen.main.scale, orientation: .up)
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let strength = colorScheme == .dark ? 0.14 : 0.13
                for pool in pools {
                    let center = CGPoint(
                        x: size.width * (pool.rest.x + pool.reach.width * sin(t * 2 * .pi / pool.period.x)),
                        y: size.height * (pool.rest.y + pool.reach.height * cos(t * 2 * .pi / pool.period.y)))
                    let gradient = Gradient(stops: [
                        .init(color: pool.color.opacity(strength), location: 0),
                        .init(color: pool.color.opacity(strength * 0.45), location: 0.45),
                        .init(color: pool.color.opacity(0), location: 1),
                    ])
                    context.fill(Path(CGRect(origin: .zero, size: size)),
                                 with: .radialGradient(gradient, center: center, startRadius: 0,
                                                       endRadius: size.width * pool.radius))
                }
            }
        }
        // Faint gradients this light step in visible rings; a fine grain hides the steps.
        .overlay(Image(uiImage: Self.grain).resizable(resizingMode: .tile).opacity(0.025))
        .background(Color(uiColor: .systemBackground))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
