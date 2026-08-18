# dz-shaders

A collection of ReShade shaders I've put together over time. Some are general-purpose tools, some started as a specific question I had about how an effect actually works at the implementation level. The shaders live in the `dz-shaders/Shaders/` directory and depend only on `ReShade.fxh` unless noted otherwise.

All shaders require ReShade 6.x unless stated otherwise.

## Shaders

### MipScope

**File:** `Shaders/MipScope.fx`

A debug and visualization shader for inspecting mipmapped luminance textures.

Many eye adaptation and auto-exposure shaders estimate scene brightness by sampling high mip levels of a luminance texture. The mip you pick changes the result a lot, but it's hard to see what any given level actually contains or how much detail survives there.

MipScope keeps five luminance textures at different resolutions (full res, 512×512, 256×256, 128×128, 64×64), each with a full mip chain. The smaller ones are built by box-downsampling the chain rather than point-sampling the screen, so they show what a real downsampled luma texture looks like instead of an aliased subsample. The full-res chain length comes from your actual screen size, so the tool reports the true mip count — 11 at 1080p, 12 at 1440p and 4K. You can switch textures, step through levels, and watch how sampling behaviour changes across the chain.

**Requires:** `ReShade.fxh` only. No additional shader packs needed.

#### Modes

**Mode 0: Fullscreen Mip View**

Stretches the selected mip to fill the screen. Useful for judging how much detail is left at a given level, and whether letterbox bars, a dark sidebar or a bright corner are still affecting the sampled result.

**Mode 1: Mip Chain Grid**

Shows every mip at once in a 4-column grid starting from mip 0. The selected one gets a blue tint so you can tell which cell you're looking at. Ask for a level the texture doesn't have and the last valid cell highlights instead, because that's what the GPU is really reading.

**Mode 2: Sample Region Overlay**

Shows the scene in grayscale with a yellow rectangle marking the screen region the sampled texel covers. The box snaps to the real texel grid at the selected mip — it finds which texel your Sample UV lands in and outlines that texel's footprint, so the overlay sits on actual texel boundaries rather than just centring on the cursor.

The last valid mip of any texture is 1×1, so that single sample represents the whole image. Ask for anything beyond it and the GPU clamps there anyway, so the region stays at 100%. That's correct — it's exactly what a real adaptation shader does when it over-requests. (Texel sizes come from standard box-filter dimensions, so on non-power-of-two textures the driver's footprint may differ by a fraction of a texel, but it's close.)

**Mode 3: Luminance Heatmap**

Maps luminance to false colour. Rainbow runs blue (dark) through green to red (bright). Grayscale is a plain black-to-white ramp, which is often easier to read when comparing levels side by side.

#### Settings

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

Declaring `MipLevels = N` in a ReShade texture gives you N levels, indexed 0 through N-1. The last is always 1×1 — one value standing for the entire image, and where most adaptation shaders read their global average.

Sample a mip index that doesn't exist and the GPU clamps to the last valid one. A shader declaring `MipLevels = 8` and sampling mip 8 is really reading mip 7. The mip slider deliberately allows out-of-range values so you can watch that clamping happen.

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

Isolates blood-colored pixels and subtly desaturates the rest of the scene to make blood more visually prominent. Blood tones keep their original saturation while everything else is pushed toward grayscale by an adjustable amount.

Three stacked filters do the work: a hue gate centred on your chosen blood tone, a saturation gate to drop dull or muted reds, and a brightness gate to drop very dark shadows and bright highlights. Whatever passes all three counts as blood; the rest blends softly toward grayscale.

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
| Edge Softness | 0.10 | Width of the soft ramp on the saturation and highlight gates. Lower values give crisper, harder isolation edges; higher values feather the transition so blood blends more gradually into the desaturated background. |
| Background Color Strength | 0.9 | How much color is retained in non-blood areas. 1.0 = fully original colors, 0.0 = completely grayscale. The default applies subtle desaturation so blood stands out without making the scene look stylized. |
| Background Brightness | 1.0 | Dims the non-blood areas of the scene. 1.0 = untouched. Lower values darken everything except blood, making blood read as brighter without touching its color. |
| Mask Smoothing | 0.0 | Blends the isolation mask with a small blur of itself to calm the shimmer noisy or compressed red pixels cause in motion. 0.0 = off (sharpest). Higher values are steadier but soften the blood edges slightly. |
| Blood Color Intensity | 1.2 | Multiplies the saturation of isolated blood pixels. 1.0 = natural saturation. Above 1.0 makes blood more vivid than the original image (up to 2.0 = double saturation). Below 1.0 pulls blood toward gray. Fully independent of Background Color Strength. |
| Show Debug Mask | off | Displays the isolation mask as white pixels against a black background. Useful for visualizing which pixels are being detected as blood and adjusting the three gates (hue, saturation, brightness) to dial in coverage. |

