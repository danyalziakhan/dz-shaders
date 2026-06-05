/*-----------------------------------------------------------|
| ::                  Perceptual HDR 2                    :: |
'------------------------------------------------------------|
|  Perceptual HDR 2                                          |
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

//===========================================================|
// :: Inlined from bb_colorspace.fxh                      :: |
// :: Credit: BarbatosBachiko / Reshade-Shaders           :: |
//===========================================================|

#ifndef BUFFER_COLOR_SPACE
#define BUFFER_COLOR_SPACE 0
#endif

uniform int HDR_Input_Format <
    ui_category_closed = true;
    ui_category = "HDR";
    ui_label = "Input Format";
    ui_tooltip = "Select the color space of the game.\n"
                 "Auto = Detect automatically (Recommended)\n"
                 "SDR/HDR formats = Force specific color space\n"
                 "Raw = No conversion applied";
    ui_type = "combo";
    ui_items = "Auto\0sRGB (SDR)\0scRGB (HDR Linear)\0HDR10 (PQ)\0Raw (No Conversion)\0";
> = 0;

uniform float HDR_Peak_Nits <
    ui_category_closed = true;
    ui_category = "HDR";
    ui_label = "HDR Peak Brightness (Nits)";
    ui_tooltip = "Set this to match your monitor's maximum HDR brightness capabilities (e.g., 400 for DisplayHDR 400, 1000 for high-end HDR). Only affects HDR formats.";
    ui_type = "drag";
    ui_min = 400.0; ui_max = 10000.0; ui_step = 10.0;
> = 1000.0;

uniform bool SDR_Enable_ITM <
    ui_category_closed = true;
    ui_category = "HDR";
    ui_label = "Enable SDR Inverse Tonemapping";
    ui_tooltip = "Expands SDR brightness to HDR range using Inverse Reinhard. Disabled by default as it introduces nonlinear distortion during blending.";
> = true;

uniform bool SDR_ITM_Hue_Preserving <
    ui_category_closed = true;
    ui_category = "HDR";
    ui_label = "SDR ITM Hue Preserving";
    ui_tooltip = "Enable to preserve original hues during brightness expansion.\n"
                 "Disable for per-channel expansion.";
> = true;

static const float3 LUMA_709  = float3(0.2126, 0.7152, 0.0722);
static const float3 LUMA_2020 = float3(0.2627, 0.6780, 0.0593);

static const float PQ_M1 = 0.1593017578125;
static const float PQ_M2 = 78.84375;
static const float PQ_C1 = 0.8359375;
static const float PQ_C2 = 18.8515625;
static const float PQ_C3 = 18.6875;

int GetHDRMode()
{
    if (HDR_Input_Format != 0)
        return HDR_Input_Format;

#if BUFFER_COLOR_SPACE == 1
    return 1;
#elif BUFFER_COLOR_SPACE == 2
    return 2;
#elif BUFFER_COLOR_SPACE == 3
    return 3;
#else
    return 1;
#endif
}

float3 PQ2Linear(float3 color)
{
    float3 val = max(pow(abs(color), 1.0 / PQ_M2) - PQ_C1, 0.0);
    float3 den = PQ_C2 - PQ_C3 * pow(abs(color), 1.0 / PQ_M2);
    float3 linearHdr = pow(abs(val / den), 1.0 / PQ_M1);
    return linearHdr * (10000.0 / HDR_Peak_Nits);
}

float3 Linear2PQ(float3 linearColor)
{
    float3 Y = max(0.0, linearColor * (HDR_Peak_Nits / 10000.0));
    float3 num = PQ_C1 + PQ_C2 * pow(Y, PQ_M1);
    float3 den = 1.0 + PQ_C3 * pow(Y, PQ_M1);
    return pow(num / den, PQ_M2);
}

float3 sRGB2Linear(float3 x)
{
    float3 linear_srgb = (x < 0.04045) ? (x / 12.92) : pow(abs((x + 0.055) / 1.055), 2.4);

    if (!SDR_Enable_ITM)
        return linear_srgb;

    float3 expanded_rgb;
    if (SDR_ITM_Hue_Preserving)
    {
        float luma = dot(linear_srgb, LUMA_709);
        float safe_luma = min(luma, 0.99);
        float expanded_luma = safe_luma / max(1.0 - safe_luma, 0.001);
        expanded_rgb = linear_srgb * (expanded_luma / max(luma, 1e-5));
    }
    else
    {
        float3 safe_rgb = min(linear_srgb, 0.99);
        expanded_rgb = (safe_rgb / max(1.0 - safe_rgb, 0.001));
    }
    return expanded_rgb;
}

float3 Linear2sRGB(float3 x)
{
    x = max(x, 0.0);

    if (SDR_Enable_ITM)
    {
        if (SDR_ITM_Hue_Preserving)
        {
            float luma = dot(x, LUMA_709);
            float compressed_luma = luma / (1.0 + luma);
            x = x * (compressed_luma / max(luma, 1e-5));
        }
        else
        {
            x = x / (1.0 + x);
        }
    }

    return (x < 0.0031308) ? (12.92 * x) : (1.055 * pow(abs(x), 1.0 / 2.4) - 0.055);
}

float3 Input2Linear(float3 color)
{
    int mode = GetHDRMode();
    if (mode == 4) return color;
    if (mode == 2) return color * (80.0 / HDR_Peak_Nits);
    if (mode == 3) return PQ2Linear(color);
    return sRGB2Linear(color);
}

float3 Linear2Output(float3 color)
{
    int mode = GetHDRMode();
    if (mode == 4) return color;
    if (mode == 2) return color * (HDR_Peak_Nits / 80.0);
    if (mode == 3) return Linear2PQ(color);
    return Linear2sRGB(color);
}

float GetLuminance(float3 color)
{
    int mode = GetHDRMode();
    float3 lumaCoeff = (mode == 2 || mode == 3) ? LUMA_2020 : LUMA_709;
    return dot(color, lumaCoeff);
}

//----------|
// :: UI :: |
//----------|

uniform float Strength <
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_label = "INTENSITY";
> = 0.3;

uniform float Radius <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 30.0;
    ui_label = "Smoothing Radius";
    ui_tooltip = "Simulates the Lambda/Alpha of WLS.";
> = 12.5;

uniform float Epsilon <
    ui_type = "slider";
    ui_min = 0.001; ui_max = 0.005;
    ui_label = "Edge Sensitivity";
> = 0.001;

uniform bool EnableAdaptation <
    ui_label = "Enable Eye Adaptation";
    ui_tooltip = "Enables dynamic brightness adaptation. Disable to use a fixed exposure value (prevents washing out dark scenes).";
> = true;

uniform float AdaptationTime <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0;
    ui_label = "Eye Adaptation Speed";
    ui_tooltip = "Time in seconds for the eye to adjust to brightness changes. Higher = Smoother/Slower.";
> = 1.0;

uniform float ManualExposure <
    ui_type = "slider";
    ui_min = 0.001; ui_max = 1.0;
    ui_label = "Manual Exposure";
    ui_tooltip = "Fixed exposure value used when Eye Adaptation is disabled. Lower values preserve darkness.";
> = 0.1;

uniform float AdaptationStrength <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Eye Adaptation Strength";
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
    ui_min = 1.0; ui_max = 11.0;
    ui_step = 0.1;
    ui_label = "Adaptation Trigger Radius";
    ui_tooltip = "Controls which mip level of the luminance texture is sampled to\n"
                 "compute average scene brightness for eye adaptation.\n\n"
                 "Lower values sample a smaller, more central area of the image.\n"
                 "Higher values pull the sample toward a whole-image average.\n"
                 "At maximum (11), any texture size will have reached its 1x1 mip\n"
                 "and will return the average luminance of the entire frame.\n\n"
                 "Valid top of chain per texture size:\n"
                 "  Full Res 1080p : mip 10   Full Res 1440p : mip 11\n"
                 "  512 x 512      : mip  9   256 x 256      : mip  8\n"
                 "  128 x 128      : mip  7    64 x 64       : mip  6\n\n"
                 "Values beyond the preset's valid range are GPU-clamped to the\n"
                 "last valid level (same behavior as real adaptation shaders).";
> = 8.0;

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
    ui_category_closed = true;
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
    ui_category_closed = true;
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
    ui_category_closed = true;
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
    ui_category_closed = true;
    ui_tooltip = "Controls shadow suppression strength when the scene is brighter than average.\n\n"
                 "1.0 = neutral, identical to the original PHDR behavior (no tonal delta).\n"
                 "> 1.0 = amplifies shadow darkening in bright scene conditions.\n"
                 "< 1.0 = suppresses shadow darkening.";
> = 1.0;

// ---- Adaptive Color Volume / Split Toning ----

uniform bool EnableSplitToning <
    ui_label = "Enable Split Toning";
    ui_category = "Adaptive Color Volume";
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
> = 0.75;

uniform float FrameTime < source = "frametime"; >;

//----------------|
// :: Textures :: |
//----------------|

#define SCALE 2
#define GW (BUFFER_WIDTH / SCALE)
#define GH (BUFFER_HEIGHT / SCALE)

namespace DZPHDR
{

texture TexColor : COLOR;
sampler sTexColor { Texture = TexColor; };

texture TexLuma
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = R16F;
    MipLevels = 12;
};
sampler sTexLuma { Texture = TexLuma; };

texture TexLuma512  { Width = 512; Height = 512; Format = R16F; MipLevels = 10; };
sampler sTexLuma512 { Texture = TexLuma512; };

texture TexLuma256  { Width = 256; Height = 256; Format = R16F; MipLevels = 9; };
sampler sTexLuma256 { Texture = TexLuma256; };

texture TexLuma128  { Width = 128; Height = 128; Format = R16F; MipLevels = 8; };
sampler sTexLuma128 { Texture = TexLuma128; };

texture TexLuma64   { Width = 64;  Height = 64;  Format = R16F; MipLevels = 7; };
sampler sTexLuma64  { Texture = TexLuma64; };

texture TexTempMeans { Width = GW; Height = GH; Format = RG16F; };
sampler sTexTempMeans { Texture = TexTempMeans; };

texture TexStats { Width = GW; Height = GH; Format = RG16F; };
sampler sTexStats { Texture = TexStats; };

texture TexVarI { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; };
sampler sTexVarI { Texture = TexVarI; };

texture TexAdapt { Format = R32F; Width = 1; Height = 1; };
sampler sTexAdapt { Texture = TexAdapt; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

texture TexLastAdapt { Format = R32F; Width = 1; Height = 1; };
sampler sTexLastAdapt { Texture = TexLastAdapt; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

texture TexLastParams { Format = RGBA32F; Width = 1; Height = 1; };
sampler sTexLastParams { Texture = TexLastParams; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

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

//---------------------|
// :: Pixel Shaders :: |
//---------------------|

void PS_Luma(VS_OUTPUT input, out float luma : SV_Target)
{
    luma = GetLuminance(tex2D(sTexColor, input.uv).rgb);
}

float PS_Luma512(VS_OUTPUT input) : SV_Target
{
    float2 ps = float2(1.0 / BUFFER_WIDTH, 1.0 / BUFFER_HEIGHT);
    float v = 0.0;
    v += tex2Dlod(sTexLuma, float4(input.uv + float2(-0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma, float4(input.uv + float2( 0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma, float4(input.uv + float2(-0.5,  0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma, float4(input.uv + float2( 0.5,  0.5) * ps, 0, 0)).r;
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
    float4 uvMip = float4(0.5, 0.5, 0.0, TriggerRadius);
    [branch]
    if (LumaTextureSize == 1) return tex2Dlod(sTexLuma512, uvMip).r;
    if (LumaTextureSize == 2) return tex2Dlod(sTexLuma256, uvMip).r;
    if (LumaTextureSize == 3) return tex2Dlod(sTexLuma128, uvMip).r;
    if (LumaTextureSize == 4) return tex2Dlod(sTexLuma64,  uvMip).r;
    return tex2Dlod(sTexLuma, uvMip).r;
}

void PS_CalcMeansH(VS_OUTPUT input, out float2 mean_horiz : SV_Target)
{
    float2 ps = bb::PixelSize;
    float step = max(1.0, Radius / 3.0);
    float2 sum = 0.0;
    float count = 0.0;

    for (float x = -Radius; x <= Radius; x += step)
    {
        float val = tex2Dlod(sTexLuma, float4(input.uv + float2(x * ps.x, 0), 0, 0)).r;
        sum += float2(val, val * val);
        count += 1.0;
    }
    mean_horiz = sum / count;
}

void PS_CalcMeansV(VS_OUTPUT input, out float2 mean_corr : SV_Target)
{
    float2 ps = bb::PixelSize;
    float step = max(1.0, Radius / 3.0);
    float2 sum = 0.0;
    float count = 0.0;

    for (float y = -Radius; y <= Radius; y += step)
    {
        float2 val = tex2Dlod(sTexTempMeans, float4(input.uv + float2(0, y * ps.y), 0, 0)).rg;
        sum += val;
        count += 1.0;
    }
    mean_corr = sum / count;
}

void PS_GuidedFilterResult(VS_OUTPUT input, out float base_layer : SV_Target)
{
    float2 stats = tex2D(sTexStats, input.uv).rg;
    float mean_I = stats.r;
    float corr_I = stats.g;

    float var_I = corr_I - mean_I * mean_I;
    float a = var_I / (var_I + Epsilon);

    float I = tex2D(sTexLuma, input.uv).r;
    base_layer = lerp(mean_I, I, a);
}

void PS_CalcAdapt(VS_OUTPUT input, out float adapt : SV_Target)
{
    float current = SampleAvgLuma();
    float last    = tex2Dfetch(sTexLastAdapt, 0).r;

    float4 prevParams = tex2Dfetch(sTexLastParams, 0);
    float4 currParams = float4(float(LumaTextureSize), TriggerRadius, 0.5, 0.5);
    bool paramChanged = any(abs(currParams - prevParams) > 1e-4);

    if (paramChanged || AdaptationTime <= 0.0)
    {
        adapt = current;
    }
    else
    {
        float smoothFactor = saturate((FrameTime * 0.001) / AdaptationTime);
        adapt = lerp(last, current, smoothFactor);
    }
    adapt = max(adapt, 1e-5);
}

void PS_SaveParams(VS_OUTPUT input, out float4 save : SV_Target)
{
    save = float4(float(LumaTextureSize), TriggerRadius, 0.5, 0.5);
}

void PS_SaveAdapt(VS_OUTPUT input, out float save : SV_Target)
{
    save = tex2Dfetch(sTexAdapt, 0).r;
}

float3 PS_FinalCombine(VS_OUTPUT input) : SV_Target
{
    float3 original = tex2D(sTexColor, input.uv).rgb;
    float L    = tex2D(sTexLuma, input.uv).r;
    float Base = tex2D(sTexVarI, input.uv).r;

    L    = max(L,    1e-5);
    Base = max(Base, 1e-5);
    float R_val = log(L) - log(Base);

    float sm_manual  = clamp(ManualExposure, 0.01, 0.99);
    float sm_adapt   = EnableAdaptation ? clamp(tex2Dfetch(sTexAdapt, 0).r, 0.01, 0.99) : sm_manual;
    float scene_mean = EnableAdaptation ? lerp(sm_manual, sm_adapt, AdaptationStrength) : sm_manual;

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

    float3 blended = lerp(original, original * ratio, Strength);

    [branch]
    if (EnableAdaptation)
    {
        float adp_luma    = GetLuminance(blended);
        float3 adp_chroma = blended - adp_luma;
        float adp_delta;

        // sm_adapt (not scene_mean) is used here to evaluate raw environment brightness
        // so that AdaptationStrength's lerp does not distort the brightening/darkening threshold.
        if (sm_adapt < 0.5)
        {
            float curve = AdaptationStrength * 10.0 * pow(0.5 - sm_adapt, 4.0);
            adp_delta = AdaptionDelta(
                adp_luma,
                LiftMidtones   - 1.0,
                LiftShadows    - 1.0,
                LiftHighlights - 1.0
            ) * curve;
        }
        else
        {
            float curve = AdaptationStrength * (sm_adapt - 0.5);
            adp_delta = -AdaptionDelta(
                adp_luma,
                PullMidtones   - 1.0,
                PullShadows    - 1.0,
                PullHighlights - 1.0
            ) * curve;
        }

        adp_luma = saturate(adp_luma + adp_delta);
        blended  = saturate(adp_luma + adp_chroma);
    }

    [branch]
    if (EnableSplitToning && (!ScaleTintsWithIntensity || Strength > 0.0))
    {
        float local_luma     = GetLuminance(blended);
        float contrast_ratio = local_luma / (scene_mean + 0.0001);

        float strength_weight         = ScaleTintsWithIntensity ? pow(Strength, 0.75) : 1.0;
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
            blended = lerp(blended, blended * GetShadowTintColor(), final_opacity_S);
        }
    }

    return blended;
}

technique DZ_PerceptualHDR
<
    ui_label = "Perceptual HDR";
>
{
    pass Luma         { VertexShader = PostProcessVS; PixelShader = PS_Luma;              RenderTarget = TexLuma;       }
    pass Luma512      { VertexShader = PostProcessVS; PixelShader = PS_Luma512;           RenderTarget = TexLuma512;    }
    pass Luma256      { VertexShader = PostProcessVS; PixelShader = PS_Luma256;           RenderTarget = TexLuma256;    }
    pass Luma128      { VertexShader = PostProcessVS; PixelShader = PS_Luma128;           RenderTarget = TexLuma128;    }
    pass Luma64       { VertexShader = PostProcessVS; PixelShader = PS_Luma64;            RenderTarget = TexLuma64;     }
    pass CalcAdapt    { VertexShader = PostProcessVS; PixelShader = PS_CalcAdapt;         RenderTarget = TexAdapt;      }
    pass SaveParams   { VertexShader = PostProcessVS; PixelShader = PS_SaveParams;        RenderTarget = TexLastParams; }
    pass SaveAdapt    { VertexShader = PostProcessVS; PixelShader = PS_SaveAdapt;         RenderTarget = TexLastAdapt;  }
    pass CalcMeansH   { VertexShader = PostProcessVS; PixelShader = PS_CalcMeansH;        RenderTarget = TexTempMeans;  }
    pass CalcMeansV   { VertexShader = PostProcessVS; PixelShader = PS_CalcMeansV;        RenderTarget = TexStats;      }
    pass GuidedFilter { VertexShader = PostProcessVS; PixelShader = PS_GuidedFilterResult; RenderTarget = TexVarI;      }
    pass Combine      { VertexShader = PostProcessVS; PixelShader = PS_FinalCombine;                                    }
}

} // namespace DZPHDR