# dz-shaders

A collection of ReShade shaders I've put together over time. Some are general-purpose tools, some started as a specific question I had about how an effect actually works at the implementation level. They live in `Shaders/`, with the one texture they need in `Textures/`.

All shaders require ReShade 6.x unless stated otherwise.

## Installation

Copy the contents of `Shaders/` into your ReShade `Shaders` folder and the contents of `Textures/` into your ReShade `Textures` folder, then enable the effects from the ReShade overlay.

MipScope and BloodHighlight include `ReShade.fxh`, which isn't in this repo. The ReShade installer always installs it, with its Standard effects package, into `reshade-shaders\Shaders`. If you point ReShade's effect search path somewhere else instead, keep that folder on the path too or copy `ReShade.fxh` alongside these shaders. PHDR Plus needs no headers.

MipScope replaces the whole frame with debug views, so switch it on only while inspecting. The others are meant to run during play.

## Shaders

### PHDR Plus

**File:** `Shaders/PHDRPlus.fx`

A perceptual HDR shader that restores depth and dynamic range on an ordinary SDR monitor. It isn't true HDR. It measures a scene average through eye adaptation, then fuses several virtual exposures to lift shadow detail and recover highlight structure at once.

The core comes from BarbatosBachiko's PHDR, which took it from singleLDR2HDR: a smoothed base layer, Selective Reflectance Scaling of the log-luminance ratio above the scene mean, and a weighted fusion of five virtual exposures. What I've added:

**Three contrast bands.** The single base layer becomes three guided-filter scales, Micro, Medium and Macro, each with its own slider. The filter coefficients are worked out at low resolution and upsampled, which is the fast guided filter, and each tap reads the mip matching its own stride so a wide window doesn't alias.

**Per-zone tonal adaptation.** Six Lift and Pull sliders shape highlights, midtones and shadows, Lift in scenes darker than a pivot and Pull in brighter ones. The approach comes from brussell's EyeAdaption. All six are neutral at 1.0.

**A steadier adaptation model.** Scene brightness is a geometric mean, so a torch or a patch of sky can't drag the exposure around. A short symmetric pre-filter settles on the true mean before an asymmetric stage, quick to brighten and slow to dark-adapt, takes over. Run straight off a flickering measurement, the asymmetric stage creeps upward and sits about 10% high next to a campfire.

**Split toning and Purkinje.** Pixels well above the scene average take a warm tint and pixels well below take a cool one. In dark scenes the Purkinje shift moves shadows toward blue-green, and the cool tint gives way to it so the two don't stack into mud.

**Simultaneous contrast.** A dark halo on the shadow side of bright edges, which makes highlights read as brighter than they are. It is also the etched-outline look when overdone, so it has both a strength and a threshold.

**Debanding and dithering.** Dithering stops new banding forming; debanding repairs banding that's already there. The debander only acts where three tests agree: the neighbourhood average sits close to the pixel, the samples agree with each other, and the value doesn't change from one pixel to the next. The last one is what separates a band from quiet texture, since inside a band neighbouring pixels are identical. It runs twice with separate settings, Shader Effect for pixels the tone fusion reworked and Source Image for everything it left alone, crossfaded by how far each pixel moved. The dither is triangular and per channel, from a spatiotemporal blue noise mask (`tools/make_stbn.py`, shipped as `Textures/dz_stbn_512x256.png`) or from interleaved gradient noise if the texture is missing.

On an HDR swap chain the debanding and dithering settings disappear and those passes are compiled out. The frame is float at that point, so there's nothing to band against, and [HDR Bridge](https://github.com/danyalziakhan/hdrbridge) does both at the end of the chain for the 8-bit cut Windows makes.

The boosted colour is soft-clipped by scaling all three channels together, so a saturated highlight desaturates toward white instead of clipping one channel and shifting hue.

#### Settings

