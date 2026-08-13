import AppKit
import SwiftUI

enum PickUpTheme {
    static let indigo = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.56, green: 0.54, blue: 1.00, alpha: 1)
            : NSColor(red: 0.36, green: 0.36, blue: 0.86, alpha: 1)
    })

    static let teal = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.33, green: 0.83, blue: 0.76, alpha: 1)
            : NSColor(red: 0.18, green: 0.62, blue: 0.70, alpha: 1)
    })

    static let coral = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.00, green: 0.69, blue: 0.56, alpha: 1)
            : NSColor(red: 0.94, green: 0.48, blue: 0.39, alpha: 1)
    })

    // Keep the workbench on a deliberately light, solid surface. The previous
    // system materials picked up macOS' gray window tint and made every region
    // feel like a separate panel.
    static let canvas = Color.white
    static let surface = Color.white
    static let raised = Color.white
    static let divider = Color.black.opacity(0.07)
    static let border = Color.black.opacity(0.08)

    static let quickSpring = Animation.spring(response: 0.34, dampingFraction: 1.0)
}

struct PickUpBackdrop: View {
    var body: some View {
        PickUpTheme.canvas
        .ignoresSafeArea()
    }
}

struct PickUpIconBadge: View {
    let symbol: String
    var color: Color = PickUpTheme.indigo
    var size: CGFloat = 56

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .stroke(color.opacity(0.22), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

struct PickUpStatusPill: View {
    let title: String
    let symbol: String
    var color: Color = PickUpTheme.indigo

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.13), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct PickUpChromeEdge: View {
    var body: some View {
        PickUpTheme.divider
            .frame(height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct PickUpCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var tint: Color?
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(PickUpTheme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        tint?.opacity(contrast == .increased ? 0.72 : 0.30)
                            ?? Color.black.opacity(contrast == .increased ? 0.34 : 0.08),
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
            }
            .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.07), radius: 16, y: 6)
    }
}

extension View {
    func pickUpCard(tint: Color? = nil, padding: CGFloat = 18) -> some View {
        modifier(PickUpCardModifier(tint: tint, padding: padding))
    }

    @ViewBuilder
    func pickUpAnimated<Value: Equatable>(for value: Value, reduceMotion: Bool) -> some View {
        if reduceMotion {
            animation(.easeOut(duration: 0.16), value: value)
        } else {
            animation(PickUpTheme.quickSpring, value: value)
        }
    }
}
