import AppKit

/// Glass like the system Dock's: the wallpaper behind, softened by a blur, with
/// its colors deepened and a light wash over it. Measured against the system
/// Dock, the System Settings › Appearance › Liquid Glass slider (Clear ↔ Tinted)
/// mostly saturates the glass; its brightness barely changes.
///
/// The Dock draws its glass with its own private material. NSGlassEffectView's
/// public styles frost the wallpaper into a flat slab, and its Dock-like variant
/// bends it in a thick ripple along the whole rim, so this view builds the look
/// from the backdrop layer that NSVisualEffectView itself uses. `make()` returns
/// nil where those private classes are missing, so the caller can fall back.
final class DockGlassView: NSView {
    private let backdrop: CALayer
    private let blur: NSObject
    private let saturate: NSObject
    private let wash = CALayer()

    static func make() -> DockGlassView? {
        let create = NSSelectorFromString("filterWithType:")
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              filterClass.responds(to: create),
              let blur = filterClass.perform(create, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject,
              let saturate = filterClass.perform(create, with: "colorSaturate")?.takeUnretainedValue() as? NSObject
        else { return nil }
        return DockGlassView(backdrop: layerClass.init(), blur: blur, saturate: saturate)
    }

    private init(backdrop: CALayer, blur: NSObject, saturate: NSObject) {
        self.backdrop = backdrop
        self.blur = blur
        self.saturate = saturate
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
        let tint = min(max(UserDefaults.standard.double(forKey: "NSGlassTintAmount"), 0), 1)
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        // The system Dock keeps about a quarter of the wallpaper's texture and
        // 80% of its brightness; at the slider's middle its colors are about a
        // third more saturated, and more toward Tinted.
        blur.setValue(opaque ? 30 : 2 + 4 * tint, forKey: "inputRadius")
        saturate.setValue(max(1, 0.9 + tint), forKey: "inputAmount")
        backdrop.filters = [blur, saturate]
        let base = dark ? NSColor.black : NSColor.white
        let alpha: CGFloat = opaque ? 0.9 : 0.2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.backgroundColor = systemWash ? base.withAlphaComponent(alpha).cgColor : nil
        CATransaction.commit()
    }
}
