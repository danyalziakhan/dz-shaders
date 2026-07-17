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
| Detection Range | 0.08 | Width of the hue window around the target. Small values are tight and precise; large values catch a broader band of reds and orange-reds. Raise if neighboring blood pixels are not being picked up. Lower if non-blood reds (rust, armor) are triggering. |
| Blood Saturation Threshold | 0.55 | Minimum color saturation a pixel must have to qualify as blood. Raise to exclude dull or faded reds (rust, worn cloth, dark brick). Lower if blood looks muted and is not being fully highlighted. |
| Shadow Cutoff | 0.01 | Pixels darker than this brightness are excluded. Keeps very dark shadows and near-black surfaces from being tagged as blood. The default is very permissive — only raise it if dark areas are incorrectly picking up. |
| Highlight Cutoff | 0.40 | Pixels brighter than this brightness are excluded. Prevents fire, glowing UI elements, and bright red surfaces from triggering. Lower if non-blood reds are slipping through. Raise if blood on bright surfaces is getting cut out. |
| Background Color Strength | 0.9 | How much color is retained in non-blood areas. 1.0 = fully original colors, 0.0 = completely grayscale. The default applies subtle desaturation so blood stands out without making the scene look stylized. |
| Blood Color Intensity | 1.2 | Multiplies the saturation of isolated blood pixels. 1.0 = natural saturation. Above 1.0 makes blood more vivid than the original image (up to 2.0 = double saturation). Below 1.0 pulls blood toward gray. Fully independent of Background Color Strength. |
| Show Debug Mask | off | Displays the isolation mask as white pixels against a black background. Useful for visualizing which pixels are being detected as blood and adjusting the three gates (hue, saturation, brightness) to dial in coverage. |

#### Tuning for a specific game

The defaults are calibrated for Mortal Kombat 1. For other games:

1. Find a scene with blood clearly visible on a neutral surface — floor, concrete, or bare skin work well.
2. **Blood Tone** — if blood looks distinctly orange-red (dried, older games) nudge right. If it looks dark crimson or pooled, nudge left. Leave at center for standard bright red.
3. **Detection Range** — this is the most important slider for coverage. If only a thin slice of blood is lighting up and neighboring pixels are not catching, raise it. If non-blood reds start triggering, lower it slightly. The default (0.08, ~29 degrees) covers most realistic blood palettes.
3. **Shadow Cutoff** — lower slightly if blood pooling in dark shadows is not being picked up. The default (0.01) is already very permissive.
4. **Highlight Cutoff** — lower if fire, UI elements, or environmental reds are bleeding into the effect. Raise if blood on bright surfaces (white fabric, lit floors) is getting cut out.
5. **Blood Saturation Threshold** — raise if non-blood reds like rust, worn cloth, or red armor are being highlighted. Lower if blood looks faded or is only partially colored.
6. **Background Color Strength** — adjust to taste. Lower values increase the contrast between blood and everything else at the cost of a more stylized look.
7. **Blood Color Intensity** — leave at 1.0 unless you want to soften the effect and blend blood partway back toward the desaturated background.

---

### PHDR2

**File:** `Shaders/PHDR2.fx`

A perceptual HDR shader that attempts to restore depth and dynamic range on standard LDR monitors. It's not true HDR - it works by analyzing per-pixel luminance, computing a scene average through eye adaptation, and applying a multi-exposure tone fusion across virtual illumination samples to lift shadow detail and recover highlight structure simultaneously.

The core technique comes from BarbatosBachiko's PHDR shader, which combines Weighted Least Squares smoothing for base layer extraction, Selective Reflectance Scaling to selectively amplify the log-luminance ratio for pixels above the scene mean, Virtual Illumination Generation across five virtual exposure points, and a weighted fusion of those samples back into a single output. The result is a frame that reads as having more perceived depth than the input without obvious tone mapping artifacts.

PHDR2 adds eight things on top of that foundation.

The first is per-zone tonal adaptation. The original PHDR applies no per-pixel brightening or darkening beyond the base fusion - the exposure logic only feeds the brightness level into the tone mapping calculation. PHDR2 exposes six Lift and Pull sliders that let you independently control how aggressively the shader brightens highlights, midtones, and shadows in dark scenes, and suppresses them in bright scenes. These controls function seamlessly whether dynamic eye adaptation is enabled or manual exposure is used. All six sliders default to 1.0, which is neutral and identical to the original PHDR output. Push above 1.0 to amplify the response in that zone, or pull below 1.0 to suppress it. The formula uses the standard 4.0 midtone coefficient so all three zones respond proportionally to the same slider travel.

