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
    static func check(width: Int, height: Int, recipe: EditRecipe, allowOvercommit: Bool = false)
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
        if recipe.look.enabled && recipe.look.mode == .spektrafilm && recipe.mix < 1 { estimate += pixels * 32 }
        if recipe.look.enabled && recipe.monochromeGrain && recipe.flag("film_render.grain.active") {
            estimate += pixels * 32
        }
        if max(width, height) <= 2048 && !recipe.tone.outputStage.isIdentity {
            estimate += pixels * 48
        }
        let pitch = recipe.number("camera.film_format_mm") * 1000 / Double(max(width, height))
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
            estimate += power(width + 2 * radius) * power(height + 2 * radius) * 128
        }
        let processAllowance = ImageMemoryAllowance.available
        // Metal's recommended working set is a performance advisory, not an allocation limit.
        // The process headroom and single-buffer limit above are the admission limits.
        guard allowOvercommit || estimate < processAllowance else {
            throw Failure(estimated: estimate, available: processAllowance)
        }
    }
}
