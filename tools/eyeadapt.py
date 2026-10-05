"""Fit a game's own auto exposure response from an EyeAdaptProbe recording.

EyeAdaptProbe.fx bakes a calibrated meter bar into every frame: bar length
encodes metered scene luminance, and two swatches at the ends of the bar are
always pure black and pure white so this script can correct for whatever
levels or gamma shift the recording introduces before trusting the bar itself.

Capture: enable EyeAdaptProbe alone, with PHDRPlus and any other tone mapper
disabled, since the target is the game's own adaptation. Swing the camera to
the subject that should trigger it, hold completely still through the whole
transition, and keep recording until the bar settles. A moving camera changes
scene content as well as exposure and the two cannot be told apart afterwards,
so the hold is what keeps the reading a pure exposure response. Capture one
clip for brightening (dark to bright) and a separate one for darkening, since
games commonly adapt at different rates in each direction, matching PHDRPlus's
own Eye Adaptation Speed and Dark Adaptation Multiplier.

Extract frames at a known, fixed frame rate, for example:

    ffmpeg -i capture.mp4 -vf fps=30 work\\eyeadapt\\frame_%04d.png

Then run:

    python tools/eyeadapt.py work\\eyeadapt --fps 30

The script finds the sharpest single-frame jump in the bar as the moment the
scene changed, fits the settling that follows as a single exponential in both
EV (log2 luminance) and linear luminance space, and reports whichever domain
fits better along with the time constant in seconds. That time constant is
the number to compare against PHDRPlus's Eye Adaptation Speed when tuning it
for this game.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

import numpy as np
from numpy.typing import NDArray
from PIL import Image

type Arr = NDArray[np.float64]


def read_bar_fraction(
    path: Path, bar_height_frac: float, bar_position: str, swatch_frac: float
) -> float:
    """Decode one frame's meter bar into a fill fraction in [0, 1]."""
    img = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
    h, w, _ = img.shape

    bar_h = max(1, round(h * bar_height_frac))
    strip = img[h - bar_h : h] if bar_position == "bottom" else img[0:bar_h]

    # A few central rows, averaged, to ride out per-row dither and codec noise.
    mid = strip.shape[0] // 2
    rows = strip[max(0, mid - 2) : mid + 3]
    profile = rows.mean(axis=(0, 2))

    sw = max(1, round(w * swatch_frac))
    black_ref = profile[:sw].mean()
    white_ref = profile[w - sw :].mean()
    span = max(1e-6, white_ref - black_ref)
    norm = np.clip((profile - black_ref) / span, 0.0, 1.0)

    return crossing_fraction(norm[sw : w - sw], 0.5)


def crossing_fraction(bar: Arr, threshold: float) -> float:
    """Sub-pixel position where `bar` first drops below `threshold`, as a
    fraction of its length. The meter fills from index 0, so this is the
    fill fraction the shader drew."""
    above = bar >= threshold
    if not above.any():
        return 0.0
    if above.all():
        return 1.0

    idx = int(np.argmax(~above))
    if idx == 0:
        return 0.0

    v0, v1 = bar[idx - 1], bar[idx]
    t = (v0 - threshold) / (v0 - v1) if v0 != v1 else 0.0
    crossing = (idx - 1) + t
    return crossing / (len(bar) - 1)


def _log_linear_fit(t_rel: Arr, resid: Arr) -> tuple[float, float]:
    """R^2 and slope of log|resid| against t_rel, for one candidate plateau.
    A clean exponential settling to the true plateau is a straight line in
    this space; the wrong plateau bends it, which is what the search below
    uses to find the right one."""
    mask = np.abs(resid) > 1e-9
    if mask.sum() < 3:
        return -np.inf, np.nan

    log_resid = np.log(np.abs(resid[mask]))
    slope, intercept = np.polyfit(t_rel[mask], log_resid, 1)
    if slope >= 0:
        return -np.inf, slope

    pred = intercept + slope * t_rel[mask]
    ss_res = np.sum((log_resid - pred) ** 2)
    ss_tot = np.sum((log_resid - log_resid.mean()) ** 2)
    r_squared = 1.0 - ss_res / ss_tot if ss_tot > 0 else 0.0
    return r_squared, slope