#### Tuning for a specific game

The defaults are calibrated for Mortal Kombat 1. For other games:

1. Find a scene with blood clearly visible on a neutral surface — floor, concrete, or bare skin work well.
2. **Blood Tone** — if blood looks distinctly orange-red (dried, older games) nudge right. If it looks dark crimson or pooled, nudge left. Leave at center for standard bright red.
3. **Detection Range** — this is the most important slider for coverage. If only a thin slice of blood is lighting up and neighboring pixels are not catching, raise it. If non-blood reds start triggering, lower it slightly. The default (0.08, ~29 degrees) covers most realistic blood palettes.
4. **Shadow Cutoff** — lower slightly if blood pooling in dark shadows is not being picked up. The default (0.01) is already very permissive.
5. **Highlight Cutoff** — lower if fire, UI elements, or environmental reds are bleeding into the effect. Raise if blood on bright surfaces (white fabric, lit floors) is getting cut out.
6. **Blood Saturation Threshold** — raise if non-blood reds like rust, worn cloth, or red armor are being highlighted. Lower if blood looks faded or is only partially colored.
7. **Background Color Strength** — adjust to taste. Lower values increase the contrast between blood and everything else at the cost of a more stylized look.
8. **Blood Color Intensity** — leave at 1.0 unless you want to soften the effect and blend blood partway back toward the desaturated background.

---

### PHDR Plus

**File:** `Shaders/PHDRPlus.fx`

A perceptual HDR shader that tries to restore depth and dynamic range on an ordinary LDR monitor. It isn't true HDR — it reads per-pixel luminance, computes a scene average through eye adaptation, then fuses several virtual exposures to lift shadow detail and recover highlight structure at once.

The core technique comes from BarbatosBachiko's PHDR: Weighted Least Squares smoothing for base layer extraction, Selective Reflectance Scaling to amplify the log-luminance ratio for pixels above the scene mean, Virtual Illumination Generation across five exposure points, and a weighted fusion back into one output. The result reads as having more depth than the input without obvious tone mapping artifacts.

PHDR Plus adds ten things on top of that foundation.

Per-zone tonal adaptation. The original does no per-pixel brightening or darkening beyond the fusion; exposure only feeds the tone mapping. Six Lift and Pull sliders now set how hard highlights, midtones and shadows are brightened in dark scenes and suppressed in bright ones, working the same under eye adaptation or manual exposure. All six default to 1.0 — neutral, identical to the original — with above 1.0 amplifying a zone and below suppressing it. The standard 4.0 midtone coefficient keeps all three responding proportionally to the same slider travel.

Adaptive split toning. Pixels measurably brighter than the scene average take a warm tint (yellow through orange to amber); those below a shadow threshold take a cool one (cyan through blue to indigo). Both are masked by local contrast ratio against the scene mean rather than absolute brightness, so the effect tracks the environment instead of clipping at fixed luma values. Tint strength can scale with INTENSITY, which also fades it with the Dark Scene Fade and drops it entirely when the shader is dialled back.

Configurable luma texture resolution and trigger radius. The internal luminance texture runs at full resolution or downscales to 512×512, 256×256, 128×128 or 64×64 — smaller ones collapse their mip chains sooner and cost less. Trigger Radius picks which mip feeds the scene average: low values weight a central region, high values approach a full-frame average.

A more stable, eye-like adaptation model. Scene brightness is a geometric (log) mean rather than a plain average, so a torch, a muzzle flash or a patch of sky can't drag the exposure around — the metric follows overall tonal balance. Adaptation uses continuous exponential decay, making its speed frame rate independent, and its time constant is asymmetric: the eye brightens quickly but dark-adapts slowly, so darkening eases in more gradually by a configurable multiplier.