| Setting | Default | What it does |
|---|---|---|
| INTENSITY | 0.3 | Blend between the original frame and the result. 0 is no effect. Everything else scales with it. |
| Dark Scene Fade | 0.65 | Fades the tone fusion out in very dark scenes, where there's little range left to recover and it mostly amplifies noise. 0 is off. |
| Dark Scene Fade Threshold | 0.20 | Scene brightness at which the fade has fully released. The ramp starts at the Adaptation Floor. |
| Smoothing Radius | 13.5 | Window the base layers are smoothed over, in pixels at 1080p. Wider spreads the shading beside bright objects until it reads as lighting rather than an outline, but past about 20 the effect stops being local and turns into a global tone curve. Pick it by eye. |
| Edge Sensitivity | 0.001 | Guided filter epsilon. Raising it extracts more texture as detail and darkens the rim beside bright edges along with it. |
| Detail Limit | 0 | Ceiling on the detail term in stops, darkening side only. Buys back the dark rim around bright objects while lit surfaces keep their glow. 0 is off. |
| Micro Contrast Boost | 0 | Contrast at the finest scale. Above 0 this is what starts to look sharpened. |
| Medium Contrast Boost | 0 | Contrast at the scale of objects and their shading. The one to raise for depth. |
| Macro Contrast Boost | 0 | Large-scale depth. Runs 0 to 1, see below. |
| Macro Soft Area Guard | 0 | Holds Macro back in soft areas with no fine texture, such as clouds, haze and out of focus backgrounds, where it darkens whole patches into blotches. 0 is off. |
| Contrast Shadow Strength | 1.0 | Depth of the dark halo on the shadow side of bright edges, as a fraction of INTENSITY. Lower it if objects look drawn on. |
| Contrast Shadow Threshold | 0 | How much darker than its surroundings a pixel must be before the halo acts. Raise it if soft clouds or out of focus backgrounds turn grainy; real edges keep their halo. 0 is off. |
| Enable Dithering | on | Triangular dither, per channel. SDR swap chain only. |
| Dither Strength | 1.0 | Amplitude in output steps. 1.0 is what the maths asks for; raise it for visible grain. |
| Dither Pattern | Blue Noise Mask | The mask hides better at the same amplitude and settles rather than crawling. Gradient Noise needs no texture. |
| Enable Debanding | on | Master switch. SDR swap chain only. |
| Deband Correction Limit | 2.0 | Furthest a pixel may move, in steps. A band is a step or two tall, so a bigger correction is averaging away contrast. |
| Deband Split Point | 1.0 | How far the shader must have moved a pixel, in steps, before the Shader Effect settings take it over from the Source Image ones. |
| Deband Samples | 16 | Samples per pass. Raise this before loosening a threshold. |
| Shader Effect: Threshold / Radius / Passes / Detail Guard | 1.75 / 13 / 2 / 1.0 | Debanding for what the shader reworked. Threshold is how flat an area must be to count as a band, Radius how far the first pass looks in pixels at 1080p, Detail Guard how much pixel-to-pixel variation marks texture and puts it out of reach. |
| Source Image: Threshold / Radius / Passes / Detail Guard | 1.65 / 12 / 1 / 0.85 | The same for what it left alone. Gentler, because the texture at risk here is the game's own. |
| Enable Eye Adaptation | on | Off uses Manual Exposure as a fixed scene brightness. |
| Eye Adaptation Speed | 0.5 | Seconds to adjust when the scene gets brighter. |
| Dark Adaptation Multiplier | 2.5 | How much slower darkening is than brightening. |
| Adaptation Floor / Ceiling | 0.03 / 0.85 | Clamps on measured brightness, so a fade to black or a white flash can't rail the exposure. |
| Manual Exposure | 0.1 | Scene brightness assumed with adaptation off. |
| Eye Adaptation Strength | 1.0 | 0 measures but doesn't apply. |
| Luma Texture Size | Full Resolution | Smaller is cheaper and its mip chain collapses sooner. |
| Adaptation Trigger Radius | 8.0 | Mip sampled for scene brightness, at 1080p. Higher covers more of the screen. |
| Tonal Neutral Point | 0.30 | Scene brightness treated as average. Below it Lift applies, above it Pull. |
| Tonal Response Span | 1.5 | Stops from the pivot before Lift or Pull reaches full travel. |
| Highlight / Midtone / Shadow Lift | 1.0 | Tonal shaping in scenes darker than the pivot. |
| Highlight / Midtone / Shadow Pull | 1.0 | Tonal shaping in scenes brighter than the pivot. |
| Enable Split Toning | on | Warm highlights, cool shadows. |
| Highlight / Shadow Tint Tone | 0.5 / 0.5 | Hue, not amount. Highlight runs golden to deep amber, shadow teal to indigo. |
| Highlight / Shadow Tint Base Intensity | 0.15 / 0.08 | Amount of each tint. |
| Highlight / Shadow Contrast Threshold | 1.25 / 0.70 | How far above or below the scene average a pixel must sit to take its tint. |
| Enable Purkinje Effect | on | Blue-green shift in dark scenes. |
| Purkinje Red Reduction | 0.10 | Pulls red toward luminance. In a blue night scene red sits below luminance, so raising this lifts red and washes the shift out. Strengthen the effect with the two bias sliders instead. |
| Purkinje Green / Blue Bias | 0.010 / 0.012 | Strength of the shift. |
| Purkinje Fade-Out Start / End | 0.05 / 0.20 | Full strength below Start, gone above End. |
| Debug views | off | Contrast mask, dithering and debanding. |

