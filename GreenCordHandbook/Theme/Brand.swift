import SwiftUI

/// Princeton ISD's colours, defined once.
///
/// The hex values come from the district site's own stylesheet - see
/// `content/source-of-truth.md`. Views refer to these tokens and never to a
/// colour literal, so re-skinning the app means editing the asset catalogue and
/// nothing else.
enum Brand {
    /// `--primary-color` on pshs.princetonisd.net. Defined in
    /// Assets.xcassets/BrandMaroon, which carries a lighter variant for dark
    /// mode so text on a dark background stays legible.
    static let maroon = Color("BrandMaroon")

    /// `--secondary-color`. Used for dividers and muted chrome.
    static let silver = Color("BrandSilver")

    /// The fill behind white text. In light mode this is the official maroon; in
    /// dark mode it stays dark, because white-on-light-maroon would fail
    /// contrast. See verification/contrast.md.
    static let maroonSurface = Color("BrandMaroonSurface")

    /// The green of the cord itself, for the one thing the programme is named
    /// after: the progress ring and the "requirement met" state.
    static let cordGreen = Color("CordGreen")

    static let pageBackground = Color("PageBackground")
    static let cardBackground = Color("CardBackground")

    /// Documented hex values, kept here so tests and verification/contrast.md
    /// can assert against the same numbers the asset catalogue holds.
    enum Hex {
        /// Sampled from the district's own panther logo, which ships in
        /// `content/source/brand/`. Changing it means re-running
        /// `tools/check_contrast.py`.
        static let maroon = "5E0227"
        static let maroonDark = "C66A8F"
        static let silver = "BEBFC1"
        static let cordGreen = "1B6B3A"
        static let cordGreenDark = "5FD08A"
    }
}

/// A status pill. The colour is a hint; the word is the information, so this
/// reads correctly for someone who cannot distinguish the colours.
struct StatusBadge: View {
    let status: EntryStatus

    private var tint: Color {
        switch status {
        case .approved: return Brand.cordGreen
        case .submitted: return Brand.maroon
        case .rejected: return .red
        case .revisionRequested: return .orange
        case .draft: return .secondary
        }
    }

    private var symbol: String {
        switch status {
        case .approved: return "checkmark.seal.fill"
        case .submitted: return "clock.fill"
        case .rejected: return "xmark.circle.fill"
        case .revisionRequested: return "pencil.circle.fill"
        case .draft: return "doc.text"
        }
    }

    var body: some View {
        Label(status.displayName, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel("Status: \(status.displayName)")
    }
}

/// The panther mark, drawn as vector art for this project.
///
/// It is **not** the district's logo: the Green Cord program page publishes only
/// a wordmark and a letter "P", neither of which contains an animal. Swapping in
/// the school's official mark is one asset-catalogue change, described in
/// README.md under "Replacing the panther mark".
/// The district's panther logo, as supplied by the school.
///
/// The file is a square with its own maroon background, so it is shown as a
/// rounded tile rather than floated on the page - treating it as a transparent
/// mark would put a maroon block in the middle of a white screen.
///
/// `PantherMark` below is the drawn fallback, kept for anywhere the real logo
/// is too detailed to read.
struct BrandLogo: View {
    var size: CGFloat = 96

    var body: some View {
        Image("PantherLogo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct PantherMark: View {
    var size: CGFloat = 28
    var tint: Color = .primary

    var body: some View {
        PantherShape()
            .fill(tint, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The silhouette itself. The eyes are separate subpaths and the shape is filled
/// even-odd, so they read as holes rather than as drawn-on dots - which is what
/// keeps the face legible at tab-bar size.
struct PantherShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 100
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(
                translationX: rect.minX + (rect.width - 100 * scale) / 2,
                y: rect.minY + (rect.height - 100 * scale) / 2
            ))

        var path = Path()

        path.move(to: CGPoint(x: 18, y: 54))
        path.addCurve(
            to: CGPoint(x: 31, y: 27),
            control1: CGPoint(x: 18, y: 41),
            control2: CGPoint(x: 23, y: 32)
        )
        path.addLine(to: CGPoint(x: 24, y: 6))    // left ear tip
        path.addLine(to: CGPoint(x: 43, y: 21))
        path.addCurve(
            to: CGPoint(x: 57, y: 21),
            control1: CGPoint(x: 47, y: 19),
            control2: CGPoint(x: 53, y: 19)
        )
        path.addLine(to: CGPoint(x: 76, y: 6))    // right ear tip
        path.addLine(to: CGPoint(x: 69, y: 27))
        path.addCurve(
            to: CGPoint(x: 82, y: 54),
            control1: CGPoint(x: 77, y: 32),
            control2: CGPoint(x: 82, y: 41)
        )
        path.addCurve(
            to: CGPoint(x: 64, y: 82),
            control1: CGPoint(x: 82, y: 67),
            control2: CGPoint(x: 75, y: 76)
        )
        path.addLine(to: CGPoint(x: 50, y: 94))   // chin
        path.addLine(to: CGPoint(x: 36, y: 82))
        path.addCurve(
            to: CGPoint(x: 18, y: 54),
            control1: CGPoint(x: 25, y: 76),
            control2: CGPoint(x: 18, y: 67)
        )
        path.closeSubpath()

        // Eyes: angled slits, which is what makes the silhouette read as a big
        // cat rather than a house cat.
        for mirrored in [false, true] {
            let flip: (Double) -> Double = { mirrored ? 100 - $0 : $0 }
            var eye = Path()
            eye.move(to: CGPoint(x: flip(31), y: 50))
            eye.addLine(to: CGPoint(x: flip(45), y: 46))
            eye.addLine(to: CGPoint(x: flip(45), y: 54))
            eye.addLine(to: CGPoint(x: flip(33), y: 57))
            eye.closeSubpath()
            path.addPath(eye)
        }

        // Muzzle notch.
        var muzzle = Path()
        muzzle.move(to: CGPoint(x: 50, y: 66))
        muzzle.addLine(to: CGPoint(x: 58, y: 73))
        muzzle.addLine(to: CGPoint(x: 50, y: 80))
        muzzle.addLine(to: CGPoint(x: 42, y: 73))
        muzzle.closeSubpath()
        path.addPath(muzzle)

        return path.applying(transform)
    }
}
