"""Illustrate gate clipping versus shared film exposure; not a calibrated film model.

Run with the project's existing Reference/.venv Python. Generates PNG and SVG
beside this script. This is research material, not application rendering code.
"""

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.ndimage import gaussian_filter


OUT = Path(__file__).resolve().parent
x = np.linspace(-0.65, 0.55, 540)
y = np.linspace(-0.36, 0.36, 324)
xx, yy = np.meshgrid(x, y)
gate = xx < 0
source = 0.025 + 28 * np.exp(-((xx + 0.095) ** 2 + yy**2) / (2 * 0.035**2))
direct = source * gate
fog = 0.002
plain = np.repeat((direct + fog)[..., None], 3, axis=2)
integrated = plain.copy()
pitch = x[1] - x[0]
for channel, energy in enumerate((0.16, 0.045, 0.009)):
    # Arbitrary, normalized, zero-padded example kernels. No off-frame light
    # is invented; only light admitted by the gate supplies the returned field.
    scatter = gaussian_filter(direct, 0.018 / pitch, mode="constant")
    returned = gaussian_filter(direct, 0.095 / pitch, mode="constant")
    integrated[..., channel] += 0.025 * scatter + energy * returned


def display(exposure):
    # Merely a monotonic viewing transform, not film development or printing.
    return np.clip(exposure / (1 + exposure), 0, 1) ** (1 / 2.2)


plt.rcParams.update(
    {
        "font.family": "DejaVu Sans",
        "font.size": 10,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.labelcolor": "#374151",
        "text.color": "#17212b",
        "xtick.color": "#64748b",
        "ytick.color": "#64748b",
        "svg.fonttype": "none",
    }
)
fig = plt.figure(figsize=(13.5, 6.4), facecolor="#fafaf8")
grid = fig.add_gridspec(1, 3, width_ratios=(1, 1, 1.12), wspace=0.25)
for col, (pixels, title) in enumerate(
    ((plain, "Fixed border after rendering"), (integrated, "Shared film exposure"))
):
    ax = fig.add_subplot(grid[col])
    ax.imshow(
        display(pixels), origin="lower", extent=(x[0], x[-1], y[0], y[-1]),
        aspect="equal", interpolation="nearest"
    )
    ax.axvline(0, color="white", linewidth=0.7, linestyle=(0, (3, 4)), alpha=0.65)
    ax.set_title(title, fontsize=11, fontweight="bold", pad=14)
    ax.set_xlabel("Distance from gate edge (mm)", labelpad=10)
    ax.set_yticks([])
    ax.set_xticks((-0.5, 0, 0.5))
    ax.text(-0.32, 0.30, "IMAGE", color="#e5e7eb", fontsize=9, ha="center")
    ax.text(0.28, 0.30, "REBATE", color="#e5e7eb", fontsize=9, ha="center")
    for spine in ax.spines.values():
        spine.set_visible(False)

ax = fig.add_subplot(grid[2])
row = np.argmin(np.abs(y))
ax.axvspan(0, x[-1], color="#ece8dd", zorder=0)
ax.semilogy(x, plain[row, :, 0], color="#64748b", linewidth=1.5,
            linestyle=(0, (4, 3)), label="Direct + base exposure")
for channel, color, label in (
    (0, "#ba493c", "With return · R"),
    (1, "#52845d", "With return · G"),
    (2, "#4c78a8", "With return · B"),
):
    ax.semilogy(x, integrated[row, :, channel], color=color, linewidth=1.5, label=label)
ax.axvline(0, color="#7b7d77", linewidth=0.8)
ax.set_title("Exposure across the same edge", fontsize=11, fontweight="bold", pad=14)
ax.set_xlabel("Distance from gate edge (mm)", labelpad=10)
ax.set_ylabel("Relative exposure · log scale", labelpad=8)
ax.set_xlim(-0.42, 0.50)
ax.set_ylim(0.001, 50)
ax.grid(axis="y", alpha=0.16)
ax.legend(loc="upper right", frameon=False, fontsize=8)
ax.text(0.26, 0.004, "unexposed film\ncan receive returned light", fontsize=8,
        ha="center", color="#565d60")

fig.text(0.055, 0.935, "The border belongs to the film", fontsize=21, fontweight="bold")
fig.text(0.055, 0.881,
         "A bright source near the gate can expose adjacent emulsion before development.",
         fontsize=11, color="#53616b")
fig.text(0.055, 0.063,
         "DESIGN ILLUSTRATION ONLY  ·  Arbitrary kernel, energy and viewing curve; no real-film calibration.",
         fontsize=9, color="#53616b")
fig.text(0.055, 0.030,
         "This compares two toy constructions. It is neither SpektraLab output nor an implemented SpektraCam feature.",
         fontsize=9, color="#53616b")
fig.subplots_adjust(left=0.055, right=0.985, top=0.78, bottom=0.22)
fig.savefig(OUT / "boundary_concept.png", dpi=160, facecolor=fig.get_facecolor())
fig.savefig(OUT / "boundary_concept.svg", facecolor=fig.get_facecolor())
plt.close(fig)
print("Wrote boundary_concept.png and boundary_concept.svg")