The asymmetry runs in two stages. A short symmetric pre-filter cleans the measurement, and only that clean signal reaches the asymmetric stage. This matters more than it sounds: a fast-up, slow-down filter fed a flickering signal creeps upward, and next to a campfire it'll sit about ten percent brighter than the scene really is. Direction of travel fades across a small deadband rather than a hard comparison, so ordinary frame-to-frame movement doesn't flip the time constant back and forth. A floor and ceiling on the measurement stop a fade-to-black or a white flash from railing the adaptation and slamming the tonal curves.

Simultaneous contrast masking. A microscopic dark halo around bright highlights, made by slightly deepening pixels on the shadow side of an edge. That exploits the eye's own contrast enhancement — the Chevreul illusion — so bright areas read as more luminous without getting brighter. Unlike a standard clarity filter the mask comes from the smoothed base layer, which keeps it spatially aware and blind to high-frequency noise. It's gated on local base brightness so it only forms next to genuinely bright regions instead of etching texture in flat shadows, and it scales with INTENSITY so it fades with the main effect.

Configurable Purkinje adaptation. In dark scenes it simulates the shift from photopic to scotopic vision by cutting red sensitivity and adding a subtle blue-green bias to shadows. Red reduction, green bias, blue bias, the brightness below which it runs at full strength and the brightness above which it switches off are all exposed, so it tunes from a light nudge to a strong low-light simulation.

Multi-scale local contrast. The original guided filter extracts one base layer, limiting local contrast work to a single spatial frequency. This splits it into three: Micro for fine texture and edge definition, Medium for object-level structure, Macro for large-scale depth. The bands don't overlap, so each slider owns a distinct range. Base layers come from a fast guided filter that derives coefficients at low resolution and upsamples them, keeping strong edges free of the halos naive upsampling produces. Each scale reads its taps from the mip matching their spacing, so a wide window averages the pixels it covers instead of point-sampling a sparse comb that would alias and shimmer in motion.

Adaptive triangular dithering. SDR displays and 8-bit pipelines band visibly when exposure, local contrast or colour volume are pushed hard. The pattern is interleaved gradient noise, whose values are spread evenly across any small neighbourhood instead of merely being random, so it vanishes into a gradient rather than clumping into speckle. Each sample is then reshaped from a flat distribution into a triangular one two quantisation steps wide. That second part is what actually kills a band: flat noise one step wide decorrelates the average error but not its variance, so the amount of grain still rises and falls with the signal and the band survives as a change in texture instead of a hard edge. A triangular spread steadies the noise floor across the whole gradient, which is the same reasoning behind triangular dither in audio mastering. The reshape is a monotonic remap of a single sample rather than a sum of two, since summing averages two lookups together and throws away the spatial arrangement that made the pattern worth using.

Every channel gets its own pattern, so a coloured gradient can't band in one channel while the others stay smooth, and a mask on the screen-space slope keeps the noise in flat regions and out of texture and edges. The pattern scrolls each frame so it reads as fine grain rather than a fixed overlay, amplitude is measured in the real output step (8- or 10-bit) rather than assuming 8-bit, and a Dither Strength slider scales it. A debug view shows exactly what's being applied, mask included.

At the default strength of 1.0 the grain is meant to be invisible on its own — that's the point of getting the amplitude right, and the thing to check is whether the bands are gone, not whether you can see noise. Raise it if you want the grain itself.

The pattern itself can come from either of two sources. Blue Noise Mask, the default, reads a stored spatiotemporal mask generated by `tools/make_stbn.py` — void-and-cluster in three dimensions, with an independent volume in each of red, green and blue so one fetch feeds all three channels. Clumping is what makes a dither pattern read as a pattern, and measured against the alternative this one carries about a twentieth of the low-frequency energy, holds its per-frame average about five times steadier, and converges twice as fast when successive frames are averaged. In practice that means it hides better at the same amplitude and settles instead of crawling when the camera holds still. It needs `dz_stbn_512x256.png` in the ReShade Textures folder, which ships in this repo.

Gradient Noise is computed on the spot and needs nothing on disk. It's a good pattern in its own right and costs nothing to carry, so it's there to fall back to if the mask isn't where ReShade can find it.

Debanding. Dithering keeps a smooth gradient from banding on the way to the display, but it can do nothing about a gradient that is already stepped. Debanding is the other half. A band is a run of pixels that should have differed slightly and instead all landed on the same level, and the value they should have had is still recoverable from the surrounding area, because that area still carries the gradient — average a wide enough neighbourhood and the average lands between the levels, which is where the pixel belonged.

