import SwiftUI

/// The app mark: a rounded squircle rotated to a diamond, with a brushed-silver
/// gradient. Sized to fit within a `size × size` box.
struct AppLogo: View {
    var size: CGFloat

    var body: some View {
        let side = size * 0.72
        RoundedRectangle(cornerRadius: side * 0.32, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.92), Color(white: 0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: side, height: side)
            .rotationEffect(.degrees(45))
            .frame(width: size, height: size)
    }
}
