/*-----------------------------------------------------------|
| ::                 Perceptual HDR Plus                  :: |
'------------------------------------------------------------|
|  Perceptual HDR Plus                                       |
|  Version: 2.0                                              |
|                                                            |
|  Original PHDR (v1.1) by BarbatosBachiko:                  |
|    https://github.com/BarbatosBachiko/Reshade-Shaders      |
|  Based on: https://github.com/ray075hl/singleLDR2HDR       |
|  Techniques: WLS (Weighted Least Squares smoothing),       |
|    SRS (Selective Reflectance Scaling),                    |
|    VIG (Virtual Illumination Generator),                   |
|    ToneMap (multi-exposure fusion)                         |
|                                                            |
|  Tonal adaptation controls (Lift / Pull sliders)           |
|  derived from the EyeAdaption.fx technique by              |
|  brussell:                                                 |
|    https://github.com/brussell1/Shaders                    |
|                                                            |
|  Split toning added using standard color grading           |
|  techniques (warm highlights, cool shadows).               |
|                                                            |
|  License: MIT                                              |
|  About: Extends PHDR with per-zone tonal adaptation        |
|  controls and adaptive split toning to push perceived      |
|  dynamic range beyond what the original achieves.          |
'------------------------------------------------------------*/

//===========================================================|
// :: Inlined from bb_reshade.fxh                         :: |
// :: Credit: BarbatosBachiko / Reshade-Shaders           :: |
//===========================================================|

#if !defined(__RESHADE__) || __RESHADE__ < 30000
    #error "ReShade 3.0+ is required for this shader"
#endif

#define BUFFER_PIXEL_SIZE   float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT)
#define BUFFER_SCREEN_SIZE  float2(BUFFER_WIDTH, BUFFER_HEIGHT)
#define BUFFER_ASPECT_RATIO (BUFFER_WIDTH * BUFFER_RCP_HEIGHT)

namespace bb
{
    static const float  AspectRatio = BUFFER_WIDTH * BUFFER_RCP_HEIGHT;
    static const float2 PixelSize   = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    static const float2 ScreenSize  = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
}

