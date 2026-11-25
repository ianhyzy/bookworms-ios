import RealityKit

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

extension TowerFigure {
    /// The figure's model, `height` scene units tall, standing on the table with its left edge
    /// at `left` and set a little behind the tower, with grounding shadows; or nothing when its
    /// model cannot load. The reader's figure wears `face`, their profile photo, when there is
    /// one.
    @MainActor
    func entity(height: Float, left: Float, face: UIImage? = nil) async -> Entity? {
        guard let url = Bundle.main.url(forResource: "figure-\(name)", withExtension: "usdz"),
            let figure = try? await Entity(contentsOf: url)
        else { return nil }
        let bounds = figure.visualBounds(relativeTo: nil)
        figure.scale *= height / max(bounds.extents.y, 0.001)
        let scaled = figure.visualBounds(relativeTo: nil)
        figure.position += SIMD3<Float>(
            left - scaled.min.x, -scaled.min.y, -scaled.center.z - scaled.extents.z * 0.3)
        func ground(_ entity: Entity) {
            if entity.components.has(ModelComponent.self) {
                entity.components.set(GroundingShadowComponent(castsShadow: true))
            }
            entity.children.forEach(ground)
        }
        ground(figure)
        // The mask goes on after the figure is sized, so it doesn't count toward its height.
        if isReader, let face, let head = figure.findEntity(named: "head") {
            figure.addChild(Self.mask(face, before: head.visualBounds(relativeTo: figure)))
        }
        return figure
    }

    /// `photo` on a flat round card, held flat against the front of the head whose bounds are
    /// `head`, like a mask. The card is wider than the head, so the photo reads at share size.
    @MainActor
    private static func mask(_ photo: UIImage, before head: BoundingBox) -> Entity {
        let diameter = head.extents.y * 1.25
        let thickness = diameter * 0.015
        var card = PhysicallyBasedMaterial()
        card.baseColor = .init(tint: UIColor(white: 0.93, alpha: 1))
        card.roughness = 0.8
        let mask = ModelEntity(
            mesh: .generateCylinder(height: thickness, radius: diameter / 2), materials: [card])
        // The cylinder's axis turns from up to toward the camera, so its face is the card's.
        mask.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        mask.position = [head.center.x, head.center.y, head.max.z + thickness / 2]
        if let image = photo.cgImage,
            let texture = try? TextureResource(image: image, options: .init(semantic: .color))
        {
            var print = PhysicallyBasedMaterial()
            print.baseColor = .init(tint: .white, texture: .init(texture))
            print.roughness = 0.6
            // A circle: a square plane whose corners round to half its side. It lies just in
            // front of the card's face, in the mask's turned frame, where up is toward the
            // camera.
            let face = ModelEntity(
                mesh: .generatePlane(
                    width: diameter * 0.96, height: diameter * 0.96, cornerRadius: diameter * 0.48),
                materials: [print])
            face.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            face.position = [0, thickness / 2 + 0.0005, 0]
            mask.addChild(face)
        }
        mask.components.set(GroundingShadowComponent(castsShadow: true))
        return mask
    }
}