Knowing when not to do that is the whole difficulty, and it's where debanders lose detail. Two of the three tests here are the familiar pair: the neighbourhood average has to sit close to the pixel, which holds across a flat step and fails at an edge, and the samples have to agree with each other, which holds on a gradient and fails in loud texture. Both are graded rather than pass/fail, so the repair fades in and out instead of switching and leaving blotches along the boundary. Samples are spread evenly over a disc by golden-angle rotation rather than placed on a ring, and the disc is turned by a different angle at every pixel and on every frame. More samples make the second test worth trusting — judging how much a neighbourhood scatters from four points is close to guesswork — so the count runs from 8 to 32 over one to four passes that reach further and judge more strictly as they go.

The third test is the one that matters, because the first two share a blind spot that every debander built on this shape has: they both ask how *far apart* values are, and quiet texture is not far apart, so it reads exactly like a band and gets flattened. That's the mechanism behind debanding softening detail, and no amount of extra sampling fixes it, because the criterion is what's wrong rather than the estimate. The third test asks how *often* the value changes instead. Inside a band neighbouring pixels are identical — that is what makes it a band — while texture changes from one pixel to the next however faint it is overall. Measuring pixel-to-pixel variation separates the two on a property they genuinely differ on. It reads the incoming frame rather than the tone-mapped one, since the question is whether there was detail there before the shader touched it. The Detail Guard slider sets where the line falls, in quantisation steps.

All three tests read the incoming frame, and only the repair itself is taken from the tone-mapped one, because deciding and reconstructing are different questions. Whether a pixel sits in a band is a question about the frame as it arrived, and it's exact there: steps are genuinely one step apart and a band is genuinely piecewise-constant. After the tone fusion, local gain has stretched those steps by an amount that varies across the picture, so a threshold quoted in steps means nothing fixed any more. What to replace the pixel *with*, on the other hand, has to be answered in output space, since that's where the value has to land between levels. So each sample reads both images — the source decides, the output supplies the answer.

The frame is then split in two and each half gets its own settings, both running every frame. Alpha out of the combine pass records how far the shader moved each pixel, and the Split Point sets the line. On one side are pixels the tone fusion reworked, where any banding is the shader's own mess; on the other are pixels it left close to how it found them, where both the banding and the texture were there beforehand, so the detail at risk is detail that looked correct before the shader was ever enabled. The handover is a crossfade rather than a hard edge, and either half can be switched off on its own. Sample count is shared, since it trades cost against how well the neighbourhood is measured rather than changing the look.

One limit applies to both halves and matters more than any of the thresholds: the Correction Limit caps how far a pixel may be moved, in output steps. A band is a step or two tall, so that's the size of correction it takes — anything much larger isn't flattening a step, it's averaging away contrast that belongs in the picture. Without a cap, a wide search radius over an area the tone fusion has just added local contrast to will happily average that contrast straight back out, which quietly undoes the effect the shader is there to produce. With it, the debander can remove the step and nothing else, however far it searches. The cap eases in rather than clipping, so corrections below half of it pass through untouched and larger ones bend toward the limit without putting an edge where it starts to bite.

Dynamic intensity. Very dark scenes have little range left to recover, and running the fusion at full strength there mostly amplifies compression noise and crushed shadows, so it fades out as measured brightness drops below a threshold. An amount slider sets how much of the fade applies, a threshold slider the brightness at which it has fully released; the default is a gentle half-strength fade, and zero holds full intensity at any brightness.

The ramp starts at the Adaptation Floor rather than at black, since the floor would otherwise clip the bottom off it and the fade would never fully arrive. A minimum width stops a threshold set near the floor from squeezing the transition into a couple of hundredths and turning it into a step.

Underneath all of it the boosted result is soft-clipped in a hue-preserving way: when the fusion pushes a saturated highlight past display maximum, all three channels scale down together, so it desaturates cleanly toward white instead of clipping one channel at a time and shifting hue.

The shader is self-contained and needs no external headers.

**Requires:** `ReShade.fxh` only, plus `Textures/dz_stbn_512x256.png` from this repo. Copy that file into your ReShade `Textures` folder along with the shader — ReShade will complain about the missing texture if it isn't there, and since Blue Noise Mask is the default dither pattern, dithering will misbehave until you either copy the file in or switch Dither Pattern to Gradient Noise. No additional shader packs needed.

#### Settings