#### Lift and Pull

All six are neutral at 1.0 and scale with INTENSITY, so INTENSITY 0 leaves the frame untouched wherever they sit. From tuning several games:

- **Midtone Lift** below 1.0 is the main night control. It cancels the brightening the fusion adds to dark scenes.
- **Shadow Lift** is what crushes dark corners. Leave it at 1.0.
- **Midtone Pull** above 1.0 darkens daylight midtones and widens the gap to white.
- **Highlight Pull** flattens the whites and eats the peak. Darken the midtones instead.

The **Tonal Neutral Point** decides which group runs. It defaults to 0.30 rather than 0.5 because scene brightness is a geometric mean in gamma space, which reads well below 0.5 even outdoors. How hard a group pushes depends on how far the scene sits from the pivot, counted in stops over the **Tonal Response Span**. Stops rather than plain brightness because the metric is a geometric mean: measured against a linear span, the same sliders acted more than seven times harder on a bright afternoon than on an overcast one.

Keep the pivot inside the **Adaptation Floor** and **Ceiling**, since those cap what the metric can report. With the floor at 0.30 and the pivot at 0.20 nothing ever measures below average and the three Lift sliders do nothing, quietly. Check the two clamps first if a group seems to have no effect.

The curve is limited so it can't fold back on itself. Opposed settings, a lowered Highlight Lift against a raised Shadow Lift for instance, could otherwise make a darker pixel come out brighter than a lighter one. At worst it goes flat.

#### Contrast

**Micro** acts close to the pixel grid, and raising it is what makes a frame look sharpened rather than deep. For depth, keep Micro at or below 0 and raise **Medium**.

**Macro** runs 0 to 1 rather than -1 to 1. It's a bare gain on the large-scale band, so 0 adds none and 1 passes the band at full strength. A negative value would invert the band and swap which side of a large edge reads brighter.

**Macro Soft Area Guard** and **Contrast Shadow Threshold** are both off by default and aimed at the same content: soft clouds and out of focus backgrounds. Macro darkens a soft patch as a block against the wider sky, and the halo turns the small noisy dips in a blurred area into dark grain. The guard reads whether the finest scale found any texture across the width macro acts over, so hills, rock and sea keep their macro contrast and no bright ring forms round a tree or statue against a night sky; the threshold is subtracted before the halo is drawn, so it grows from zero with no step and edges, which dip much further, keep it. Raise them if a preset leaves skies blotchy.

