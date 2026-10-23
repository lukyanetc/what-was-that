import SwiftUI

extension View {
    /// Opacity of the entry text. Color emoji do not take opacity from the text color (`foregroundStyle`),
    /// so it is applied as the opacity of the view itself, and the text color is used without it (otherwise it would apply twice).
    func fadedLikeText(_ appearance: Appearance) -> some View {
        foregroundStyle(appearance.textColor).opacity(appearance.textOpacity)
    }
}

/// A row of 9 colors and "no color" as rounded squares with side `size`.
/// They slide out from the indicator position to the right along the input line, one after another, and fade in slightly. Choosing one calls `onChoose` (nil means no color).
struct ColorStrip: View {
    let size: Double
    let onChoose: (Int?) -> Void
    @State private var isOpen = false

    /// Invisible area around the dot: clicking it also counts.
    static let slotPadding = 2.0

    var body: some View {
        let count = Appearance.indicatorColors.count
        let slot = size + 2 * Self.slotPadding
        HStack(spacing: 0) {
            ForEach(0...count, id: \.self) { index in
                Button { onChoose(index < count ? index : nil) } label: {
                    swatch(index < count ? index : nil)
                        .frame(width: size, height: size)
                        .padding(Self.slotPadding)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .scaleEffect(isOpen ? 1 : 0.3)
                .opacity(isOpen ? 1 : 0)
                .offset(x: isOpen ? 0 : -Double(index) * slot)
                .animation(.spring(duration: 0.2, bounce: 0.15).delay(Double(index) * 0.01), value: isOpen)
            }
        }
        .onAppear { isOpen = true }
    }

    @ViewBuilder private func swatch(_ index: Int?) -> some View {
        if let index {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(Appearance.indicatorColors[index].opacity(Appearance.indicatorOpacity))
        } else {
            // "No color": an empty outline with a cross.
            RoundedRectangle(cornerRadius: size * 0.25).strokeBorder(lineWidth: 1).opacity(0.5)
                .overlay { Image(systemName: "xmark").font(.system(size: size * 0.4)).opacity(0.5) }
        }
    }
}
