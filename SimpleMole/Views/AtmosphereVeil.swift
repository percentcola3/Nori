import SwiftUI

/// 主窗口的"大气层"纱幕：叠在 L0 窗口玻璃与内容之间，只调光影、不加色块。
/// - 纵向：顶部与底部略压暗，中段最通透，避免整面同一种蓝的扁平感；
/// - 天光：顶部中央一束极淡的冷白光，落在导航后方，形成视觉焦点；
/// - 暗角：四角向深空墨蓝收拢，把视线拉回中央内容。
/// 全部半透明，玻璃的磨砂与折射仍会透出；仅深色外观启用，
/// 减少透明度时不绘制（窗口已回退为 glassOpaque 实底）。
struct AtmosphereVeil: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if colorScheme == .dark && !reduceTransparency {
            ZStack {
                LinearGradient(stops: [
                    .init(color: Color.atmosphereSpace.opacity(0.20), location: 0.0),
                    .init(color: Color.atmosphereSpace.opacity(0.04), location: 0.42),
                    .init(color: Color.atmosphereSpace.opacity(0.18), location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
                EllipticalGradient(stops: [
                    .init(color: Color.atmosphereHaze.opacity(0.16), location: 0.0),
                    .init(color: Color.atmosphereHaze.opacity(0.05), location: 0.45),
                    .init(color: Color.atmosphereHaze.opacity(0.0), location: 1.0),
                ], center: .top, startRadiusFraction: 0, endRadiusFraction: 0.62)
                EllipticalGradient(stops: [
                    .init(color: .clear, location: 0.6),
                    .init(color: Color.atmosphereSpace.opacity(0.20), location: 1.0),
                ], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.75)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
