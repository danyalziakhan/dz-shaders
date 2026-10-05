// EyeAdaptProbe.fx - Scene Luminance Meter for Measuring In-Game Auto Exposure
// Version: 1.0
// Author:  Danyal Zia Khan
// License: MIT
//
// Renders a meter bar into every frame that encodes the scene's metered
// luminance as a bar length, so it survives being recorded to video and read
// back later. The point is to measure a game's own eye adaptation (how fast
// its auto exposure brightens or darkens the screen), not PHDRPlus's, so this
// effect should run with PHDRPlus and any other tone mapper disabled: point
// it at the raw scene.
//
// Workflow: enable this effect alone, start a screen recording, look at
// something that swings the camera from bright to dark (or the reverse) and
// hold still until the game's exposure settles, then stop recording. Run
// tools/eyeadapt.py on the extracted frames to fit the adaptation curve and
// get a time constant. See that script's docstring for the analysis side.
//
// The meter uses bar length, not color, to carry the value: video codecs
// preserve edges far better than they preserve small per-channel color
// differences, especially under chroma subsampling. Two calibration swatches
// at the ends of the bar are always pure black and pure white, so the reader
// can correct for whatever levels or gamma shift the recording introduces
// instead of assuming the video reproduces 0 and 255 exactly.
//
// Requires: ReShade 6.x, ReShade.fxh only.

#include "ReShade.fxh"

#define REFERENCE_HEIGHT 1080.0

uniform float ProbeMinEV <
    ui_type    = "slider";
    ui_label   = "Meter Floor (EV)";
    ui_tooltip = "Scene luminance mapped to the left end of the bar, in stops\n"
                 "relative to a luma of 1.0. Widen this if the darkest frame\n"
                 "you captured pins the bar at zero.";
    ui_min     = -16.0;
    ui_max     = -1.0;
    ui_step    = 0.5;
> = -10.0;

uniform float ProbeMaxEV <
    ui_type    = "slider";
    ui_label   = "Meter Ceiling (EV)";
    ui_tooltip = "Scene luminance mapped to the right end of the bar, in stops\n"
                 "relative to a luma of 1.0. Widen this if the brightest frame\n"
                 "you captured pins the bar at full.";
    ui_min     = -2.0;
    ui_max     = 8.0;
    ui_step    = 0.5;
> = 2.0;

uniform float TriggerRadius <
    ui_type    = "slider";
    ui_label   = "Metering Radius";
    ui_tooltip = "Mip level of the luminance texture the meter reads, same\n"
                 "meaning as PHDRPlus's Adaptation Trigger Radius. Match the\n"
                 "value you intend to tune PHDRPlus with so this measures the\n"
                 "same region the shader will later meter.";
    ui_min     = 1.0;
    ui_max     = 12.0;
    ui_step    = 0.1;
> = 8.0;

uniform float BarHeightFrac <
    ui_type    = "slider";
    ui_label   = "Bar Height";
    ui_tooltip = "Fraction of screen height the meter occupies.";
    ui_min     = 0.02;
    ui_max     = 0.15;
    ui_step    = 0.005;
> = 0.05;

uniform int BarPosition <
    ui_type    = "combo";
    ui_label   = "Bar Position";
    ui_tooltip = "Move the meter if the default position overlaps a HUD element.";
    ui_items   = "Bottom\0Top\0";
> = 0;

// Calibration swatches at each end read as pure black and pure white so the
// analysis script can correct for levels or gamma the recording introduces
// instead of assuming the video reproduces 0 and 255 exactly.
#define SWATCH_FRAC 0.03

#if (BUFFER_WIDTH >= 4096) || (BUFFER_HEIGHT >= 4096)
    #define LUMA_FULLRES_MIPS 13
#elif (BUFFER_WIDTH >= 2048) || (BUFFER_HEIGHT >= 2048)
    #define LUMA_FULLRES_MIPS 12
#elif (BUFFER_WIDTH >= 1024) || (BUFFER_HEIGHT >= 1024)
    #define LUMA_FULLRES_MIPS 11
#else
    #define LUMA_FULLRES_MIPS 10