def fit_exponential(t: Arr, y: Arr) -> tuple[float, float, float]:
    """Fit y = plateau + (y0 - plateau) * exp(-t / tau) from the point of
    steepest change onward. Returns (tau, plateau, r_squared).

    The plateau is not read off the tail of the clip: a capture that stops
    before the response fully settles would bias that average and, with it,
    every point on the curve. Instead this searches for the plateau value
    that makes log|y - plateau| most linear in time, which is what a genuine
    single exponential does regardless of how far the clip runs.
    """
    d = np.abs(np.diff(y))
    onset = int(np.argmax(d)) + 1

    t_rel = t[onset:] - t[onset]
    y_seg = y[onset:]

    lo, hi = float(y_seg.min()), float(y_seg.max())
    pad = max(0.05 * (hi - lo), 1e-3)
    lo, hi = lo - pad, hi + pad

    best = (-np.inf, np.nan, np.nan)  # r_squared, slope, plateau
    for _ in range(40):
        candidates = np.linspace(lo, hi, 25)
        for plateau in candidates:
            r_squared, slope = _log_linear_fit(t_rel, y_seg - plateau)
            if r_squared > best[0]:
                best = (r_squared, slope, plateau)
        # zoom in around the current best for the next pass
        span = (hi - lo) / 24.0 * 2.0
        lo, hi = best[2] - span, best[2] + span

    r_squared, slope, plateau = best
    tau = -1.0 / slope if slope < 0 else float("nan")
    return tau, float(plateau), float(r_squared)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("frames", type=Path, help="Directory of extracted frame PNGs")
    parser.add_argument("--fps", type=float, required=True, help="Frame extraction rate")
    parser.add_argument("--min-ev", type=float, default=-10.0, help="Meter Floor (EV) used in the shader")
    parser.add_argument("--max-ev", type=float, default=2.0, help="Meter Ceiling (EV) used in the shader")
    parser.add_argument("--bar-height", type=float, default=0.05, help="Bar Height used in the shader")
    parser.add_argument("--bar-position", choices=["bottom", "top"], default="bottom")
    parser.add_argument("--swatch-frac", type=float, default=0.03, help="Calibration swatch width, matches the shader's SWATCH_FRAC")
    parser.add_argument("--csv", type=Path, help="Write the decoded time series here")
    args = parser.parse_args()

    paths = sorted(args.frames.glob("*.png"))
    if len(paths) < 10:
        raise SystemExit(f"found {len(paths)} frames in {args.frames}, need at least 10")

    fracs = np.array(
        [
            read_bar_fraction(p, args.bar_height, args.bar_position, args.swatch_frac)
            for p in paths
        ]
    )
    ev = args.min_ev + fracs * (args.max_ev - args.min_ev)
    luma = 2.0**ev
    t = np.arange(len(paths)) / args.fps

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["frame", "t", "ev", "luma"])
            for i, p in enumerate(paths):
                writer.writerow([p.name, f"{t[i]:.4f}", f"{ev[i]:.4f}", f"{luma[i]:.6f}"])
        print(f"wrote {args.csv}")

    tau_ev, plateau_ev, r2_ev = fit_exponential(t, ev)
    tau_lin, plateau_lin, r2_lin = fit_exponential(t, luma)

    print(f"{len(paths)} frames at {args.fps} fps, {t[-1]:.2f}s total")
    print(f"EV domain:     tau={tau_ev:.3f}s  plateau={plateau_ev:.2f}EV  r2={r2_ev:.4f}")
    print(f"linear domain: tau={tau_lin:.3f}s  plateau={plateau_lin:.4f}  r2={r2_lin:.4f}")

    better = "EV" if r2_ev >= r2_lin else "linear"
    tau_best = tau_ev if better == "EV" else tau_lin
    print(f"best fit: {better} domain, tau={tau_best:.3f}s")
    print("tau is time to reach 63% of the transition; 3*tau reaches about 95%.")


if __name__ == "__main__":
    main()
