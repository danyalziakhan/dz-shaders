# dz-shaders

A collection of ReShade shaders I've put together over time. Some are general-purpose tools, some started as a specific question I had about how an effect actually works at the implementation level. The shaders live in the `dz-shaders/Shaders/` directory and depend only on `ReShade.fxh` unless noted otherwise.

All shaders require ReShade 6.x unless stated otherwise.

## Shaders

### MipScope

**File:** `Shaders/MipScope.fx`

A debug and visualization shader for inspecting mipmapped luminance textures.

Many eye adaptation and auto-exposure shaders estimate scene brightness by sampling high mip levels of a luminance texture. The selected mip level has a significant impact on the result, but it can be difficult to visualize what each mip actually contains or how much image detail remains at a given level.

MipScope maintains five luminance textures at different resolutions (full resolution, 512×512, 256×256, 128×128, and 64×64), each with a complete mip chain. You can switch between textures, inspect individual mip levels, and visualize how sampling behavior changes across the chain.

**Requires:** `ReShade.fxh` only. No additional shader packs needed.

#### Modes

**Mode 0: Fullscreen Mip View**

Stretches the selected mip level to fill the screen. Useful for determining how much detail remains at a given mip level and whether features such as letterbox bars, a dark sidebar, or a bright corner are still affecting the sampled result.

**Mode 1: Mip Chain Grid**

Shows all mip levels at once in a 4-column grid, starting from mip 0. The selected mip level gets a blue tint so you can see exactly which cell you're looking at. If you set a mip level that's beyond what the texture actually has, the last valid cell gets highlighted instead because that's what the GPU is actually reading when you ask for something that doesn't exist.

**Mode 2: Sample Region Overlay**

Shows the scene in grayscale with a yellow rectangle marking the approximate screen region that the sampled texel covers. The box size is `(2^mipLevel / textureSize)` per axis, centered on your Sample UV setting.

The last valid mip level of any texture is always 1 pixel by 1 pixel, so that single sample represents your entire image. If you ask for a mip beyond that, the GPU clamps it there anyway, so the region stays at 100%. This is the correct behavior, it's exactly what happens in a real adaptation shader that over-requests mip levels. (The calculation here is an approximation based on standard box filtering, so driver behavior might differ slightly with non-power-of-two textures, but it's close.)

**Mode 3: Luminance Heatmap**

Maps luminance values to a false-color gradient. Rainbow goes from blue (dark) through green to red (bright). Grayscale is a plain black-to-white ramp, which can be easier to read when you're comparing mip levels side by side.

#### Settings

These control what you see and how you navigate the visualization:

| Setting | What it does |
|---|---|
| Debug Mode | Which visualization to display (0-3) |
| Texture Size | Full resolution, 512×512, 256×256, 128×128, or 64×64 |
| Mip Level | The mip level to display. Values beyond the valid chain get clamped by the GPU to the last real level |
| Sample UV | The UV coordinate to mark and use for region coverage calculation (0.5, 0.5 is center) |
| Show Sample Point | Draw a green crosshair at the sample UV |
| Show Region Overlay | Display the yellow box showing texel coverage at the selected mip (Mode 2 only) |
| Heatmap Color Ramp | Grayscale (black to white) or Rainbow (blue to red) for Mode 3 |
| Grid: Highlight Selected Mip | In Mode 1, tint the current mip cell blue. If out of range, the last valid cell gets highlighted |
| Grid Cell Border | Border thickness between grid cells in Mode 1 |

#### Understanding the mip chain

When you declare `MipLevels = N` in a ReShade texture, you get N levels, indexed 0 through N-1. The last one is always 1 pixel by 1 pixel, a single value that represents your entire image. That's where most adaptation shaders read from when they want a global average.

If you ask the GPU to sample a mip index that doesn't exist, it just clamps to the last valid level. So a shader that declares `MipLevels = 8` and samples mip 8 is actually reading mip 7, the same 1 pixel by 1 pixel value it would get at index 7. The mip slider intentionally allows values beyond the valid chain so clamping behavior can be observed directly.

For reference, here's how many mip levels each preset naturally has:

