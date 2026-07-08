import SwiftUI

/// Visual language for Bard, drawn from the app icon: a red-figure Greek pottery
/// medallion (terracotta figure on near-black glaze, bronze meander border).
enum BardTheme {
    static let terracotta = Color(red: 0.757, green: 0.400, blue: 0.180)  // #C1662E
    static let terracottaDeep = Color(red: 0.522, green: 0.259, blue: 0.114)  // #85421D
    static let terracottaBright = Color(red: 0.867, green: 0.510, blue: 0.298)  // #DD824C
    static let charcoal = Color(red: 0.098, green: 0.078, blue: 0.067)  // #191411
    static let charcoalLight = Color(red: 0.157, green: 0.129, blue: 0.110)  // #28211C
    static let parchment = Color(red: 0.953, green: 0.914, blue: 0.839)  // #F3E9D6

    static func canvasBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? charcoal : parchment
    }

    static func panelBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? charcoalLight : Color.white
    }
}

extension Font {
    /// Serif display font for hero moments (empty state, "done" screen) — larger
    /// and more deliberately weighted than the app-wide serif set via `.font()`
    /// on the window root in BardApp.swift.
    static func bardDisplay(_ size: CGFloat = 22, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

/// Compact, tracked-caps section label matching native macOS inspector styling
/// (e.g. Finder's Info panel), used instead of oversized .headline/.title labels.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .serif))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// A thin repeating meander ("Greek key") rule, echoing the app icon's border
/// motif. Used sparingly as a decorative divider, not as a UI workhorse.
struct GreekKeyRule: View {
    var color: Color = BardTheme.terracottaDeep
    var unit: CGFloat = 9
    var lineWidth: CGFloat = 1.25

    var body: some View {
        GeometryReader { geo in
            let count = max(Int(geo.size.width / (unit * 2)), 1)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { _ in
                    GreekKeyMotif()
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .square))
                        .frame(width: unit * 2, height: unit)
                }
            }
            .frame(width: geo.size.width, alignment: .center)
        }
        .frame(height: unit)
    }
}

private struct GreekKeyMotif: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w * 0.7, y: 0))
        p.addLine(to: CGPoint(x: w * 0.7, y: h * 0.55))
        p.addLine(to: CGPoint(x: w * 0.3, y: h * 0.55))
        p.addLine(to: CGPoint(x: w * 0.3, y: h))
        p.addLine(to: CGPoint(x: w, y: h))
        return p
    }
}