The second is adaptive split toning. Pixels that are measurably brighter than the scene average receive a warm tint (yellow through orange to amber, adjustable). Pixels that fall below a shadow threshold receive a cool tint (cyan through blue to indigo). Both tints are masked by the local contrast ratio against the scene mean rather than absolute brightness, so the effect tracks the environment instead of clipping at fixed luma values. Tint strength can optionally scale with the main INTENSITY slider so it disappears completely when the shader is dialed back.

The third is configurable luma texture resolution and adaptation trigger radius. The internal luminance texture used for eye adaptation can be run at full resolution or downscaled to 512×512, 256×256, 128×128, or 64×64. Smaller textures collapse their mip chains sooner and are cheaper. The Trigger Radius slider selects which mip level is sampled for scene average computation. Lower values weight toward a central screen region, while higher values approach a full-frame average.

The fourth is mathematically true frame rate independent eye adaptation. It replaces standard linear interpolation with a continuous exponential decay formula, which ensures that eye adaptation speed remains perfectly identical whether the game runs at low or high frame rates.

The fifth is simultaneous contrast masking. This adds a microscopic dark halo around bright highlights by slightly deepening pixels on the shadow side of an edge. By selectively darkening the shadow boundary, it exploits the human eye’s natural contrast enhancement (the Chevreul illusion), making bright areas appear more luminous without increasing their actual brightness. Unlike standard clarity filters, it uses the smoothed `Base` layer for the mask, ensuring it is spatially aware and ignores high frequency noise.

The sixth is configurable Purkinje adaptation. In dark scenes, it simulates the shift from photopic to scotopic vision by reducing red sensitivity and introducing a subtle blue-green bias in shadow regions. The effect exposes separate controls for red reduction, green bias, blue bias, the scene brightness below which the effect operates at full strength, and the scene brightness above which it becomes fully disabled. This allows the effect to be tuned from a subtle perceptual enhancement to a stronger low-light vision simulation.

The seventh is multi-scale local contrast enhancement. The original guided filter extracts a single base layer, limiting local contrast manipulation to one spatial frequency. PHDR2 extends this into three independently adjustable scales: Micro, Medium, and Macro. Micro Contrast Boost affects fine texture detail and edge definition, Medium Contrast Boost influences object-level structure, and Macro Contrast Boost modifies large-scale depth relationships across the scene. Each scale can be amplified or suppressed independently, providing much finer control over perceived depth and dimensionality.

The eighth is adaptive interleaved gradient noise (IGN) dithering. SDR displays and 8-bit output pipelines can exhibit visible gradient banding when exposure, local contrast, or color volume are aggressively enhanced. PHDR2 can optionally inject a small amount of analytical interleaved gradient noise only into regions identified as being susceptible to banding. This helps preserve smooth gradients while avoiding unnecessary noise in detailed regions. A dedicated debug visualization is also included to display the exact dithering contribution being applied to the final image.

The shader is self-contained and has no dependency on external header files.

**Requires:** `ReShade.fxh` only. No additional shader packs needed.

#### Settings