#### Resolution

Smoothing Radius, both deband radii and the metering mip are authored at 1080 lines and converted at the point of use, so a preset covers the same fraction of the picture on any monitor. The contrast bands take their scale from Smoothing Radius, and the tonal curves, tints and Purkinje work per pixel, so nothing else needs converting. The dither stays in output pixels on purpose, since it exists to break up the pixel grid.

A preset authored on a 1200 line screen before this is ported by dividing by 1200/1080: Radius 15 becomes 13.5, Deband Effect Radius 14 becomes 12.6 and Deband Source Radius 13 becomes 11.7. Trigger Radius is a mip index and shifts by `log2(1200/1080)` instead, 8 becoming 7.848. Edge Sensitivity doesn't scale.

#### HUD

With the [HUD Mask](https://github.com/danyalziakhan/hudmask) add-on installed, PHDR Plus leaves the game's HUD as the game drew it and keeps it out of the eye adaptation, so a bright compass or quest marker no longer moves the exposure. Without the add-on nothing changes. In an HDR game, HDR Bridge still tone maps the HUD, since it has to bring the HUD's brightness down to SDR like the rest of the frame.

---

### MipScope

**File:** `Shaders/MipScope.fx`

A debug shader for inspecting mipmapped luminance textures.

Many eye adaptation and auto-exposure shaders estimate scene brightness by sampling a high mip of a luminance texture. The mip you pick changes the result a lot, but it's hard to see what any given level actually contains or how much detail survives there.

MipScope keeps five luminance textures (full res, 512x512, 256x256, 128x128, 64x64), each with a full mip chain. The smaller ones are box-downsampled rather than point-sampled from the screen, so they show what a real downsampled luma texture looks like instead of an aliased subsample. The full-res chain is sized from your screen, so the tool reports the true mip count: 11 at 1080p, 12 at 1440p and 4K. You can switch textures, step through levels, and watch how sampling changes across the chain.

**Requires:** `ReShade.fxh`.

#### Modes

**Mode 0: Fullscreen Mip View.** Stretches the selected mip over the screen. Useful for judging how much detail is left at a level, and whether letterbox bars, a dark sidebar or a bright corner still affect the sampled result.

**Mode 1: Mip Chain Grid.** Every mip at once in a 4-column grid, the selected one tinted blue. Ask for a level the texture doesn't have and the last cell is tinted instead, because that's what the GPU really reads. Dark teal cells are unused slots in the grid.

**Mode 2: Sample Region Overlay.** The scene in grayscale with a rectangle over the screen region the sampled texel covers. The box snaps to the texel grid at the selected mip, outlining the texel your Sample UV lands in rather than centring on the cursor. The last mip of any texture is 1x1, so it covers the whole image, and anything past it is clamped there. That is exactly what a real adaptation shader gets when it over-requests. On non-power-of-two textures the driver's footprint may differ from the drawn box by a fraction of a texel.

**Mode 3: Luminance Heatmap.** Luminance in false colour. Rainbow runs blue through green to red; Grayscale is often easier when comparing levels.

#### Settings

| Setting | What it does |
|---|---|
| Debug Mode | Which view to show (0 to 3) |
| Texture Size | Full resolution, 512x512, 256x256, 128x128 or 64x64 |
| Mip Level | The mip to show. Values past the end of the chain are clamped by the GPU to the last level |
| Sample UV | The point to mark and to use for the region overlay (0.5, 0.5 is the centre) |
| Show Sample Point | Draw a crosshair at Sample UV |
| Show Region Overlay | Draw the texel footprint box (Mode 2 only) |
| Heatmap Color Ramp | Grayscale or Rainbow, for Mode 3 |
| Grid: Highlight Selected Mip | Tint the selected cell blue in Mode 1 |
| Grid Cell Border | Border thickness between grid cells in Mode 1 |

#### The mip chain

Declaring `MipLevels = N` in a ReShade texture gives N levels, indexed 0 to N-1. The last is 1x1, one value for the entire image, and it's where most adaptation shaders read their global average. Sample an index that doesn't exist and the GPU clamps to the last one: a shader declaring `MipLevels = 8` and sampling mip 8 is really reading mip 7. The Mip Level slider allows out-of-range values so you can watch that happen.

| Texture Size | Mip Count | Last Mip (1x1) |
|---|---|---|
| Full res 1080p | 11 | mip 10 |
| Full res 1440p or 4K | 12 | mip 11 |
| 512 x 512 | 10 | mip 9 |
| 256 x 256 | 9 | mip 8 |
| 128 x 128 | 8 | mip 7 |
| 64 x 64 | 7 | mip 6 |

---

### BloodHighlight

**File:** `Shaders/BloodHighlight.fx`

Keeps blood in full colour and desaturates the rest of the scene by an adjustable amount, so blood stands out without the frame turning black and white.

Three gates decide what counts as blood: hue near the chosen blood tone, enough saturation to drop dull reds, and brightness between a shadow and a highlight cutoff. Whatever passes all three keeps its colour; the rest blends softly toward grayscale.

Tuned for Mortal Kombat 1, and should work for any game with realistic blood.

**Requires:** `ReShade.fxh`.

#### Settings

| Setting | Default | What it does |
|---|---|---|
| Blood Tone | 0.5 | Target hue. 0 is dark crimson, as in pooled blood; 0.5 is pure red; 1 is the orange-red of dried blood. |
| Detection Range | 0.08 | Width of the hue window, about 29 degrees at the default. Raise it if parts of a splash are missed, lower it if rust or red armour lights up. |
| Blood Saturation Threshold | 0.55 | Minimum saturation to count as blood. Raise it to drop rust, worn cloth and dark brick. |
| Shadow Cutoff | 0.01 | Pixels darker than this are never blood. The default excludes almost nothing. |
| Highlight Cutoff | 0.40 | Pixels brighter than this are never blood, which keeps out fire, UI and lit red surfaces. |
| Edge Softness | 0.10 | Width of the ramp on the saturation and highlight gates. Lower is a harder edge. |
| Background Color Strength | 0.9 | Colour kept outside the blood. 1 is untouched, 0 is grayscale. |
| Background Brightness | 1.0 | Dims everything except blood, so blood reads brighter without its colour changing. |
| Mask Smoothing | 0.0 | Blends the mask with a 3x3 blur of itself to calm shimmer from noisy red pixels in motion. |
| Blood Color Intensity | 1.2 | Saturation of the isolated blood. 1 leaves it as it was. |
| Show Debug Mask | off | The blood mask, white on black. The quickest way to tune the three gates. |

#### Tuning for another game

1. Find a scene with blood on a neutral surface: floor, concrete or bare skin.
2. **Blood Tone.** Nudge right if the game's blood is orange-red, left if it's dark crimson.
3. **Detection Range.** The main coverage control. Raise it if only a thin slice of the blood lights up, lower it if other reds start to.
4. **Shadow Cutoff.** Lower it if blood pooled in shadow is missed.
5. **Highlight Cutoff.** Lower it if fire or UI bleeds in, raise it if blood on bright surfaces is cut out.
6. **Blood Saturation Threshold.** Raise it if rust, cloth or armour is caught, lower it if blood is only partly coloured.
7. **Background Color Strength.** To taste. Lower is more contrast between blood and everything else, and a more stylised look.
8. **Blood Color Intensity.** The default makes blood a little more vivid than the source. Bring it toward 1.0 or below to blend blood back toward the background.

## Development note

AI assistance was used during the development of these shaders, for tasks such as reviewing the code, finding bugs, refining the implementation, and writing documentation. All changes were reviewed and tested before being included.

## License

MIT. Use, modify, and redistribute freely. Credit is appreciated but not required.
