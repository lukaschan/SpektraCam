import Metal

extension MTLComputeCommandEncoder {
    /// Uniform threadgroups work on every Metal device, including Simulator GPUs that do not
    /// support nonuniform dispatch. Kernels must guard the logical bounds before accessing data.
    nonisolated func dispatchGrid(_ grid: MTLSize, threadsPerThreadgroup group: MTLSize) {
        guard grid.width > 0, grid.height > 0, grid.depth > 0 else { return }
        dispatchThreadgroups(
            MTLSize(
                width: 1 + (grid.width - 1) / group.width,
                height: 1 + (grid.height - 1) / group.height,
                depth: 1 + (grid.depth - 1) / group.depth),
            threadsPerThreadgroup: group)
    }
}