| Setting                        | Default         | What it does                                                                                                                                            |
| ------------------------------ | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| INTENSITY                      | 0.3             | Overall blend strength between the original frame and the tone-mapped result. 0.0 = no effect.                                                          |
| Dark Scene Fade                | 0.5             | Fades the tone fusion out in very dark scenes to avoid amplifying compression noise. 0.0 = off (full intensity everywhere), 1.0 = full fade.            |
| Dark Scene Fade Threshold      | 0.15            | Scene brightness at which the Dark Scene Fade has fully released. The effect ramps smoothly from the Adaptation Floor up to this value, and the ramp is held to a minimum width so it always stays gradual. |
| Smoothing Radius               | 15.0            | Controls the window size for the guided filter base layer smoothing. Larger values separate coarser structure from detail.                              |
| Edge Sensitivity               | 0.001           | Epsilon in the guided filter variance calculation. Lower values preserve more edges in the base layer; higher values smooth across them.                |
| Micro Contrast Boost           | 0.0             | Amplifies or suppresses fine-scale texture detail and high-frequency local contrast.                                                                    |
| Medium Contrast Boost          | 0.0             | Amplifies or suppresses medium-scale object contrast and structural detail.                                                                             |
| Macro Contrast Boost           | 0.0             | Adds large-scale depth contrast and scene separation back into the image. Unlike the other two this one starts at 0 rather than centring there — see the note below. |
| Contrast Shadow Strength       | 1.0             | Intensity of the microscopic dark halo around bright highlights, read as a fraction of INTENSITY. Higher values increase perceived edge contrast without sharpening artifacts. |
| Enable Dithering               | on              | Enables adaptive triangular dithering, per channel, to reduce visible SDR gradient banding.                                                             |
| Dither Strength                | 1.0             | Dither amplitude in output quantisation steps. 1.0 is the amount the maths asks for and is meant to be invisible on its own; raise it for visible grain. |
| Dither Pattern                 | Blue Noise Mask | Where the pattern comes from. The mask is spread far more evenly and settles rather than crawling, but needs the texture copied in. Gradient Noise needs no files and is the fallback. |
| Enable Debanding               | on              | Master switch. Rebuilds gradients that have been quantised into visible steps.                                                                           |
| Deband Correction Limit        | 2.0             | The furthest any pixel may be moved, in output steps. Keeps a repair from becoming a blur, and stops a wide search from averaging away the local contrast the shader just added. |
| Deband Split Point             | 1.0             | How far the shader must have moved a pixel, in steps, before it is handed to the Shader Effect settings rather than the Source Image ones.                |
| Deband Samples                 | 16 samples      | Samples per pass, spread over a disc, shared by both halves. This is what separates a repair from a blur — raise it before raising either threshold.     |
| Shader Effect: Enable          | on              | Debanding for pixels the shader reworked. Steps here are ones it opened up.                                                                              |
| Shader Effect: Threshold       | 1.75            | How far a pixel may sit from its surroundings and still count as flat, in steps of the incoming frame.                                                   |
| Shader Effect: Radius          | 14.0            | How far the first pass looks, in pixels; later passes reach further. Wants to be wider than the bands themselves.                                        |
| Shader Effect: Passes          | 2               | How many times to repeat, each reaching further and judging more strictly.                                                                               |
| Shader Effect: Detail Guard    | 1.0             | Pixel-to-pixel variation that marks an area as texture and puts it out of reach, in steps. The test that tells a band from fine detail.                   |
| Source Image: Enable           | on              | Debanding for pixels the shader barely moved. Both the banding and the texture here predate the shader, so it treads lightly.                             |
| Source Image: Threshold        | 1.5             | As above, but for the untouched half. Only acts on unmistakable steps.                                                                                   |
| Source Image: Radius           | 12.0            | As above, but for the untouched half.                                                                                                                    |
| Source Image: Passes           | 1               | As above, but for the untouched half.                                                                                                                    |
| Source Image: Detail Guard     | 0.75            | Stricter than the Shader Effect side, because the texture at risk here is texture the shader had no hand in. Lower it further if detail is flattened.     |
| Debug: Visualize Debanding     | off             | Shows what the debander moved, amplified. Black means untouched.                                                                                        |
| Enable Eye Adaptation          | on              | When enabled, scene brightness is measured each frame and used to drive the tone mapping. When disabled, Manual Exposure is used as a fixed scene mean. |
| Eye Adaptation Speed           | 0.5             | Smoothing time in seconds when the scene gets brighter (light adaptation). Higher values produce slower, more cinematic transitions.                    |
| Dark Adaptation Multiplier     | 2.5             | Multiplies the adaptation time when the scene gets darker, so darkening eases in more slowly than brightening. 1.0 = symmetric, 2–4 is realistic.       |
| Adaptation Floor               | 0.03            | Lower clamp on the measured scene brightness. Stops a fade-to-black or a wall of shadow from dragging the exposure to the floor. Raising it past the Tonal Neutral Point leaves the Lift sliders inert. |
| Adaptation Ceiling             | 0.85            | Upper clamp on the measured scene brightness. Stops a white flash from railing the exposure and crushing the scene dark afterwards. Lowering it below the Tonal Neutral Point leaves the Pull sliders inert. |
| Manual Exposure                | 0.1             | Fixed scene mean when eye adaptation is disabled. Lower values preserve darker scenes.                                                                  |
| Eye Adaptation Strength        | 1.0             | Scales the adaptation correction. 0.0 = adaptation is measured but ignored, 1.0 = full correction.                                                      |
| Luma Texture Size              | Full Resolution | Resolution of the internal luminance texture used for eye adaptation. Lower resolutions are cheaper and collapse to a whole-image average sooner.       |
| Adaptation Trigger Radius      | 8.0             | Mip level sampled from the luminance texture to estimate average scene brightness. Higher values cover more of the screen.                              |
| Tonal Neutral Point            | 0.30            | Scene brightness treated as "average", where neither Lift nor Pull does anything. Below it the Lift sliders apply, above it the Pull sliders apply. Governs both groups, and wants to sit inside the Adaptation Floor and Ceiling. |
| Highlight Lift                 | 1.0             | Highlight recovery strength when the scene is darker than average. 1.0 = neutral. Values above 1.0 amplify brightening; values below 1.0 suppress it.   |
| Midtone Lift                   | 1.0             | Midtone recovery strength when the scene is darker than average. Uses the same scale as Highlight Lift.                                                 |
| Shadow Lift                    | 1.0             | Shadow recovery strength when the scene is darker than average. Lower values preserve deeper blacks.                                                    |
| Highlight Pull                 | 1.0             | Highlight suppression strength when the scene is brighter than average. Values above 1.0 darken highlights more aggressively.                           |
| Midtone Pull                   | 1.0             | Midtone suppression strength when the scene is brighter than average.                                                                                   |
| Shadow Pull                    | 1.0             | Shadow suppression strength when the scene is brighter than average.                                                                                   |
| Enable Split Toning            | on              | Toggles adaptive warm highlight tinting and cool shadow tinting.                                                                                        |
| Scale Tints with INTENSITY     | on              | When enabled, tint strength scales with INTENSITY and fades with the Dark Scene Fade.                                                                   |
| Highlight Tint Tone            | 0.5             | Hue of the warm highlight tint. 0.0 = golden yellow, 0.5 = warm orange, 1.0 = deep amber.                                                               |
| Shadow Tint Tone               | 0.5             | Hue of the cool shadow tint. 0.0 = cyan/teal, 0.5 = cool blue, 1.0 = deep indigo.                                                                       |
| Highlight Tint Base Intensity  | 0.15            | Maximum opacity of the warm tint at the strongest contrast ratio.                                                                                       |
| Shadow Tint Base Intensity     | 0.08            | Maximum opacity of the cool tint at the strongest contrast ratio.                                                                                       |
| Highlight Contrast Threshold   | 1.25            | How much brighter than the scene average a pixel must be before the warm tint is applied.                                                               |
| Shadow Contrast Threshold      | 0.70            | How much darker than the scene average a pixel must be before the cool tint is applied.                                                                 |
| Enable Purkinje Effect         | on              | Simulates the Purkinje shift by reducing red sensitivity and introducing a subtle blue-green bias in dark scenes.                                       |
| Purkinje Red Reduction         | 0.10            | Controls the strength of red sensitivity reduction in dark scenes.                                                                                      |
| Purkinje Green Bias            | 0.010           | Controls the strength of the green bias introduced by the Purkinje effect.                                                                              |
| Purkinje Blue Bias             | 0.012           | Controls the strength of the blue bias introduced by the Purkinje effect.                                                                               |
| Purkinje Fade-Out End          | 0.20            | Scene brightness above which the Purkinje effect is completely disabled.                                                                                |
| Purkinje Fade-Out Start        | 0.05            | Scene brightness below which the Purkinje effect operates at full strength.                                                                             |
| Debug: Visualize Contrast Mask | off             | Displays the simultaneous contrast mask used to generate the microscopic dark halo around highlights.                                                   |
| Debug: Visualize Dithering     | off             | Displays the actual adaptive dithering contribution being injected into the final image.                                                                |