#endif

texture TexLuma
{
    Width     = BUFFER_WIDTH;
    Height    = BUFFER_HEIGHT;
    Format    = R16F;
};
sampler sTexLuma { Texture = TexLuma; };

// Log luminance, box averaged down its own mip chain, so a tap at mip N
// reads a geometric mean over the region that mip covers. Matches how
// PHDRPlus meters the scene, so the two give comparable numbers.
texture TexLumaLog
{
    Width     = BUFFER_WIDTH;
    Height    = BUFFER_HEIGHT;
    Format    = R16F;
    MipLevels = LUMA_FULLRES_MIPS;
};
sampler sTexLumaLog { Texture = TexLumaLog; };

float GetLuminance(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

void PS_Luma(float4 pos : SV_Position, float2 uv : TEXCOORD, out float luma : SV_Target)
{
    luma = GetLuminance(tex2D(ReShade::BackBuffer, uv).rgb);
}

void PS_LumaLog(float4 pos : SV_Position, float2 uv : TEXCOORD, out float logLuma : SV_Target)
{
    float luma = tex2Dlod(sTexLuma, float4(uv, 0, 0)).r;
    logLuma = log(max(luma, 1e-4));
}

// Mip N spans 2^N texels whatever the screen is, so the metering tap has to
// shift with resolution or the reading drifts with it, same as PHDRPlus.
float MeteringMip()
{
    return max(0.0, TriggerRadius + log2(float(BUFFER_HEIGHT) / REFERENCE_HEIGHT));
}

float SampleSceneLuma()
{
    return exp(tex2Dlod(sTexLumaLog, float4(0.5, 0.5, 0, MeteringMip())).r);
}

// Distance in bar-fraction space to the nearest one-EV-stop tick, so the
// meter is readable by eye while lining up a shot without needing text.
float DistToNearestTick(float barX, float stopsInRange)
{
    float stopFrac = 1.0 / stopsInRange;
    float nearest  = round(barX / stopFrac) * stopFrac;
    return abs(barX - nearest);
}

float4 PS_Draw(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 scene = tex2D(ReShade::BackBuffer, uv).rgb;

    float barTop = (BarPosition == 0) ? (1.0 - BarHeightFrac) : 0.0;
    float barBot = (BarPosition == 0) ? 1.0 : BarHeightFrac;
    if (uv.y < barTop || uv.y > barBot)
        return float4(scene, 1.0);

    if (uv.x < SWATCH_FRAC)
        return float4(0.0, 0.0, 0.0, 1.0);
    if (uv.x > 1.0 - SWATCH_FRAC)
        return float4(1.0, 1.0, 1.0, 1.0);

    float meterSpan = max(0.5, ProbeMaxEV - ProbeMinEV);
    float sceneLuma = SampleSceneLuma();
    float ev        = log2(max(sceneLuma, 1e-6));
    float frac      = saturate((ev - ProbeMinEV) / meterSpan);

    float barMin = SWATCH_FRAC;
    float barMax = 1.0 - SWATCH_FRAC;
    float barX   = (uv.x - barMin) / (barMax - barMin);

    float3 color  = (barX < frac) ? float3(1.0, 1.0, 1.0) : float3(0.0, 0.0, 0.0);
    float onTick  = step(DistToNearestTick(barX, meterSpan), 0.0015);
    color         = lerp(color, float3(0.5, 0.5, 0.5), onTick * 0.6);

    return float4(color, 1.0);
}

technique EyeAdaptProbe
<
    ui_label   = "Eye Adaptation Probe";
    ui_tooltip = "Draws a calibrated luminance meter bar for measuring a\n"
                 "game's own auto exposure speed. Run with PHDRPlus and any\n"
                 "other tone mapper disabled, record while triggering the\n"
                 "adaptation, then analyze the recording with\n"
                 "tools/eyeadapt.py.";
>
{
    pass Luma
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_Luma;
        RenderTarget = TexLuma;
    }
    pass LumaLog
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_LumaLog;
        RenderTarget = TexLumaLog;
    }
    pass Draw
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_Draw;
    }
}