| Setting                        | Default         | What it does                                                                                                                                            |
| ------------------------------ | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| INTENSITY                      | 0.3             | Overall blend strength between the original frame and the tone-mapped result. 0.0 = no effect.                                                          |
| Smoothing Radius               | 15.0            | Controls the window size for the guided filter base layer smoothing. Larger values separate coarser structure from detail.                              |
| Edge Sensitivity               | 0.001           | Epsilon in the guided filter variance calculation. Lower values preserve more edges in the base layer; higher values smooth across them.                |
| Micro Contrast Boost           | 0.0             | Amplifies or suppresses fine-scale texture detail and high-frequency local contrast.                                                                    |
| Medium Contrast Boost          | 0.0             | Amplifies or suppresses medium-scale object contrast and structural detail.                                                                             |
| Macro Contrast Boost           | 0.0             | Amplifies or suppresses large-scale depth contrast and scene separation.                                                                                |
| Contrast Shadow Strength       | 0.25            | Intensity of the microscopic dark halo around bright highlights. Higher values increase perceived edge contrast without sharpening artifacts.           |
| Enable Dithering               | on              | Enables adaptive interleaved gradient noise dithering to reduce visible SDR gradient banding.                                                           |
| Enable Eye Adaptation          | on              | When enabled, scene brightness is measured each frame and used to drive the tone mapping. When disabled, Manual Exposure is used as a fixed scene mean. |
| Eye Adaptation Speed           | 0.5             | Smoothing time in seconds for the moving average. Higher values produce slower and more cinematic adaptation transitions.                               |
| Manual Exposure                | 0.1             | Fixed scene mean when eye adaptation is disabled. Lower values preserve darker scenes.                                                                  |
| Eye Adaptation Strength        | 1.0             | Scales the adaptation correction. 0.0 = adaptation is measured but ignored, 1.0 = full correction.                                                      |
| Luma Texture Size              | Full Resolution | Resolution of the internal luminance texture used for eye adaptation. Lower resolutions are cheaper and collapse to a whole-image average sooner.       |
| Adaptation Trigger Radius      | 8.0             | Mip level sampled from the luminance texture to estimate average scene brightness. Higher values cover more of the screen.                              |
| Highlight Lift                 | 1.0             | Highlight recovery strength when the scene is darker than average. 1.0 = neutral. Values above 1.0 amplify brightening; values below 1.0 suppress it.   |
| Midtone Lift                   | 1.0             | Midtone recovery strength when the scene is darker than average. Uses the same scale as Highlight Lift.                                                 |
| Shadow Lift                    | 1.0             | Shadow recovery strength when the scene is darker than average. Lower values preserve deeper blacks.                                                    |
| Highlight Pull                 | 1.0             | Highlight suppression strength when the scene is brighter than average. Values above 1.0 darken highlights more aggressively.                           |
| Midtone Pull                   | 1.0             | Midtone suppression strength when the scene is brighter than average.                                                                                   |
| Shadow Pull                    | 1.0             | Shadow suppression strength when the scene is brighter than average.                                                                                    |
| Enable Split Toning            | on              | Toggles adaptive warm highlight tinting and cool shadow tinting.                                                                                        |
| Scale Tints with INTENSITY     | on              | When enabled, tint strength scales proportionally with the INTENSITY slider.                                                                            |
| Highlight Tint Tone            | 0.5             | Hue of the warm highlight tint. 0.0 = golden yellow, 0.5 = warm orange, 1.0 = deep amber.                                                               |
| Shadow Tint Tone               | 0.5             | Hue of the cool shadow tint. 0.0 = cyan/teal, 0.5 = cool blue, 1.0 = deep indigo.                                                                       |
| Highlight Tint Base Intensity  | 0.15            | Maximum opacity of the warm tint at the strongest contrast ratio.                                                                                       |
| Shadow Tint Base Intensity     | 0.08            | Maximum opacity of the cool tint at the strongest contrast ratio.                                                                                       |
| Highlight Contrast Threshold   | 1.25            | How much brighter than the scene average a pixel must be before the warm tint is applied.                                                               |
| Shadow Contrast Threshold      | 0.75            | How much darker than the scene average a pixel must be before the cool tint is applied.                                                                 |
| Enable Purkinje Effect         | on              | Simulates the Purkinje shift by reducing red sensitivity and introducing a subtle blue-green bias in dark scenes.                                       |
| Purkinje Red Reduction         | 0.10            | Controls the strength of red sensitivity reduction in dark scenes.                                                                                      |
| Purkinje Green Bias            | 0.010           | Controls the strength of the green bias introduced by the Purkinje effect.                                                                              |
| Purkinje Blue Bias             | 0.012           | Controls the strength of the blue bias introduced by the Purkinje effect.                                                                               |
| Purkinje Fade-Out End          | 0.30            | Scene brightness above which the Purkinje effect is completely disabled.                                                                                |
| Purkinje Fade-Out Start        | 0.05            | Scene brightness below which the Purkinje effect operates at full strength.                                                                             |
| Debug: Visualize Contrast Mask | off             | Displays the simultaneous contrast mask used to generate the microscopic dark halo around highlights.                                                   |
| Debug: Visualize Dithering     | off             | Displays the actual adaptive dithering contribution being injected into the final image.                                                                |


#### Notes on the Lift and Pull sliders

All six sliders are intentionally neutral at their default values. Loading the shader with no adjustments gives output identical to the original PHDR. The sliders are designed for deliberate tuning rather than preset-style defaults. Push Highlight Lift and Shadow Lift together above 1.0 in games with consistently dark imagery to increase perceived depth in the shadowed regions. In bright outdoor scenes, Highlight Pull above 1.0 helps recover the sensation of blown highlights without introducing haze. Shadow Pull below 1.0 resists darkening of shadow areas in those same bright scenes if you want to preserve the shadow detail the fusion already recovered.

The **Contrast Shadow Strength** slider controls the intensity of the microscopic dark halos around bright objects. An internal scaling factor boosts subtle local details for better responsiveness, a hard ceiling prevents edges from turning pitch black or creating harsh rendering artifacts.

The shader includes internal logic to prevent the Purkinje effect and Split Toning from stacking in deep shadows. This ensures that shadow color shifts remain natural, preventing muddy color profiles in dark scenes.

---

## Installation

Copy the contents of `Shaders/` into your ReShade `Shaders` folder. Enable shaders from the ReShade overlay. MipScope replaces the whole frame with debug visuals, so toggle it on only when inspecting and off when playing. BloodHighlight is designed to run during normal gameplay.

## License

MIT. Use, modify, and redistribute freely. Credit is appreciated but not required.