#### Notes on the Lift and Pull sliders

All six are neutral at their defaults, so loading the shader unadjusted gives output identical to the original PHDR. They're for deliberate tuning, not preset-style defaults. In consistently dark games, push Highlight Lift and Shadow Lift above 1.0 together to deepen shadowed regions. In bright outdoor scenes, Highlight Pull above 1.0 recovers the sensation of blown highlights without haze, and Shadow Pull below 1.0 resists darkening if you want to keep the shadow detail the fusion already found.

Which group runs depends on the **Tonal Neutral Point**: scenes darker than it use Lift, brighter use Pull. It defaults to 0.30 rather than the midpoint because scene brightness is a geometric mean in gamma space, which reads well below 0.5 even outdoors — a 0.5 pivot would leave Pull effectively unreachable.

How hard either group pushes depends on how far the scene sits from the pivot, measured in plain brightness over a fixed range identical above and below it. Moving the pivot away from your usual scene brightness therefore strengthens the response as well as choosing the group. Direction comes from the sliders alone: above 1.0 brightens, below darkens. Raise the pivot with Lift under 1.0 and a dark scene gets darker, not brighter — so if the image moves the wrong way, check which side of 1.0 the relevant sliders are on.

The pivot wants to sit comfortably inside the **Adaptation Floor** and **Adaptation Ceiling**, because those two cap what the scene metric can ever report. Park the pivot near the floor and a dark scene has barely any distance left to travel on the Lift side, so Lift only reaches a fraction of its response and needs a higher setting to push as hard; the same holds for Pull near the ceiling. Move the pivot past either clamp and that group stops acting altogether — with the floor at 0.30 and the pivot at 0.20, nothing can ever measure below average, and the three Lift sliders sit there doing nothing. It's consistent behaviour rather than a failure, but it's quiet about it, so it's worth checking the two clamps first if a group of sliders seems to have no effect.

