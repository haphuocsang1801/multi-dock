import AppKit

/// Clear glass like the system Dock's: the wallpaper shows through almost sharp,
/// under a light blur and a wash whose strength follows System Settings ›
/// Appearance › Liquid Glass (Clear ↔ Tinted).
///
/// The Dock draws its glass with its own private material. NSGlassEffectView's
/// public styles frost the wallpaper into a flat slab, and its Dock-like variant
/// bends it in a thick ripple along the whole rim, so this view builds the look
/// from the backdrop layer that NSVisualEffectView itself uses. `make()` returns
/// nil where those private classes are missing, so the caller can fall back.
final class DockGlassView: NSView {
    private let backdrop: CALayer
    private let blur: NSObject
    private let wash = CALayer()

    static func make() -> DockGlassView? {
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              filterClass.responds(to: NSSelectorFromString("filterWithType:")),
              let blur = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                .takeUnretainedValue() as? NSObject
        else { return nil }
        return DockGlassView(backdrop: layerClass.init(), blur: blur)
    }

    private init(backdrop: CALayer, blur: NSObject) {
        self.backdrop = backdrop
        self.blur = blur
        super.init(frame: .zero)
        wantsLayer = true
        backdrop.setValue(true, forKey: "windowServerAware")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        backdrop.masksToBounds = true
        wash.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        backdrop.addSublayer(wash)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { backdrop }

    override func layout() {
        super.layout()
        wash.frame = bounds
    }

    /// `systemWash` darkens (or, in Light mode, lightens) the glass the way the
    /// system Dock does; themes pass false and lay their own color over it.
    func update(systemWash: Bool, dark: Bool) {
        // 0 is Clear, 1 is Tinted; the key is absent until the slider is moved.
        let tint = CGFloat(min(max(UserDefaults.standard.double(forKey: "NSGlassTintAmount"), 0), 1))
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        blur.setValue(opaque ? 30 : 1.5 + 3 * tint, forKey: "inputRadius")
        backdrop.filters = [blur]
        let base = dark ? NSColor.black : NSColor.white
        let alpha = opaque ? 0.9 : 0.08 + 0.35 * tint
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.backgroundColor = systemWash ? base.withAlphaComponent(alpha).cgColor : nil
        CATransaction.commit()
    }
}
