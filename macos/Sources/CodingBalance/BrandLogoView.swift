import SwiftUI

/// 品牌 Logo：品牌蓝圆角方块 + 白色「代码尖括号 </>」。
/// 极简配色（品牌蓝 #2F7CF6 + 白），与 AppIcon.svg 保持同一视觉。
struct BrandLogoView: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Color(red: 47 / 255, green: 124 / 255, blue: 246 / 255))
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size * 0.52, weight: .heavy))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Coding Balance")
    }
}
