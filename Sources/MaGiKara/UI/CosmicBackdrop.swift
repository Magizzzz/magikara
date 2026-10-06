import SwiftUI

/// 稀疏星点与星轨只落在窗口底板上；不进入工作区卡片，也不拦截交互。
struct CosmicBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RadialGradient(
                    colors: [Theme.blueViolet.opacity(0.10), .clear],
                    center: .topLeading,
                    startRadius: 2,
                    endRadius: 270)

                RadialGradient(
                    colors: [Theme.violet.opacity(0.09), .clear],
                    center: .bottomTrailing,
                    startRadius: 4,
                    endRadius: 320)

                Canvas { context, size in
                    let topArc = Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height * 0.055))
                        path.addCurve(
                            to: CGPoint(x: size.width * 0.31, y: 0),
                            control1: CGPoint(x: size.width * 0.12, y: size.height * 0.13),
                            control2: CGPoint(x: size.width * 0.18, y: -size.height * 0.04))
                    }
                    let bottomArc = Path { path in
                        path.move(to: CGPoint(x: size.width, y: size.height * 0.91))
                        path.addCurve(
                            to: CGPoint(x: size.width * 0.78, y: size.height),
                            control1: CGPoint(x: size.width * 0.91, y: size.height * 0.84),
                            control2: CGPoint(x: size.width * 0.84, y: size.height * 1.04))
                    }
                    context.stroke(topArc,
                                   with: .color(Theme.blueViolet.opacity(0.17)),
                                   style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                    context.stroke(bottomArc,
                                   with: .color(Theme.violet.opacity(0.16)),
                                   style: StrokeStyle(lineWidth: 0.8, lineCap: .round))

                    let stars: [(CGFloat, CGFloat, CGFloat, Double)] = [
                        (0.014, 0.16, 1.4, 0.32), (0.045, 0.075, 2.0, 0.44),
                        (0.19, 0.022, 1.2, 0.28), (0.47, 0.018, 1.3, 0.24),
                        (0.79, 0.025, 1.5, 0.32), (0.982, 0.13, 1.7, 0.36),
                        (0.991, 0.36, 1.3, 0.30), (0.012, 0.58, 1.3, 0.25),
                        (0.987, 0.72, 1.6, 0.31), (0.026, 0.91, 1.8, 0.34),
                        (0.18, 0.984, 1.4, 0.28), (0.62, 0.988, 1.2, 0.24),
                        (0.963, 0.96, 2.0, 0.36),
                    ]

                    for (x, y, diameter, opacity) in stars {
                        let center = CGPoint(x: size.width * x, y: size.height * y)
                        let rect = CGRect(x: center.x - diameter / 2,
                                          y: center.y - diameter / 2,
                                          width: diameter,
                                          height: diameter)
                        context.fill(Path(ellipseIn: rect),
                                     with: .color(Theme.blueViolet.opacity(opacity)))

                        if diameter > 1.7 {
                            var sparkle = Path()
                            sparkle.move(to: CGPoint(x: center.x, y: center.y - 3.5))
                            sparkle.addLine(to: CGPoint(x: center.x, y: center.y + 3.5))
                            sparkle.move(to: CGPoint(x: center.x - 3.5, y: center.y))
                            sparkle.addLine(to: CGPoint(x: center.x + 3.5, y: center.y))
                            context.stroke(sparkle,
                                           with: .color(Color.white.opacity(opacity * 0.9)),
                                           lineWidth: 0.65)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