void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
{
    texcoord.x = (id == 2) ? 2.0 : 0.0;
    texcoord.y = (id == 1) ? 2.0 : 0.0;
    position = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

//-------------------|
// :: Luminance   :: |
//-------------------|

// The shader operates entirely in the backbuffer's native SDR gamma space;
// all internal math is tuned for values in [0, 1].
static const float3 LUMA_709 = float3(0.2126, 0.7152, 0.0722);

float GetLuminance(float3 color)
{
    return dot(color, LUMA_709);
}

//----------|
// :: UI :: |
//----------|

uniform float Strength <
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_label = "INTENSITY";
    ui_category = "General";
> = 0.3;

uniform float DynamicIntensity <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
    ui_label = "Dark Scene Fade";
    ui_category = "General";
    ui_tooltip = "Fades the tone-fusion out as the scene gets very dark, where there\n"
                 "is little dynamic range left to recover and the effect mostly\n"
                 "amplifies compression noise and crushed detail.\n\n"
                 "0.0 = off, the effect holds full INTENSITY at any brightness.\n"
                 "1.0 = fully fade out below the Dark Scene Fade Threshold.";
> = 0.5;

uniform float DarkFadeThreshold <
    ui_type = "slider";
    ui_min = 0.01; ui_max = 0.30;
    ui_step = 0.005;
    ui_label = "Dark Scene Fade Threshold";
    ui_category = "General";
    ui_tooltip = "Scene brightness at which the fade has fully released.\n"
                 "The effect ramps smoothly from the Adaptation Floor up to this\n"
                 "value, and the ramp is held to a minimum width so the transition\n"
                 "always stays gradual rather than snapping on.\n"
                 "Only relevant when Dark Scene Fade is above 0.";
> = 0.15;

uniform float Radius <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 30.0;
    ui_label = "Smoothing Radius";
    ui_category = "General";
    ui_tooltip = "Simulates the Lambda/Alpha of WLS.";
> = 15.0;

uniform float Epsilon <
    ui_type = "slider";
    ui_min = 0.001; ui_max = 0.005;
    ui_label = "Edge Sensitivity";
    ui_category = "General";
> = 0.001;

uniform float Contrast_Micro <
    ui_label = "Micro Contrast Boost";
    ui_category = "General";
    ui_tooltip = "Amplifies or suppresses micro-scale local contrast.";
    ui_type = "slider";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float Contrast_Medium <
    ui_label = "Medium Contrast Boost";
    ui_category = "General";
    ui_tooltip = "Amplifies or suppresses medium-scale local contrast.";
    ui_type = "slider";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float Contrast_Macro <
    ui_label = "Macro Contrast Boost";
    ui_category = "General";
    ui_tooltip = "Adds large-scale depth contrast back into the image.\n\n"
                 "Unlike the Micro and Medium sliders this one starts at 0 rather\n"
                 "than centring there. The tone mapping already divides the coarse\n"
                 "structure out, so 0 is the flat end of the range and raising the\n"
                 "slider restores large-scale depth. There is nothing below 0 to\n"
                 "suppress: negative gain would invert the macro band instead of\n"
                 "flattening it, swapping which side of a large edge reads brighter.";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float Contrast_Shadow_Strength <
    ui_label = "Contrast Shadow Strength";
    ui_category = "General";
    ui_tooltip = "Adjusts the intensity of the microscopic dark halo around bright\n"
                 "highlights. Higher values increase edge contrast.\n\n"
                 "Read as a fraction of INTENSITY, so the halo fades out with the\n"
                 "main effect and with the Dark Scene Fade.";
    ui_type = "drag";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.001;
> = 1.0;

uniform bool EnableDithering <
    ui_label = "Enable Dithering";
    ui_category = "General";
    ui_tooltip = "Reduces visible 8-bit gradient banding by injecting subtle adaptive dithering only where banding is likely to occur.";
> = true;

uniform bool EnableAdaptation <
    ui_label = "Enable Eye Adaptation";
    ui_category = "Eye Adaptation";
    ui_category_closed = true;
    ui_tooltip = "Enables dynamic brightness adaptation. Disable to use a fixed exposure value (prevents washing out dark scenes).";
> = true;

uniform float AdaptationTime <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Eye Adaptation Speed";
    ui_category = "Eye Adaptation";
    ui_tooltip = "Time in seconds for the eye to adjust when a scene gets BRIGHTER\n"
                 "(light adaptation). Higher = Smoother/Slower.\n"
                 "Darkening uses this value scaled by the Dark Adaptation Multiplier.";
> = 0.5;

uniform float DarkAdaptationMult <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Dark Adaptation Multiplier";
    ui_category = "Eye Adaptation";
    ui_tooltip = "The human eye brightens quickly but dark-adapts much more slowly.\n"
                 "When the scene gets DARKER, adaptation time is multiplied by this\n"
                 "factor, so the effect eases into shadow more gradually.\n\n"
                 "1.0 = symmetric. 2-4 is realistic.";
> = 2.5;

uniform float AdaptMin <
    ui_type = "slider";
    ui_min = 0.01; ui_max = 0.5;
    ui_step = 0.001;
    ui_label = "Adaptation Floor";
    ui_category = "Eye Adaptation";
    ui_tooltip = "Lower clamp on the measured scene brightness. Raising this stops a\n"
                 "near-black frame (e.g. a fade-out or a wall of shadow) from dragging\n"
                 "the exposure all the way to the floor and blowing out the next shot.\n\n"
                 "Raise it past the Tonal Neutral Point and no scene can ever measure\n"
                 "dark enough to count as below average, which leaves the Tonal\n"
                 "Brightening (Lift) sliders with nothing to act on.";
> = 0.03;

uniform float AdaptMax <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 0.99;
    ui_step = 0.001;
    ui_label = "Adaptation Ceiling";
    ui_category = "Eye Adaptation";
    ui_tooltip = "Upper clamp on the measured scene brightness. Lowering this stops a\n"
                 "white flash (explosion, muzzle flare) from railing the exposure and\n"
                 "crushing the scene dark for a moment afterwards.\n\n"
                 "Lower it below the Tonal Neutral Point and no scene can ever measure\n"
                 "bright enough to count as above average, which leaves the Tonal\n"
                 "Darkening (Pull) sliders with nothing to act on.";
> = 0.85;

uniform float ManualExposure <
    ui_type = "slider";
    ui_min = 0.001; ui_max = 1.0;
    ui_label = "Manual Exposure";
    ui_category = "Eye Adaptation";
    ui_tooltip = "Fixed exposure value used when Eye Adaptation is disabled. Lower values preserve darkness.";
> = 0.1;

uniform float AdaptationStrength <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Eye Adaptation Strength";
    ui_category = "Eye Adaptation";
    ui_tooltip = "How strongly eye adaptation shifts the exposure.\n"
                 "Only active when Enable Eye Adaptation is on.\n\n"
                 "1.0 = full adaptation correction (default behavior).\n"
                 "0.0 = adaptation is measured but has no effect on the image.\n"
                 "0.5 = half the normal correction is applied.";
> = 1.0;

// ---- Core Eye Adaptation Controls ----

uniform int LumaTextureSize <
    ui_type = "combo";
    ui_label = "Luma Texture Size";
    ui_category = "Eye Adaptation";
    ui_tooltip = "Resolution of the internal luminance texture used for eye adaptation.\n\n"
                 "Smaller textures are cheaper and their mip chains collapse to 1x1\n"
                 "sooner, so a given Trigger Radius covers a wider screen area:\n"
                 "  Full Resolution : mip chain matches screen res (up to mip 11)\n"
                 "  512 x 512       : 10 mip levels, valid indices 0-9\n"
                 "  256 x 256       :  9 mip levels, valid indices 0-8\n"
                 "  128 x 128       :  8 mip levels, valid indices 0-7\n"
                 "   64 x 64        :  7 mip levels, valid indices 0-6\n\n"
                 "Values of Trigger Radius beyond the valid chain are GPU-clamped\n"
                 "to the last level (1x1 pixel = whole-image average). This matches\n"
                 "the behavior described in MipScope.";
    ui_items = "Full Resolution\0"
               "512 x 512\0"
               "256 x 256\0"
               "128 x 128\0"
               "64 x 64\0";
> = 0;

uniform float TriggerRadius <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 12.0;
    ui_step = 0.1;
    ui_label = "Adaptation Trigger Radius";
    ui_category = "Eye Adaptation";
    ui_tooltip = "Controls which mip level of the luminance texture is sampled to\n"
                 "compute average scene brightness for eye adaptation.\n\n"
                 "Lower values sample a smaller, more central area of the image.\n"
                 "Higher values pull the sample toward a whole-image average.\n"
                 "At maximum (12), any texture size will have reached its 1x1 mip\n"
                 "and will return the average luminance of the entire frame.\n\n"
                 "Valid top of chain per texture size:\n"
                 "  Full Res 1080p : mip 10   Full Res 1440p : mip 11\n"
                 "  Full Res 4K    : mip 12\n"
                 "  512 x 512      : mip  9   256 x 256      : mip  8\n"
                 "  128 x 128      : mip  7    64 x 64       : mip  6\n\n"
                 "Values beyond the preset's valid range are GPU-clamped to the\n"
                 "last valid level (same behavior as real adaptation shaders).";
> = 8.0;

// ---- Tonal Adaptation - Shared ----
// The pivot that decides whether a scene is brightened or darkened. It governs
// both the Brightening (Lift) and Darkening (Pull) groups below, so it lives in
// its own category rather than inside either one.

uniform float TonalNeutralPoint <
    ui_type = "slider";
    ui_min = 0.10; ui_max = 0.70;
    ui_step = 0.01;
    ui_label = "Tonal Neutral Point";
    ui_category = "Tonal Adaptation";
    ui_tooltip = "The scene brightness treated as 'average', where neither the Lift nor\n"
                 "the Pull sliders do anything. Scenes measuring below it are handled by\n"
                 "the Tonal Brightening (Lift) sliders, scenes above it by the Tonal\n"
                 "Darkening (Pull) sliders. Governs both groups.\n\n"
                 "How hard either group pushes depends on how far the scene sits from\n"
                 "this point, measured over a fixed range that is the same above and\n"
                 "below it. Moving the pivot away from your usual scene brightness\n"
                 "therefore strengthens the response as well as choosing which group\n"
                 "runs.\n\n"
                 "Direction comes from the sliders alone - they brighten above 1.0 and\n"
                 "darken below it. Raise the pivot with Lift set under 1.0 and a dark\n"
                 "scene gets darker, not brighter.\n\n"
                 "Scene brightness is a geometric mean in gamma space, which typically\n"
                 "reads well below 0.5 even in bright outdoor scenes, so the pivot sits\n"
                 "at 0.30 to keep the Pull sliders reachable.\n\n"
                 "Keep it inside the Adaptation Floor and Ceiling. Sitting close to\n"
                 "either one leaves a scene little room to travel on that side, so the\n"
                 "group it feeds reaches only part of its travel and needs a higher\n"
                 "slider setting to push as hard. Past either one, that group stops\n"
                 "acting at all, since no scene can measure on that side of the pivot.";
> = 0.30;

// ---- Tonal Adaptation - Brightening ----
// All three sliders share the same scale. Default 1.0 = neutral (no tonal delta,
// identical to the original PHDR behavior). Values above 1.0 amplify the zone's
// brightening response in dark scenes; values below 1.0 suppress it.

uniform float LiftHighlights <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 1.5;
    ui_step = 0.01;
    ui_label = "Highlight Lift";
    ui_category = "Tonal Brightening";
    ui_category_closed = true;
    ui_tooltip = "Controls highlight recovery strength when the scene is darker than average.\n\n"
                 "1.0 = neutral, identical to the original PHDR behavior (no tonal delta).\n"
                 "> 1.0 = amplifies highlight brightening in dark scene conditions.\n"
                 "< 1.0 = suppresses highlight brightening, allowing highlights to stay darker.";
> = 1.0;

uniform float LiftMidtones <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 1.5;
    ui_step = 0.01;
    ui_label = "Midtone Lift";
    ui_category = "Tonal Brightening";
    ui_tooltip = "Controls midtone recovery strength when the scene is darker than average.\n\n"
                 "1.0 = neutral, identical to the original PHDR behavior (no tonal delta).\n"
                 "> 1.0 = amplifies midtone brightening in dark scene conditions.\n"
                 "< 1.0 = suppresses midtone brightening.";
> = 1.0;

uniform float LiftShadows <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 1.5;
    ui_step = 0.01;
    ui_label = "Shadow Lift";
    ui_category = "Tonal Brightening";
    ui_tooltip = "Controls shadow recovery strength when the scene is darker than average.\n\n"
                 "1.0 = neutral, identical to the original PHDR behavior (no tonal delta).\n"
                 "> 1.0 = amplifies shadow brightening in dark scene conditions.\n"
                 "< 1.0 = suppresses shadow brightening, preserving deep blacks.";
> = 1.0;

// ---- Tonal Adaptation - Darkening ----
// Mirror of Tonal Brightening but applied when the scene is brighter than average.
// Default 1.0 = neutral. Above 1.0 pushes the zone darker; below 1.0 resists darkening.

uniform float PullHighlights <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 1.5;
    ui_step = 0.01;
    ui_label = "Highlight Pull";
    ui_category = "Tonal Darkening";
    ui_category_closed = true;
    ui_tooltip = "Controls highlight suppression strength when the scene is brighter than average.\n\n"
                 "1.0 = neutral, identical to the original PHDR behavior (no tonal delta).\n"
                 "> 1.0 = amplifies highlight darkening in bright scene conditions.\n"
                 "< 1.0 = suppresses highlight darkening.";
> = 1.0;

uniform float PullMidtones <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 1.5;
    ui_step = 0.01;
    ui_label = "Midtone Pull";
    ui_category = "Tonal Darkening";
    ui_tooltip = "Controls midtone suppression strength when the scene is brighter than average.\n\n"
                 "1.0 = neutral, identical to the original PHDR behavior (no tonal delta).\n"
                 "> 1.0 = amplifies midtone darkening in bright scene conditions.\n"
                 "< 1.0 = suppresses midtone darkening.";
> = 1.0;

uniform float PullShadows <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 1.5;
    ui_step = 0.01;
    ui_label = "Shadow Pull";
    ui_category = "Tonal Darkening";
    ui_tooltip = "Controls shadow suppression strength when the scene is brighter than average.\n\n"
                 "1.0 = neutral, identical to the original PHDR behavior (no tonal delta).\n"
                 "> 1.0 = amplifies shadow darkening in bright scene conditions.\n"
                 "< 1.0 = suppresses shadow darkening.";
> = 1.0;

// ---- Adaptive Color Volume / Split Toning ----

uniform bool EnableSplitToning <
    ui_label = "Enable Split Toning";
    ui_category = "Adaptive Color Volume";
    ui_category_closed = true;
    ui_tooltip = "Toggles adaptive highlight and shadow tinting.";
> = true;

uniform bool ScaleTintsWithIntensity <
    ui_label = "Scale Tints with INTENSITY";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "If enabled, split toning strength automatically scales with the main INTENSITY slider.\n"
                 "If disabled, split toning operates completely independently of the INTENSITY slider.";
> = true;

uniform float HighlightTintTone <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Highlight Tint Tone";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "0.0 = Golden Yellow | 0.5 = Warm Orange (Default) | 1.0 = Deep Amber\n"
                 "Shifts the hue of the highlights tint without breaking realistic bounds.";
> = 0.5;

uniform float ShadowTintTone <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Shadow Tint Tone";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "0.0 = Cyan/Teal | 0.5 = Cool Blue (Default) | 1.0 = Deep Indigo\n"
                 "Shifts the hue of the shadows tint without breaking realistic bounds.";
> = 0.5;

uniform float TintOpacityH <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Highlight Tint Base Intensity";
    ui_category = "Adaptive Color Volume";
> = 0.15;

uniform float TintOpacityS <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Shadow Tint Base Intensity";
    ui_category = "Adaptive Color Volume";
> = 0.08;

uniform float TintThresholdH <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 5.0;
    ui_step = 0.05;
    ui_label = "Highlight Contrast Threshold";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "How much brighter a pixel must be relative to the scene average to receive the warm tint.\n"
                 "1.0 = Triggers instantly on any value above average.\n"
                 "1.25 = Requires a pixel to be at least 25% brighter than the environment baseline.";
> = 1.25;

uniform float TintThresholdS <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.05;
    ui_label = "Shadow Contrast Threshold";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "How much darker a pixel must be relative to the scene average to receive the cool tint.\n"
                 "1.0 = Triggers instantly on any value below average.\n"
                 "0.75 = Requires a pixel to drop at least 25% below the environment baseline.";
> = 0.70;

uniform bool EnablePurkinje <
    ui_label = "Enable Purkinje Effect";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "Simulates scotopic vision shift in dark scenes.";
> = true;

uniform float Purkinje_Red_Reduction <
    ui_label = "Purkinje Red Reduction";
    ui_category = "Adaptive Color Volume";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.5; ui_step = 0.001;
> = 0.10;

uniform float Purkinje_Green_Bias <
    ui_label = "Purkinje Green Bias";
    ui_category = "Adaptive Color Volume";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.05; ui_step = 0.001;
> = 0.010;

uniform float Purkinje_Blue_Bias <
    ui_label = "Purkinje Blue Bias";
    ui_category = "Adaptive Color Volume";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.05; ui_step = 0.001;
> = 0.012;

uniform float Purkinje_Fade_End <
    ui_label = "Purkinje Fade-Out End";
    ui_category = "Adaptive Color Volume";
    ui_type = "slider";
    ui_min = 0.10; ui_max = 0.50; ui_step = 0.01;
> = 0.20;

uniform float Purkinje_Fade_Start <
    ui_label = "Purkinje Fade-Out Start";
    ui_category = "Adaptive Color Volume";
    ui_type = "slider";
    ui_min = 0.00; ui_max = 0.20; ui_step = 0.005;
> = 0.05;

uniform bool Debug_Mask <
    ui_label = "Debug: Visualize Contrast Mask";
    ui_category = "Debug";
    ui_category_closed = true;
    ui_type = "radio";
> = false;

uniform bool Debug_Dithering <
    ui_label = "Debug: Visualize Dithering";
    ui_category = "Debug";
    ui_type = "radio";
> = false;

uniform float FrameTime < source = "frametime"; >;
uniform int FrameCount < source = "framecount"; >;

// Quantisation step of the output. Dither amplitude is one such step so it
// matches the real bit depth of the swapchain (255 for 8-bit, 1023 for 10-bit)
// instead of always assuming 8-bit.
#ifndef BUFFER_COLOR_BIT_DEPTH
    #define BUFFER_COLOR_BIT_DEPTH 8
#endif
static const float DitherSteps = float((1 << BUFFER_COLOR_BIT_DEPTH) - 1);

//----------------|
// :: Textures :: |
//----------------|

#define SCALE 2
#define GW (BUFFER_WIDTH / SCALE)
#define GH (BUFFER_HEIGHT / SCALE)

// Enough mip levels for the full-res luma chain to reach 1x1: a 4K buffer
// needs 13 levels (0-12); 12 suffices up to 2048 pixels on the long axis.
#if (BUFFER_WIDTH >= 4096) || (BUFFER_HEIGHT >= 4096)
    #define LUMA_FULLRES_MIPS 13
#elif (BUFFER_WIDTH >= 2048) || (BUFFER_HEIGHT >= 2048)
    #define LUMA_FULLRES_MIPS 12
#elif (BUFFER_WIDTH >= 1024) || (BUFFER_HEIGHT >= 1024)
    #define LUMA_FULLRES_MIPS 11
#elif (BUFFER_WIDTH >= 512) || (BUFFER_HEIGHT >= 512)
    #define LUMA_FULLRES_MIPS 10
#else
    #define LUMA_FULLRES_MIPS 9
#endif

namespace DZPHDR
{
    texture TexColor : COLOR;
    sampler sTexColor
    {
        Texture = TexColor;
    };

    texture TexLuma
    {
        Width     = BUFFER_WIDTH;
        Height    = BUFFER_HEIGHT;
        Format    = R16F;
        MipLevels = LUMA_FULLRES_MIPS;
    };

    sampler sTexLuma
    {
        Texture = TexLuma;
    };

    // Log-luminance copy of TexLuma. Eye adaptation averages this instead of
    // TexLuma so the scene metric is a geometric (log) mean, which is far more
    // stable than an arithmetic mean - a few very bright pixels no longer drag
    // the whole exposure. Kept separate because the guided filters and the
    // final combine still need the linear TexLuma.
    texture TexLumaLog
    {
        Width     = BUFFER_WIDTH;
        Height    = BUFFER_HEIGHT;
        Format    = R16F;
        MipLevels = LUMA_FULLRES_MIPS;
    };

    sampler sTexLumaLog
    {
        Texture = TexLumaLog;
    };

    texture TexLuma512
    {
        Width     = 512;
        Height    = 512;
        Format    = R16F;
        MipLevels = 10;
    };

    sampler sTexLuma512
    {
        Texture = TexLuma512;
    };

    texture TexLuma256
    {
        Width     = 256;
        Height    = 256;
        Format    = R16F;
        MipLevels = 9;
    };

    sampler sTexLuma256
    {
        Texture = TexLuma256;
    };

    texture TexLuma128
    {
        Width     = 128;
        Height    = 128;
        Format    = R16F;
        MipLevels = 8;
    };

    sampler sTexLuma128
    {
        Texture = TexLuma128;
    };

    texture TexLuma64
    {
        Width     = 64;
        Height    = 64;
        Format    = R16F;
        MipLevels = 7;
    };

    sampler sTexLuma64
    {
        Texture = TexLuma64;
    };

    // Medium scale (Base) filter maps
    // The vertical passes read these with the same strided taps the horizontal ones
    // use, so they need a mip chain to prefilter from. Six levels covers the widest
    // stride any scale can ask for (macro at maximum Radius) with room to spare.
    texture TexTempMeansMedium
    {
        Width     = GW;
        Height    = GH;
        Format    = RG16F;
        MipLevels = 6;
    };

    sampler sTexTempMeansMedium
    {
        Texture = TexTempMeansMedium;
    };

    texture TexStatsMedium
    {
        Width  = GW;
        Height = GH;
        Format = RG16F;
    };

    sampler sTexStatsMedium
    {
        Texture = TexStatsMedium;
    };

    // Micro scale filter maps
    texture TexTempMeansMicro
    {
        Width     = GW;
        Height    = GH;
        Format    = RG16F;
        MipLevels = 6;
    };

    sampler sTexTempMeansMicro
    {
        Texture = TexTempMeansMicro;
    };

    texture TexStatsMicro
    {
        Width  = GW;
        Height = GH;
        Format = RG16F;
    };

    sampler sTexStatsMicro
    {
        Texture = TexStatsMicro;
    };

    // Macro scale filter maps
    texture TexTempMeansMacro
    {
        Width     = GW;
        Height    = GH;
        Format    = RG16F;
        MipLevels = 6;
    };

    sampler sTexTempMeansMacro
    {
        Texture = TexTempMeansMacro;
    };

    texture TexStatsMacro
    {
        Width  = GW;
        Height = GH;
        Format = RG16F;
    };

    sampler sTexStatsMacro
    {
        Texture = TexStatsMacro;
    };

    // Expanded to RGB16F to store all three scale bases (R=Micro, G=Medium, B=Macro)
    texture TexVarI
    {
        Width  = BUFFER_WIDTH;
        Height = BUFFER_HEIGHT;
        Format = RGBA16F;
    };

    sampler sTexVarI
    {
        Texture = TexVarI;
    };

    // .r = the value the shader uses (perceptual, asymmetric filter)
    // .g = a short symmetric pre-filter of the raw measurement, used only to feed
    //      the asymmetric stage a flicker-free signal.
    texture TexAdapt
    {
        Format = RG32F;
        Width  = 1;
        Height = 1;
    };

    sampler sTexAdapt
    {
        Texture   = TexAdapt;
        MinFilter = POINT;
        MagFilter = POINT;
        MipFilter = POINT;
    };

    texture TexLastAdapt
    {
        Format = RG32F;
        Width  = 1;
        Height = 1;
    };

    sampler sTexLastAdapt
    {
        Texture   = TexLastAdapt;
        MinFilter = POINT;
        MagFilter = POINT;
        MipFilter = POINT;
    };

    texture TexLastParams
    {
        Format = RGBA32F;
        Width  = 1;
        Height = 1;
    };

    sampler sTexLastParams
    {
        Texture   = TexLastParams;
        MinFilter = POINT;
        MagFilter = POINT;
        MipFilter = POINT;
    };

    struct VS_OUTPUT
    {
        float4 pos : SV_POSITION;
        float2 uv  : TEXCOORD0;
    };

//-----------------|
// :: Functions :: |
//-----------------|

float ScaleFun(float v, float mean_i)
{
    float r = 1.0 - (mean_i * 0.999999);
    return r * (1.0 / (1.0 + exp(-1.0 * (v - mean_i))) - 0.5);
}

float3 GetHighlightTintColor()
{
    float3 yellow = float3(1.0, 0.9,   0.4);
    float3 orange = float3(1.0, 0.78,  0.55);
    float3 amber  = float3(1.0, 0.4,   0.1);

    return HighlightTintTone < 0.5
        ? lerp(yellow, orange, HighlightTintTone * 2.0)
        : lerp(orange, amber,  (HighlightTintTone - 0.5) * 2.0);
}

float3 GetShadowTintColor()
{
    float3 cyan   = float3(0.0, 0.75,  1.0);
    float3 blue   = float3(0.0, 0.365, 1.0);
    float3 indigo = float3(0.0, 0.05,  0.8);

    return ShadowTintTone < 0.5
        ? lerp(cyan, blue,   ShadowTintTone * 2.0)
        : lerp(blue, indigo, (ShadowTintTone - 0.5) * 2.0);
}

// Per-zone tonal delta. The standard 4.0 coefficient keeps all three zones on
// the same intensity scale - no zone receives special amplification.
// Callers pass (slider - 1.0) so that the default value of 1.0 yields a zero
// delta, matching the original PHDR behavior exactly.
float AdaptionDelta(float luma, float strengthMidtones, float strengthShadows, float strengthHighlights)
{
    float midtones   = (4.0 * strengthMidtones - strengthHighlights - strengthShadows) * luma * (1.0 - luma);
    float shadows    = strengthShadows    * (1.0 - luma);
    float highlights = strengthHighlights * luma;
    return midtones + shadows + highlights;
}

// Biggest curve weight that still leaves luma -> luma + delta rising everywhere.
// Opposed slider settings (crushed highlights against lifted shadows) can tilt
// the delta steeply enough to invert the tone order, so darker pixels come out
// brighter than lighter ones. Differentiating AdaptionDelta gives a slope of
// A * (1 - 2 * luma) + (hi - sh) with A = 4 * mid - hi - sh, which bottoms out at
// (hi - sh) - |A| when the delta is added and at -((hi - sh) + |A|) when it is
// subtracted. Hold weight * that slope at -1 or above and the curve can flatten
// but never fold back on itself.
float MonotonicCurveLimit(float strengthMidtones, float strengthShadows, float strengthHighlights, bool subtracted)
{
    float A     = 4.0 * strengthMidtones - strengthHighlights - strengthShadows;
    float slope = subtracted ? -((strengthHighlights - strengthShadows) + abs(A))
                             :  ((strengthHighlights - strengthShadows) - abs(A));
    return (slope < 0.0) ? (-1.0 / slope) : 1e6;
}

// Roll a colour whose brightest channel exceeds a soft knee back down to 1.0 by
// scaling all three channels together, so an over-boosted highlight desaturates
// toward white instead of hard-clipping one channel at a time and shifting hue.
float3 GamutSoftClip(float3 c)
{
    const float knee = 0.8;
    float m = max(max(c.r, c.g), c.b);
    [flatten]
    if (m > knee)
    {
        float over       = m - knee;
        float compressed = knee + (1.0 - knee) * (over / (over + (1.0 - knee)));
        c *= compressed / m;
    }
    return c;
}

//---------------------|
// :: Pixel Shaders :: |
//---------------------|

void PS_Luma(VS_OUTPUT input, out float luma : SV_Target)
{
    luma = GetLuminance(tex2D(sTexColor, input.uv).rgb);
}

void PS_LumaLog(VS_OUTPUT input, out float logLuma : SV_Target)
{
    // Store log-luminance so downstream box/mip averaging computes a geometric
    // mean once exp()'d back. The floor keeps pure-black pixels from sending the
    // log to -inf while still weighting shadows heavily (the perceptual intent).
    float luma = tex2Dlod(sTexLuma, float4(input.uv, 0, 0)).r;
    logLuma = log(max(luma, 1e-4));
}

float PS_Luma512(VS_OUTPUT input) : SV_Target
{
    // Screen resolution is well above 1024, so a 4-tap box at mip 0 would skip
    // most source pixels and alias the whole downsample chain. Pull from the
    // log-luma mip whose resolution is closest to 1024 so the 4 bilinear taps
    // cover the full footprint of one 512x512 texel. Everything downstream in
    // this pyramid stays in the log domain until SampleAvgLuma exp()s it.
    const float srcMip = max(0.0, ceil(log2(max(BUFFER_WIDTH, BUFFER_HEIGHT) / 1024.0)));
    const float2 ps = exp2(srcMip) * float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float v = 0.0;
    v += tex2Dlod(sTexLumaLog, float4(input.uv + float2(-0.5, -0.5) * ps, 0, srcMip)).r;
    v += tex2Dlod(sTexLumaLog, float4(input.uv + float2( 0.5, -0.5) * ps, 0, srcMip)).r;
    v += tex2Dlod(sTexLumaLog, float4(input.uv + float2(-0.5,  0.5) * ps, 0, srcMip)).r;
    v += tex2Dlod(sTexLumaLog, float4(input.uv + float2( 0.5,  0.5) * ps, 0, srcMip)).r;
    return v * 0.25;
}

float PS_Luma256(VS_OUTPUT input) : SV_Target
{
    float2 ps = float2(1.0 / 512.0, 1.0 / 512.0);
    float v = 0.0;
    v += tex2Dlod(sTexLuma512, float4(input.uv + float2(-0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma512, float4(input.uv + float2( 0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma512, float4(input.uv + float2(-0.5,  0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma512, float4(input.uv + float2( 0.5,  0.5) * ps, 0, 0)).r;
    return v * 0.25;
}

float PS_Luma128(VS_OUTPUT input) : SV_Target
{
    float2 ps = float2(1.0 / 256.0, 1.0 / 256.0);
    float v = 0.0;
    v += tex2Dlod(sTexLuma256, float4(input.uv + float2(-0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma256, float4(input.uv + float2( 0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma256, float4(input.uv + float2(-0.5,  0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma256, float4(input.uv + float2( 0.5,  0.5) * ps, 0, 0)).r;
    return v * 0.25;
}

float PS_Luma64(VS_OUTPUT input) : SV_Target
{
    float2 ps = float2(1.0 / 128.0, 1.0 / 128.0);
    float v = 0.0;
    v += tex2Dlod(sTexLuma128, float4(input.uv + float2(-0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma128, float4(input.uv + float2( 0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma128, float4(input.uv + float2(-0.5,  0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma128, float4(input.uv + float2( 0.5,  0.5) * ps, 0, 0)).r;
    return v * 0.25;
}

float SampleAvgLuma()
{
    // Every source here holds log-luminance, so exp() the sampled mip to recover
    // the geometric mean of the covered region.
    float4 uvMip = float4(0.5, 0.5, 0.0, TriggerRadius);
    float logAvg;
    [branch]
    if (LumaTextureSize == 1)      logAvg = tex2Dlod(sTexLuma512, uvMip).r;
    else if (LumaTextureSize == 2) logAvg = tex2Dlod(sTexLuma256, uvMip).r;
    else if (LumaTextureSize == 3) logAvg = tex2Dlod(sTexLuma128, uvMip).r;
    else if (LumaTextureSize == 4) logAvg = tex2Dlod(sTexLuma64,  uvMip).r;
    else                           logAvg = tex2Dlod(sTexLumaLog, uvMip).r;
    return exp(logAvg);
}

// Convert accumulated (mean_I, mean_II) moments into guided-filter coefficients
// (a, b). Computing these at low resolution and letting the final pass bilinearly
// upsample them is the fast guided filter - it avoids the edge halos that come
// from deriving 'a' at full res out of already-interpolated moments.
//
// eps scales per scale: a self-guided filter with a fixed epsilon smooths LESS
// as the window grows (a bigger window holds more variance, which pushes a -> 1
// and the base back toward the input). Left unscaled, the large-radius macro
// base ends up tracking the image more closely than the medium base, inverting
// the coarse-to-fine order and flipping the sign of the macro contrast band.
// Growing eps with the square of the radius ratio restores a proper pyramid
// where each coarser base is genuinely smoother than the finer one.
float2 MomentsToAB(float2 m, float eps)
{
    float var = m.y - m.x * m.x;
    float a   = var / (var + eps);
    return float2(a, m.x * (1.0 - a));
}

// ---- Standard (Medium) Guided Scale Filters ----
// Integer tap counts keep the window exactly symmetric; a float accumulator
// (x += step) can drop the +r endpoint to rounding error and bias the mean.
//
// stepSize = r / 3 pins every scale to 7 taps regardless of radius, so a wide
// window is covered by taps that stand tens of pixels apart. Read at LOD 0 those
// are point samples with holes between them: fine detail folds into both moments,
// the variance drives 'a' off the aliased value, and the base shimmers as content
// drifts through the sampling comb. Reading each tap from the mip whose footprint
// matches its own stride turns it into the average of the pixels it stands for.
// This also measures each scale's variance at that scale rather than letting pixel
// detail leak into the coarse windows, which reinforces the coarse-to-fine
// ordering that MomentsToAB's epsilon scaling is there to protect.
float MipForStride(float stepSize)
{
    return max(0.0, log2(stepSize));
}

void PS_CalcMeansH_Medium(VS_OUTPUT input, out float2 mean_horiz : SV_Target)
{
    float2 ps = bb::PixelSize;
    float stepSize = max(1.0, Radius / 3.0);
    int taps = int(Radius / stepSize + 1e-3);
    // Sampling TexLuma, which is full resolution, so the stride is already in texels.
    float lod = MipForStride(stepSize);
    float2 sum = 0.0;

    for (int i = -taps; i <= taps; i++)
    {
        float val = tex2Dlod(sTexLuma, float4(input.uv + float2(i * stepSize * ps.x, 0), 0, lod)).r;
        sum += float2(val, val * val);
    }
    mean_horiz = sum / (2 * taps + 1);
}

void PS_CalcMeansV_Medium(VS_OUTPUT input, out float2 ab : SV_Target)
{
    float2 ps = bb::PixelSize;
    float stepSize = max(1.0, Radius / 3.0);
    int taps = int(Radius / stepSize + 1e-3);
    // The offsets are in full-res pixels but the moments texture is 1/SCALE that
    // size, so the stride is that many fewer texels and the matching mip is lower.
    float lod = MipForStride(stepSize / float(SCALE));
    float2 sum = 0.0;

    for (int i = -taps; i <= taps; i++)
    {
        float2 val = tex2Dlod(sTexTempMeansMedium, float4(input.uv + float2(0, i * stepSize * ps.y), 0, lod)).rg;
        sum += val;
    }
    // Medium is the reference scale (ratio 1), so it uses Epsilon unchanged and
    // the default all-sliders-zero output is preserved exactly.
    ab = MomentsToAB(sum / (2 * taps + 1), Epsilon);
}

// ---- Micro Guided Scale Filters ----
void PS_CalcMeansH_Micro(VS_OUTPUT input, out float2 mean_horiz : SV_Target)
{
    float2 ps = bb::PixelSize;
    float r = max(1.0, Radius / 3.0);
    float stepSize = max(1.0, r / 3.0);
    int taps = int(r / stepSize + 1e-3);
    float lod = MipForStride(stepSize);
    float2 sum = 0.0;

    for (int i = -taps; i <= taps; i++)
    {
        float val = tex2Dlod(sTexLuma, float4(input.uv + float2(i * stepSize * ps.x, 0), 0, lod)).r;
        sum += float2(val, val * val);
    }
    mean_horiz = sum / (2 * taps + 1);
}

void PS_CalcMeansV_Micro(VS_OUTPUT input, out float2 ab : SV_Target)
{
    float2 ps = bb::PixelSize;
    float r = max(1.0, Radius / 3.0);
    float stepSize = max(1.0, r / 3.0);
    int taps = int(r / stepSize + 1e-3);
    float lod = MipForStride(stepSize / float(SCALE));
    float2 sum = 0.0;

    for (int i = -taps; i <= taps; i++)
    {
        float2 val = tex2Dlod(sTexTempMeansMicro, float4(input.uv + float2(0, i * stepSize * ps.y), 0, lod)).rg;
        sum += val;
    }
    // Finer than medium, so a smaller eps keeps the micro base close to the input.
    float ratio = r / Radius;
    ab = MomentsToAB(sum / (2 * taps + 1), Epsilon * ratio * ratio);
}

// ---- Macro Guided Scale Filters ----
void PS_CalcMeansH_Macro(VS_OUTPUT input, out float2 mean_horiz : SV_Target)
{
    float2 ps = bb::PixelSize;
    float r = min(90.0, Radius * 3.0);
    float stepSize = max(1.0, r / 3.0);
    int taps = int(r / stepSize + 1e-3);
    // Widest stride of the three scales, so this is where LOD 0 aliased worst.
    float lod = MipForStride(stepSize);
    float2 sum = 0.0;

    for (int i = -taps; i <= taps; i++)
    {
        float val = tex2Dlod(sTexLuma, float4(input.uv + float2(i * stepSize * ps.x, 0), 0, lod)).r;
        sum += float2(val, val * val);
    }
    mean_horiz = sum / (2 * taps + 1);
}

void PS_CalcMeansV_Macro(VS_OUTPUT input, out float2 ab : SV_Target)
{
    float2 ps = bb::PixelSize;
    float r = min(90.0, Radius * 3.0);
    float stepSize = max(1.0, r / 3.0);
    int taps = int(r / stepSize + 1e-3);
    float lod = MipForStride(stepSize / float(SCALE));
    float2 sum = 0.0;

    for (int i = -taps; i <= taps; i++)
    {
        float2 val = tex2Dlod(sTexTempMeansMacro, float4(input.uv + float2(0, i * stepSize * ps.y), 0, lod)).rg;
        sum += val;
    }
    // Coarser than medium, so a larger eps forces the macro base to smooth out
    // the medium-scale structure and become the true low-frequency layer.
    float ratio = r / Radius;
    ab = MomentsToAB(sum / (2 * taps + 1), Epsilon * ratio * ratio);
}

void PS_GuidedFilterResult(VS_OUTPUT input, out float3 base_layers : SV_Target)
{
    float I = tex2D(sTexLuma, input.uv).r;

    // Each stats texture now holds the low-res guided-filter coefficients (a, b);
    // bilinear sampling upsamples them and the base is just a * I + b.
    float2 ab_medium = tex2D(sTexStatsMedium, input.uv).rg;
    float base_medium = ab_medium.x * I + ab_medium.y;

    float2 ab_micro = tex2D(sTexStatsMicro, input.uv).rg;
    float base_micro = ab_micro.x * I + ab_micro.y;

    float2 ab_macro = tex2D(sTexStatsMacro, input.uv).rg;
    float base_macro = ab_macro.x * I + ab_macro.y;

    base_layers = float3(base_micro, base_medium, base_macro);
}

// Pre-filter length. Long enough to swallow a flickering torch or fire, short
// enough that it costs about a sixth of a second on a real transition.
static const float FlickerRejectTime = 0.15;

// How far a scene has to sit from the neutral point before the Lift or Pull
// sliders reach full travel. Same distance on both sides and at any pivot.
static const float TonalResponseRange = 0.35;

void PS_CalcAdapt(VS_OUTPUT input, out float2 adapt : SV_Target)
{
    // Clamp the raw measurement so a fade-to-black or a white flash can't rail
    // the adaptation and slam the tonal curves on the next frame.
    float adaptCeil = max(AdaptMax, AdaptMin + 0.01);
    float measured  = clamp(SampleAvgLuma(), AdaptMin, adaptCeil);
    float2 last     = tex2Dfetch(sTexLastAdapt, 0).rg;
    float dt        = FrameTime * 0.001;

    float4 prevParams = tex2Dfetch(sTexLastParams, 0);
    float4 currParams = float4(float(LumaTextureSize), TriggerRadius, 0.5, 0.5);
    bool paramChanged = any(abs(currParams - prevParams) > 1e-4);

    if (paramChanged || AdaptationTime <= 0.0)
    {
        adapt = max(measured, 1e-5).xx;
        return;
    }

    // Stage 1 is symmetric, so it settles on the true mean. Feeding the stage
    // below a clean signal matters: a fast-up/slow-down filter run straight off a
    // flickering measurement creeps upward, about 10% high next to a campfire.
    float fast = lerp(last.g, measured, 1.0 - exp(-dt / FlickerRejectTime));

    // Stage 2 is the eye model - quick to brighten, slow to dark-adapt. Direction
    // fades across a relative deadband instead of a hard test, otherwise noise
    // around the crossing point flips the time constant every frame. Exponential
    // decay keeps the rate independent of frame rate.
    float deadband = max(0.25 * last.r, 1e-4);
    float rising   = smoothstep(-deadband, deadband, fast - last.r);
    float tau      = AdaptationTime * lerp(DarkAdaptationMult, 1.0, rising);
    float slow     = lerp(last.r, fast, 1.0 - exp(-dt / max(tau, 0.001)));

    adapt = float2(max(slow, 1e-5), max(fast, 1e-5));
}

void PS_SaveParams(VS_OUTPUT input, out float4 save : SV_Target)
{
    save = float4(float(LumaTextureSize), TriggerRadius, 0.5, 0.5);
}

void PS_SaveAdapt(VS_OUTPUT input, out float2 save : SV_Target)
{
    save = tex2Dfetch(sTexAdapt, 0).rg;
}

float3 PS_FinalCombine(VS_OUTPUT input) : SV_Target
{
    float3 original = tex2D(sTexColor, input.uv).rgb;
    float L    = tex2D(sTexLuma, input.uv).r;
    float3 Bases = tex2D(sTexVarI, input.uv).rgb;

    L    = max(L,    1e-5);
    Bases = max(Bases, 1e-5);

    float Base = Bases.y; // Medium base is default

    // Non-overlapping log-space frequency bands so each slider controls a
    // disjoint scale. With all sliders at 0 this reduces to the original
    // R_val = log(L) - log(Bases.y). The macro band contributes only through
    // its slider, keeping the medium base as the reconstruction reference.
    float band_micro  = log(L)       - log(Bases.x);
    float band_medium = log(Bases.x) - log(Bases.y);
    float band_macro  = log(Bases.y) - log(Bases.z);

    // Macro is a bare gain rather than 1 + slider like the two finer bands, because
    // the medium base already divides the coarse structure out of the default
    // reconstruction: the macro band starts absent and the slider adds it back. That
    // makes 0 the flat end of the range, not its centre, so the gain is held at or
    // above 0 here as well as in the UI bound. A negative gain would not flatten the
    // band further, it would subtract past flat and invert it, darkening whichever
    // side of a large-scale edge is meant to read brighter.
    float macro_gain = max(Contrast_Macro, 0.0);

    float R_val = band_micro  * (1.0 + Contrast_Micro)
                + band_medium * (1.0 + Contrast_Medium)
                + band_macro  * macro_gain;

    // High-frequency reflectance detail used later for contrast masking
    float hf_detail  = L - Base;
    float sm_manual  = clamp(ManualExposure, 0.01, 0.99);
    float sm_adapt   = EnableAdaptation ? clamp(tex2Dfetch(sTexAdapt, 0).r, 0.01, 0.99) : sm_manual;
    // AdaptationStrength > 1.0 extrapolates the lerp, so re-clamp to keep the
    // scene mean in a range the VIG sigmoid and contrast ratios can handle.
    float scene_mean = EnableAdaptation ? clamp(lerp(sm_manual, sm_adapt, AdaptationStrength), 0.01, 0.99) : sm_manual;

    float R_new = R_val;
    if (L > scene_mean)
    {
        float factor = pow(abs(L / scene_mean), 0.5);
        R_new = R_val * factor;
    }

    float inv_L = 1.0 - L;
    float v1 = 0.2;
    float v3 = scene_mean;
    float v2 = 0.5 * (v1 + v3);
    float v5 = 0.8;
    float v4 = 0.5 * (v3 + v5);
    float A = 0.0, B = 0.0;
    float exp_R_new = exp(R_new);
    float v_scales[5] = { v1, v2, v3, v4, v5 };

    [unroll]
    for (int i = 0; i < 5; i++)
    {
        float fvk = ScaleFun(v_scales[i], scene_mean);
        float I_k = (1.0 + fvk) * (L + fvk * inv_L);
        float Lk  = exp_R_new * I_k;
        float wk  = (i < 3) ? I_k : 0.5 * (1.0 - I_k);
        wk = clamp(wk, 0.001, 1.0);
        A += Lk * wk;
        B += wk;
    }
    float ratio = clamp((A / (B + 1e-6)) / L, 0.0, 3.0);

    // Dynamic intensity: ramp the fusion down in very dark scenes, where the
    // log-ratio has almost no real range to recover and mostly amplifies
    // compression noise. dark_fade is 1 above the threshold, easing to 0 at
    // black; DynamicIntensity picks how much of that fade actually applies.
    // Ramp from the darkest brightness the adaptation can report rather than from
    // black, otherwise the floor clips the bottom off it and the fade never quite
    // arrives. The minimum width stops a low threshold sitting near the floor from
    // squeezing the whole ramp into a couple of hundredths and turning it into a step.
    // scene_mean is clamped to a 0.01 floor above, so the ramp has to start at or
    // above that floor: anchoring it lower (a sub-0.01 Adaptation Floor, or 0.0 in
    // manual mode) leaves a slice of the ramp that scene_mean can never reach and
    // the fade bottoms out at a few percent instead of fully releasing.
    float fade_lo   = EnableAdaptation ? max(AdaptMin, 0.01) : 0.01;
    float fade_hi   = max(DarkFadeThreshold, fade_lo + 0.10);
    float dark_fade = smoothstep(fade_lo, fade_hi, scene_mean);
    float effective_strength = Strength * lerp(1.0, dark_fade, DynamicIntensity);

    // Soft-clip the boosted colour before blending so a saturated highlight that
    // the ratio pushes past 1.0 desaturates cleanly instead of clipping one
    // channel and shifting hue.
    float3 boosted = GamutSoftClip(original * ratio);
    float3 blended = lerp(original, boosted, effective_strength);

    float adp_luma    = GetLuminance(blended);
    float3 adp_chroma = blended - adp_luma;
    float adp_delta;

    // Use 1.0 strength for static manual exposure, otherwise use the slider
    float current_strength = EnableAdaptation ? AdaptationStrength : 1.0;

    // Split point between brightening and darkening. Distance from it is measured
    // in plain brightness against a fixed range, not as a fraction of the space
    // left on either side. That keeps the ramp the same width above and below the
    // pivot and at every pivot setting, so moving the neutral point slides the
    // response along rather than stretching it, and a Lift of 1.2 a tenth below
    // neutral answers a Pull of 1.2 a tenth above it. smoothstep is flat at the
    // pivot and flat again at full travel, so settled scenes hold steady and
    // nothing kicks as the scene drifts across neutral.
    //
    // Which branch can run is bounded by the Adaptation Floor and Ceiling, since
    // those cap what sm_adapt can report. A pivot outside that bracket leaves one
    // branch unreachable and its three sliders inert, and a pivot near either end
    // leaves that side too little travel to reach full response.
    float pivot = clamp(TonalNeutralPoint, 0.05, 0.95);

    // sm_adapt defaults to ManualExposure when adaptation is disabled
    if (sm_adapt < pivot)
    {
        float mid = LiftMidtones - 1.0, sh = LiftShadows - 1.0, hi = LiftHighlights - 1.0;
        float t     = saturate((pivot - sm_adapt) / TonalResponseRange);
        float curve = current_strength * 0.5 * (t * t * (3.0 - 2.0 * t));
        curve = min(curve, MonotonicCurveLimit(mid, sh, hi, false));
        adp_delta = AdaptionDelta(adp_luma, mid, sh, hi) * curve;
    }
    else
    {
        float mid = PullMidtones - 1.0, sh = PullShadows - 1.0, hi = PullHighlights - 1.0;
        float u     = saturate((sm_adapt - pivot) / TonalResponseRange);
        float curve = current_strength * 0.5 * (u * u * (3.0 - 2.0 * u));
        curve = min(curve, MonotonicCurveLimit(mid, sh, hi, true));
        adp_delta = -AdaptionDelta(adp_luma, mid, sh, hi) * curve;
    }

    adp_luma = saturate(adp_luma + adp_delta);
    blended  = saturate(adp_luma + adp_chroma);

    float purkinje_mask = 0.0;

    // [Purkinje] In dark scenes, simulate scotopic vision by suppressing red 
    // and shifting shadow floors toward cyan (blue-green) to maximize contrast.
    // The two fade sliders' ranges overlap (Start up to 0.20, End from 0.10),
    // so enforce End > Start to keep the smoothstep edges ordered.
    float purkinje_fade_end = max(Purkinje_Fade_End, Purkinje_Fade_Start + 0.01);

    [branch]
    if (EnablePurkinje && scene_mean < purkinje_fade_end)
    {
        float pixel_luma  = GetLuminance(blended);

        // Isolate the effect to the darker halves of the image
        float shadow_mask = 1.0 - smoothstep(0.0, 0.5, pixel_luma);

        float purkinje_strength = 1.0 - smoothstep(Purkinje_Fade_Start, purkinje_fade_end, scene_mean);

        purkinje_mask = purkinje_strength * shadow_mask;

        // Slightly toned down desaturation and boost
        blended.r = lerp(blended.r, pixel_luma, purkinje_mask * Purkinje_Red_Reduction);

        // Additively lift green and blue to simulate the 507nm peak sensitivity.
        blended.g = saturate(blended.g + purkinje_mask * Purkinje_Green_Bias * (1.0 - blended.g));
        blended.b = saturate(blended.b + purkinje_mask * Purkinje_Blue_Bias * (1.0 - blended.b));
    }

    [branch]
    if (EnableSplitToning && (!ScaleTintsWithIntensity || effective_strength > 0.0))
    {
        float local_luma     = GetLuminance(blended);
        float contrast_ratio = local_luma / (scene_mean + 0.0001);

        // Track effective_strength rather than the raw slider, so the tints back off
        // with the Dark Scene Fade instead of holding full opacity over a scene the
        // tone fusion has already released. The highlight weight is 1.0 in dark
        // scenes, so without this the highlight tint keeps shifting colour there.
        float strength_weight         = ScaleTintsWithIntensity ? pow(effective_strength, 0.75) : 1.0;
        float scene_shadow_weight     = smoothstep(0.0, 0.3, scene_mean);
        float scene_highlight_weight  = smoothstep(1.0, 0.7, scene_mean);

        [branch]
        if (contrast_ratio > TintThresholdH)
        {
            float highlight_factor  = saturate((contrast_ratio - TintThresholdH) * 0.5);
            float final_opacity_H   = TintOpacityH * highlight_factor * strength_weight * scene_highlight_weight;
            blended = lerp(blended, blended * GetHighlightTintColor(), final_opacity_H);
        }
        else if (contrast_ratio < TintThresholdS)
        {
            float shadow_factor   = saturate((TintThresholdS - contrast_ratio) * 2.0);
            float final_opacity_S = TintOpacityS * shadow_factor * strength_weight * scene_shadow_weight;
            
            // Inverse scaling prevents split toning from overlapping with the active Purkinje mask
            final_opacity_S *= (1.0 - purkinje_mask);
            
            blended = lerp(blended, blended * GetShadowTintColor(), final_opacity_S);
        }
    }

    // Simultaneous Contrast Masking: create a microscopic dark halo around bright
    // objects by slightly deepening pixels that sit on the shadow side of an edge.
    // hf_detail < 0 identifies pixels darker than their local base (shadow boundaries).
    // A 3.0 multiplier increases visibility, capping the raw mask at 0.40 prevents the line from dropping to pure black.
    // Gating on the local base brightness keeps the halo next to genuinely bright
    // neighbourhoods, so it stops darkening high-frequency noise in flat shadows.
    // Scaled by effective_strength for the same reason the tints are: the halo is
    // derived from hf_detail, and in a dark scene that detail is mostly compression
    // noise, which is exactly what the Dark Scene Fade exists to stop amplifying.
    // It also means INTENSITY 0 is a genuine no-op instead of still drawing edges.
    float bright_neighbour = smoothstep(0.15, 0.5, Base);
    float contrast_shadow = min(saturate(-hf_detail * 3.0), 0.40) * Contrast_Shadow_Strength * bright_neighbour * effective_strength;

    // Visualization block
    if (Debug_Mask)
    {
        // We multiply by 5 to make the subtle dark halo clearly visible as bright pixels.
        return contrast_shadow * 5.0;
    }
    blended = saturate(blended * (1.0 - contrast_shadow));

    // Interleaved Gradient Noise (IGN)
    float dither = 0.0;

    if (EnableDithering || Debug_Dithering)
    {
        // Scroll the IGN pattern each frame so it reads as animated grain rather
        // than a fixed screen-space texture stuck on top of smooth gradients.
        float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
        float2 ign_pos = input.uv * bb::ScreenSize + 5.588238 * float(uint(FrameCount) % 64u);
        dither = frac(magic.z * frac(dot(ign_pos, magic.xy)));
    }

    float lum_dx = abs(ddx(GetLuminance(blended)));
    float lum_dy = abs(ddy(GetLuminance(blended)));

    float gradient = lum_dx + lum_dy;

    float banding_mask = saturate(1.0 - gradient * 64.0);
    banding_mask *= banding_mask;

    if (Debug_Dithering)
    {
        float applied =
            banding_mask *
            ((dither - 0.5) / DitherSteps);

        return saturate(applied.xxx * DitherSteps + 0.5);
    }

    [branch]
    if (EnableDithering)
    {
        blended += banding_mask * ((dither - 0.5) / DitherSteps);
        blended = saturate(blended);
    }

    return blended;
}

technique DZ_PerceptualHDR
<
    ui_label = "Perceptual HDR Plus";
>
{
    pass Luma         { VertexShader = PostProcessVS; PixelShader = PS_Luma;                 RenderTarget = TexLuma;           }
    pass LumaLog      { VertexShader = PostProcessVS; PixelShader = PS_LumaLog;              RenderTarget = TexLumaLog;        }
    pass Luma512      { VertexShader = PostProcessVS; PixelShader = PS_Luma512;              RenderTarget = TexLuma512;        }
    pass Luma256      { VertexShader = PostProcessVS; PixelShader = PS_Luma256;              RenderTarget = TexLuma256;        }
    pass Luma128      { VertexShader = PostProcessVS; PixelShader = PS_Luma128;              RenderTarget = TexLuma128;        }
    pass Luma64       { VertexShader = PostProcessVS; PixelShader = PS_Luma64;               RenderTarget = TexLuma64;         }
    pass CalcAdapt    { VertexShader = PostProcessVS; PixelShader = PS_CalcAdapt;            RenderTarget = TexAdapt;          }
    pass SaveParams   { VertexShader = PostProcessVS; PixelShader = PS_SaveParams;           RenderTarget = TexLastParams;     }
    pass SaveAdapt    { VertexShader = PostProcessVS; PixelShader = PS_SaveAdapt;            RenderTarget = TexLastAdapt;      }

    // Medium Scale Filter passes
    pass CalcMeansH_Medium
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CalcMeansH_Medium;
        RenderTarget = TexTempMeansMedium;
    }

    pass CalcMeansV_Medium
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CalcMeansV_Medium;
        RenderTarget = TexStatsMedium;
    }

    // Micro Scale Filter passes
    pass CalcMeansH_Micro
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CalcMeansH_Micro;
        RenderTarget = TexTempMeansMicro;
    }

    pass CalcMeansV_Micro
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CalcMeansV_Micro;
        RenderTarget = TexStatsMicro;
    }

    // Macro Scale Filter passes
    pass CalcMeansH_Macro
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CalcMeansH_Macro;
        RenderTarget = TexTempMeansMacro;
    }

    pass CalcMeansV_Macro
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CalcMeansV_Macro;
        RenderTarget = TexStatsMacro;
    }

    pass GuidedFilter
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_GuidedFilterResult;
        RenderTarget = TexVarI;
    }

    pass Combine
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_FinalCombine;
    }
}

} // namespace DZPHDR
