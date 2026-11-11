import Foundation
import Metal

#if os(iOS)
    import os
#endif

/// Conservative admission check before decoding a full-size source. A rejected request
/// stays at the chosen size; it never silently substitutes a low-resolution export.
nonisolated enum RenderMemoryBudget {
    struct Failure: LocalizedError {
        var estimated: UInt64? = nil
        var available: UInt64? = nil
        var errorDescription: String? {
            if let estimated, let available {
                return
                    String(
                        localized: "render_memory_budget.estimated_usage_warning",
                        defaultValue:
                            "This render is estimated to need \(estimated / 1_048_576) MB; the current safe allowance is \(available / 1_048_576) MB. Choose a smaller size or disable diffusion and try again."
                    )
            }
            return String(
                localized: "render_memory_budget.this_size_exceeds_the_rendering_limits_choose",
                defaultValue:
                    "This size exceeds the rendering limits. Choose a smaller size and try again.")
        }
    }
    /// A whole-frame diffusion transform pads to a power of two around the full kernel radius.
    /// Past this size the frame is rendered in tiles, where the transform stays tile-sized.
    static let wholeFrameTransformLimit: UInt64 = 512 * 1024 * 1024
    static func rendersInTiles(width: Int, height: Int, transformBytes: UInt64) -> Bool {
        PixelStore.isLarge(width: width, height: height) || transformBytes > wholeFrameTransformLimit
    }
    /// Whether this frame takes the tiled path. The renderer and the admission check agree on it.
    static func rendersInTiles(
        width: Int, height: Int, recipe: EditRecipe, pixelPitchMicrometers: Double? = nil
    ) -> Bool {
        guard width > 0, height > 0 else { return false }
        let transforms = (try? diffusionTransformBytes(
            width: width, height: height, recipe: recipe,
            pixelPitchMicrometers: pixelPitchMicrometers)) ?? 0
        return rendersInTiles(width: width, height: height, transformBytes: transforms)
    }
    /// Working memory of the whole-frame diffusion transforms this recipe would run.
    static func diffusionTransformBytes(
        width: Int, height: Int, recipe: EditRecipe, pixelPitchMicrometers: Double?
    ) throws -> UInt64 {
        var total: UInt64 = 0
        let pitch = pixelPitchMicrometers
            ?? recipe.number("camera.film_format_mm") * 1000 / Double(max(width, height))
        for prefix in ["camera.diffusion_filter", "enlarger.diffusion_filter"] {
            guard recipe.look.enabled else { continue }
            if prefix.hasPrefix("enlarger") && recipe.bypassesPrint { continue }
            guard recipe.flag(prefix + ".active"), recipe.number(prefix + ".strength") > 0 else {
                continue
            }
            var p = DiffusionCore.Parameters()
            p.family = recipe.choice(prefix + ".filter_family")
            p.spatialScale = recipe.number(prefix + ".spatial_scale")
            p.size = .init(
                recipe.number(prefix + ".core_size"), recipe.number(prefix + ".halo_size"),
                recipe.number(prefix + ".bloom_size"))
            let radius = try DiffusionCore.radius(
                width: width, height: height, pixelSize: pitch, parameters: p)
            func power(_ value: Int) -> UInt64 {
                var n: UInt64 = 1
                while n < value { n *= 2 }
                return n
            }
            total += power(width + 2 * radius) * power(height + 2 * radius) * 128
        }
        return total
    }
    static func check(width: Int, height: Int, recipe: EditRecipe, allowOvercommit: Bool = false,
                      pixelPitchMicrometers: Double? = nil)
        throws
    {
        guard width > 0, height > 0, width <= 65536, height <= 65536,
            let device = MTLCreateSystemDefaultDevice()
        else { throw Failure() }
        let pixels = UInt64(width) * UInt64(height)
        guard pixels <= UInt64(device.maxBufferLength / 16) else { throw Failure() }
        // Full-frame graph storage plus CPU input; decode and pointwise grade have separate lifetimes.
        // Pointwise grading uses 128-row strips, including LUT/noise references.
        var estimate = recipe.look.enabled
            ? pixels * (recipe.look.mode == .lut ? 192 : 176) + 96 * 1024 * 1024
            : pixels * 80 + 32 * 1024 * 1024
        // The support graph plus an optional retained center/paper bitmap. No mask bitmap.
        if recipe.filmEdgeLayout != nil { estimate += pixels * 64 }
        if recipe.look.enabled && recipe.look.mode == .spektrafilm && recipe.mix < 1 { estimate += pixels * 32 }
        if recipe.look.enabled && recipe.monochromeGrain && recipe.flag("film_render.grain.active") {
            estimate += pixels * 32
        }
        if max(width, height) <= 2048 && !recipe.tone.outputStage.isIdentity {
            estimate += pixels * 48
        }
        let transforms = try diffusionTransformBytes(
            width: width, height: height, recipe: recipe, pixelPitchMicrometers: pixelPitchMicrometers)
        if rendersInTiles(width: width, height: height, transformBytes: transforms) {
            // Tiled render: the graph's memory follows the tile, pixels live in file-backed
            // storage, and only 8-bit results scale with the image.
            let allowance = ImageMemoryAllowance.available
            let edge = UInt64(
                min(MetalFilmPipeline.Tiling.fitting(available: allowance).tileEdge, max(width, height)))
            let graph: UInt64 = recipe.look.enabled ? edge * edge * 16 * 14 : 0
            // A film edge that composites a separately graded centre also holds its gate mask.
            let perPixel: UInt64 = recipe.filmEdgeLayout == nil ? 12 : 18
            let tiled = graph + pixels * perPixel + 160 * 1024 * 1024
            guard allowOvercommit || tiled < allowance else {
                throw Failure(estimated: tiled, available: allowance)
            }
            return
        }
        estimate += transforms
        let processAllowance = ImageMemoryAllowance.available
        // Metal's recommended working set is a performance advisory, not an allocation limit.
        // The process headroom and single-buffer limit above are the admission limits.
        guard allowOvercommit || estimate < processAllowance else {
            throw Failure(estimated: estimate, available: processAllowance)
        }
    }
}
