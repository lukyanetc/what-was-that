import SwiftUI

extension View {
    /// Прозрачность текста записи. Цветные эмодзи не берут прозрачность из цвета текста (`foregroundStyle`),
    /// поэтому она применяется как прозрачность самого вида, а цвет текста идёт без неё (иначе она сложилась бы дважды).
    func fadedLikeText(_ appearance: Appearance) -> some View {
        foregroundStyle(appearance.textColor).opacity(appearance.textOpacity)
    }
}

/// Ряд из 9 цветов и «без цвета» в виде скруглённых квадратов со стороной `size`.
/// Они выезжают из места индикатора вправо вдоль линии ввода, один за другим, и слегка проявляются. Выбор вызывает `onChoose` (nil — без цвета).
struct ColorStrip: View {
    let size: Double
    let onChoose: (Int?) -> Void
    @State private var isOpen = false

    /// Невидимое поле вокруг кружка: по нему тоже можно попасть кликом.
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
            // «Без цвета»: пустой контур с крестиком.
            RoundedRectangle(cornerRadius: size * 0.25).strokeBorder(lineWidth: 1).opacity(0.5)
                .overlay { Image(systemName: "xmark").font(.system(size: size * 0.4)).opacity(0.5) }
        }
    }
}
