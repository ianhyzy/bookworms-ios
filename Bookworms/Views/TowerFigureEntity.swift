import RealityKit

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

extension TowerFigure {
    /// The figure's model, `height` scene units tall, standing on the table with its left edge
    /// at `left` and set a little behind the tower, with grounding shadows; or nothing when its
    /// model cannot load.
    @MainActor
    func entity(height: Float, left: Float) async -> Entity? {
        let figure: Entity
        if self == Self.person {
            // Placeholder for Ian's photo: a plain box with a person's proportions, which the
            // lines below scale to his height.
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: UIColor(red: 0.55, green: 0.6, blue: 0.68, alpha: 1))
            figure = ModelEntity(
                mesh: .generateBox(size: [0.27, 1, 0.16], cornerRadius: 0.03),
                materials: [material])
        } else {
            guard let url = Bundle.main.url(forResource: "figure-\(name)", withExtension: "usdz"),
                let loaded = try? await Entity(contentsOf: url)
            else { return nil }
            figure = loaded
        }
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
        return figure
    }
}