Both sides share one response shape over one fixed range, so a Lift of 1.2 a tenth below neutral answers a Pull of 1.2 a tenth above it exactly, and moving the pivot slides that response along rather than stretching it. The shape is flat at the neutral point and flat again at full travel, so a scene crossing the pivot doesn't kick and the response steadies once a scene is properly dark or properly bright — where scenes spend most of their time. That's what stops a slight shift in a dark scene producing a sudden jump.

The tonal delta is weight-limited so the curve can't fold back on itself. Opposed settings, like a crushed Highlight Lift against a raised Shadow Lift, could otherwise tilt it steeply enough that a darker pixel comes out brighter than a lighter one. The limit derives from the slope, so it only engages when a combination would actually invert; at worst the curve goes flat.

#### Notes on the contrast sliders

**Macro Contrast Boost** runs 0 to 1 rather than -1 to 1 like Micro and Medium. The tone mapping divides coarse structure out of the reconstruction already, so 0 is the flat end of the range and the slider adds large-scale depth back on top. There's nothing below 0 to suppress — a negative gain would subtract past flat and invert the band, swapping which side of a large edge reads brighter.

**Contrast Shadow Strength** sets the intensity of the dark halos around bright objects. An internal scaling factor boosts subtle local detail for responsiveness and a hard ceiling stops edges going pitch black or producing harsh artifacts. It's read as a fraction of INTENSITY, so the halo fades with the main effect and with the Dark Scene Fade.

The shader also keeps the Purkinje effect and split toning from stacking in deep shadows, so shadow colour shifts stay natural instead of turning muddy.

---

## Installation

Copy the contents of `Shaders/` into your ReShade `Shaders` folder, and the contents of `Textures/` into your ReShade `Textures` folder. Enable shaders from the ReShade overlay. MipScope replaces the whole frame with debug visuals, so toggle it on only when inspecting and off when playing. BloodHighlight is designed to run during normal gameplay.

## Development note

AI assistance was used during the development of these shaders, for tasks such as reviewing the code, finding bugs, refining the implementation, and writing documentation. All changes were reviewed and tested before being included.

## License

MIT. Use, modify, and redistribute freely. Credit is appreciated but not required.