| Texture Size | Mip Count | Valid Indices | Last Mip (1×1) at |
|---|---|---|---|
| Full res 1080p | 11 | 0-10 | mip 10 |
| Full res 1440p | 12 | 0-11 | mip 11 |
| 512 × 512 | 10 | 0-9 | mip 9 |
| 256 × 256 | 9 | 0-8 | mip 8 |
| 128 × 128 | 8 | 0-7 | mip 7 |
| 64 × 64 | 7 | 0-6 | mip 6 |

---

### BloodHighlight

**File:** `Shaders/BloodHighlight.fx`

Isolates blood-colored pixels and subtly desaturates the rest of the scene to make blood more visually prominent. Blood tones are kept at or near their original saturation while everything else is pushed toward grayscale by an adjustable amount.

The shader applies three stacked filters: a hue gate centered on your selected blood tone, a saturation gate to exclude dull or muted reds, and a brightness gate to exclude very dark shadows and bright highlights. Anything that passes all three is treated as blood; everything else is softly blended toward grayscale.

Designed and tuned for Mortal Kombat 1. Should work for any game that uses realistic blood tones.

**Requires:** `ReShade.fxh` only. No additional shader packs needed — all conversion code is self-contained.

#### Settings

| Setting | Default | What it does |
|---|---|---|
| Blood Tone | 0.5 | Shifts the hue target across the blood spectrum. Left (0.0) = dark crimson/pooled blood. Center (0.5) = pure red/typical bright blood. Right (1.0) = orange-red/dried or coagulated blood. Most games work fine at the default. |
| Blood Saturation Threshold | 0.55 | Minimum color saturation a pixel must have to qualify as blood. Raise to exclude dull or faded reds (rust, worn cloth, dark brick). Lower if blood looks muted and is not being fully highlighted. |
| Shadow Cutoff | 0.01 | Pixels darker than this brightness are excluded. Keeps very dark shadows and near-black surfaces from being tagged as blood. The default is very permissive — only raise it if dark areas are incorrectly picking up. |
| Highlight Cutoff | 0.40 | Pixels brighter than this brightness are excluded. Prevents fire, glowing UI elements, and bright red surfaces from triggering. Lower if non-blood reds are slipping through. Raise if blood on bright surfaces is getting cut out. |
| Background Color Strength | 0.9 | How much color is retained in non-blood areas. 1.0 = fully original colors, 0.0 = completely grayscale. The default applies subtle desaturation so blood stands out without making the scene look stylized. |
| Blood Color Intensity | 1.1 | Output strength of isolated blood pixels. 1.0 = full natural saturation. Above 1.0 boosts saturation beyond the original (up to 1.5). Lower values blend blood partway toward the desaturated background. |

#### Tuning for a specific game

The defaults are calibrated for Mortal Kombat 1. For other games:

1. Find a scene with blood clearly visible on a neutral surface — floor, concrete, or bare skin work well.
2. **Blood Tone** — if blood looks distinctly orange-red (dried, older games) nudge right. If it looks dark crimson or pooled, nudge left. Leave at center for standard bright red.
3. **Shadow Cutoff** — lower slightly if blood pooling in dark shadows is not being picked up. The default (0.01) is already very permissive.
4. **Highlight Cutoff** — lower if fire, UI elements, or environmental reds are bleeding into the effect. Raise if blood on bright surfaces (white fabric, lit floors) is getting cut out.
5. **Blood Saturation Threshold** — raise if non-blood reds like rust, worn cloth, or red armor are being highlighted. Lower if blood looks faded or is only partially colored.
6. **Background Color Strength** — adjust to taste. Lower values increase the contrast between blood and everything else at the cost of a more stylized look.
7. **Blood Color Intensity** — leave at 1.0 unless you want to soften the effect and blend blood partway back toward the desaturated background.

---

## Installation

Copy the contents of `Shaders/` into your ReShade `Shaders` folder. Enable shaders from the ReShade overlay. MipScope replaces the whole frame with debug visuals, so toggle it on only when inspecting and off when playing. BloodHighlight is designed to run during normal gameplay.

## License

MIT. Use, modify, and redistribute freely. Credit is appreciated but not required.