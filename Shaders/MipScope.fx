// MipScope.fx - Mipmap & Luminance Inspector
// Version: 1.0
// Author:  Danyal Zia Khan
// License: MIT
//
// A standalone ReShade debug tool for visualizing how mipmap
// levels and downsampled texture sizes affect luminance.
// Useful for understanding any eye adaptation or auto-exposure
// shader that uses mipmapped luma textures.
//
// Requires: ReShade 6.x, ReShade.fxh only.
//
// Modes:
//   0 - Fullscreen Mip View   : stretch a chosen mip to fill the screen
//   1 - Mip Chain Grid        : display all mip levels simultaneously in a grid
//   2 - Sample Region Overlay : highlight the screen region a texel covers
//   3 - Luminance Heatmap     : false-color luminance visualization

#include "ReShade.fxh"

// UI

uniform int DebugMode <
    ui_type    = "combo";
    ui_label   = "Debug Mode";
    ui_tooltip = "Select which visualization to display.\n\n"
                 "0 - Fullscreen Mip View:\n"
                 "    Stretches the selected mip level to fill the screen.\n\n"
                 "1 - Mip Chain Grid:\n"
                 "    Shows all mip levels simultaneously in a 4-column grid.\n"
                 "    The selected Mip Level cell is highlighted in blue.\n\n"
                 "2 - Sample Region Overlay:\n"
                 "    Draws a box on the scene showing the approximate screen\n"
                 "    region the sampled texel covers at the selected mip.\n"
                 "    The last valid mip always covers 100% of the screen —\n"
                 "    that is correct: at that level the texture is 1x1.\n\n"
                 "3 - Luminance Heatmap:\n"
                 "    Maps luminance to a false-color ramp.";
    ui_items   = "0 - Fullscreen Mip View\0"
                 "1 - Mip Chain Grid\0"
                 "2 - Sample Region Overlay\0"
                 "3 - Luminance Heatmap\0";
> = 0;

uniform int TexturePreset <
    ui_type    = "combo";
    ui_label   = "Texture Size";
    ui_tooltip = "Internal luma texture resolution to inspect.\n\n"
                 "Full Resolution uses your actual screen dimensions.\n"
                 "Fixed sizes simulate how downsampled luma textures behave.\n\n"
                 "Mip level counts per preset:\n"
                 "  Full Res 1080p : 11 levels (indices 0-10)\n"
                 "  Full Res 1440p : 12 levels (indices 0-11)\n"
                 "  512 x 512      : 10 levels (indices 0-9)\n"
                 "  256 x 256      :  9 levels (indices 0-8)\n"
                 "  128 x 128      :  8 levels (indices 0-7)\n"
                 "   64 x 64       :  7 levels (indices 0-6)\n\n"
                 "The last valid mip of any texture is 1x1 pixel, which\n"
                 "by definition represents the average of the entire image.\n"
                 "Requesting a mip beyond the chain (e.g. mip 8 on a\n"
                 "256x256 texture) is clamped by the GPU to the last valid\n"
                 "level — this is normal GPU behavior and is what real\n"
                 "shaders do when they over-request mip levels.";
    ui_items   = "Full Resolution\0"
                 "512 x 512\0"
                 "256 x 256\0"
                 "128 x 128\0"
                 "64 x 64\0";
> = 0;

// Slider max is 11 — the highest valid mip index across all presets
// (Full Res 1440p uses indices 0-11). Lower presets have shorter chains;
// values above their max are GPU-clamped to their last valid level,
// and the grid highlight reflects this by tinting the last real cell.
uniform int MipLevel <
    ui_type    = "slider";
    ui_label   = "Mip Level";
    ui_tooltip = "Which mip level to display/highlight.\n\n"
                 "Valid ranges per preset (values above these are GPU-clamped to last):\n"
                 "  Full Res 1080p : 0-10  (11 levels)\n"
                 "  Full Res 1440p : 0-11  (12 levels)\n"
                 "  512 x 512      : 0-9   (10 levels)\n"
                 "  256 x 256      : 0-8   ( 9 levels)\n"
                 "  128 x 128      : 0-7   ( 8 levels)\n"
                 "   64 x 64       : 0-6   ( 7 levels)\n\n"
                 "In Mode 1 (Grid): the selected mip cell is highlighted blue.\n"
                 "Values beyond the preset's valid chain highlight the last real\n"
                 "cell — because the GPU clamps the sample there too.\n"
                 "Dark teal cells at the end of the grid are empty placeholder\n"
                 "slots (the 4-column layout rounds up to the nearest multiple\n"
                 "of 4); they are intentionally empty, not broken.\n\n"
                 "In Mode 2 (Region Overlay): the overlay shows the approximate\n"
                 "screen coverage of one texel at this mip level. The last valid\n"
                 "mip always reaches 100% coverage (1x1 texel = whole image).\n"
                 "Any mip beyond that also shows 100% — clamped by the GPU.";
    ui_min     = 0;
    ui_max     = 11;
> = 0;

uniform float2 SampleUV <
    ui_type    = "drag";
    ui_label   = "Sample UV";
    ui_tooltip = "The UV coordinate being sampled.\n"
                 "(0.5, 0.5) is the center of the screen.";
    ui_min     = 0.0;
    ui_max     = 1.0;
    ui_step    = 0.005;
> = float2(0.5, 0.5);

uniform bool ShowSamplePoint <
    ui_label   = "Show Sample Point";
    ui_tooltip = "Draw a crosshair at the sampled UV location.";
> = true;

uniform bool ShowRegionOverlay <
    ui_label   = "Show Region Overlay";
    ui_tooltip = "Highlight the approximate screen region covered by\n"
                 "the sampled texel. Only visible in Mode 2.";
> = true;

uniform int HeatmapColorRange <
    ui_type    = "combo";
    ui_label   = "Heatmap Color Ramp";
    ui_tooltip = "Color mapping for Mode 3 (Luminance Heatmap).\n"
                 "Grayscale: black = dark, white = bright.\n"
                 "Rainbow:   blue = dark, through green, to red = bright.";
    ui_items   = "Grayscale\0Rainbow\0";
> = 1;

uniform float GridCellBorder <
    ui_type    = "slider";
    ui_label   = "Grid Cell Border";
    ui_tooltip = "Border thickness between cells in Mode 1 (Mip Chain Grid).";
    ui_min     = 0.001;
    ui_max     = 0.01;
    ui_step    = 0.001;
> = 0.003;

uniform bool GridHighlightSelected <
    ui_label   = "Grid: Highlight Selected Mip";
    ui_tooltip = "In Mode 1, tint the selected Mip Level cell blue.\n"
                 "If the selected mip is beyond the texture's chain,\n"
                 "the last valid cell is highlighted instead —\n"
                 "because that is what the GPU actually reads.";
> = true;

// Textures
// MipLevels = N means the chain has N levels: indices 0..(N-1).
// We declare enough levels to cover the complete natural chain
// for each texture size.
//
//   Full res:  MipLevels=12  -> indices 0..11  (covers up to 4K)
//   512x512:   MipLevels=10  -> indices 0..9
//   256x256:   MipLevels=9   -> indices 0..8
//   128x128:   MipLevels=8   -> indices 0..7
//   64x64:     MipLevels=7   -> indices 0..6
//
// At the last valid index, the texture has been collapsed to 1x1.
// Requesting any index beyond that is GPU-clamped to that 1x1.

texture TexLumaFull
{
    Width      = BUFFER_WIDTH;
    Height     = BUFFER_HEIGHT;
    Format     = R16F;
    MipLevels  = 12;
};
sampler sLumaFull { Texture = TexLumaFull; };

texture TexLuma512
{
    Width      = 512;
    Height     = 512;
    Format     = R16F;
    MipLevels  = 10;
};
sampler sLuma512 { Texture = TexLuma512; };

texture TexLuma256
{
    Width      = 256;
    Height     = 256;
    Format     = R16F;
    MipLevels  = 9;
};
sampler sLuma256 { Texture = TexLuma256; };

texture TexLuma128
{
    Width      = 128;
    Height     = 128;
    Format     = R16F;
    MipLevels  = 8;
};
sampler sLuma128 { Texture = TexLuma128; };

texture TexLuma64
{
    Width      = 64;
    Height     = 64;
    Format     = R16F;
    MipLevels  = 7;
};
sampler sLuma64 { Texture = TexLuma64; };

// Helper functions

float CalcLuminance(float3 c)
{
    return dot(c, float3(0.212656, 0.715158, 0.072186));
}

// Natural mip count of the full-resolution chain: floor(log2(longest axis)) + 1.
// Derived from the real buffer size so the tool reports the true chain length
// (e.g. 11 at 1080p, 12 at 1440p/4K) instead of assuming the declared maximum.
int FullResMipCount()
{
    return int(floor(log2(float(max(BUFFER_WIDTH, BUFFER_HEIGHT))))) + 1;
}

// Number of mip levels (count, not max index) for the selected preset.
// Max valid mip index = GetMipLevelCount() - 1.
int GetMipLevelCount()
{
    switch (TexturePreset)
    {
        case 0:  return FullResMipCount(); // Full res (depends on resolution)
        case 1:  return 10; // 512x512
        case 2:  return 9;  // 256x256
        case 3:  return 8;  // 128x128
        default: return 7;  // 64x64
    }
}

// Sample the selected luma texture at a given mip.
// Requesting a mip beyond the chain is GPU-clamped to the last valid level.
float SampleLuma(float2 uv, float mip)
{
    switch (TexturePreset)
    {
        case 0:  return tex2Dlod(sLumaFull, float4(uv, 0, mip)).r;
        case 1:  return tex2Dlod(sLuma512,  float4(uv, 0, mip)).r;
        case 2:  return tex2Dlod(sLuma256,  float4(uv, 0, mip)).r;
        case 3:  return tex2Dlod(sLuma128,  float4(uv, 0, mip)).r;
        default: return tex2Dlod(sLuma64,   float4(uv, 0, mip)).r;
    }
}

// Base texture dimensions for the selected preset.
float2 GetTexSize()
{
    switch (TexturePreset)
    {
        case 0:  return float2(BUFFER_WIDTH, BUFFER_HEIGHT);
        case 1:  return float2(512,  512);
        case 2:  return float2(256,  256);
        case 3:  return float2(128,  128);
        default: return float2(64,   64);
    }
}

// Rainbow false-color: blue=0.0, green=0.5, red=1.0
float3 HeatColor(float t)
{
    t = saturate(t);
    float3 c;
    c.r = saturate(1.5 - abs(t - 1.0) * 2.0);
    c.g = saturate(1.5 - abs(t - 0.5) * 2.0);
    c.b = saturate(1.5 - abs(t - 0.0) * 2.0);
    return c;
}

float DrawCrosshair(float2 uv, float2 center, float armLen, float thickness)
{
    float2 d = abs(uv - center);
    float  h = step(d.x, armLen) * step(d.y, thickness);
    float  v = step(d.y, armLen) * step(d.x, thickness);
    return saturate(h + v);
}

float DrawRectBorder(float2 uv, float2 lo, float2 hi, float thickness)
{
    float onEdgeX = step(lo.x, uv.x) * step(uv.x, hi.x);
    float onEdgeY = step(lo.y, uv.y) * step(uv.y, hi.y);
    float left    = step(abs(uv.x - lo.x), thickness) * onEdgeY;
    float right   = step(abs(uv.x - hi.x), thickness) * onEdgeY;
    float top     = step(abs(uv.y - lo.y), thickness) * onEdgeX;
    float bottom  = step(abs(uv.y - hi.y), thickness) * onEdgeX;
    return saturate(left + right + top + bottom);
}

// Luma write passes

// Average four luma samples half a source texel apart - a proper 2:1 box
// reduction. Point-sampling the full-res backbuffer straight into each smaller
// texture would skip most source pixels and alias the whole chain, which would
// misrepresent how a real downsampled luma texture actually looks.
float BoxDownsample(sampler src, float2 uv, float2 srcTexel, float srcMip)
{
    float v = 0.0;
    v += tex2Dlod(src, float4(uv + float2(-0.5, -0.5) * srcTexel, 0, srcMip)).r;
    v += tex2Dlod(src, float4(uv + float2( 0.5, -0.5) * srcTexel, 0, srcMip)).r;
    v += tex2Dlod(src, float4(uv + float2(-0.5,  0.5) * srcTexel, 0, srcMip)).r;
    v += tex2Dlod(src, float4(uv + float2( 0.5,  0.5) * srcTexel, 0, srcMip)).r;
    return v * 0.25;
}

void PS_WriteLumaFull(float4 pos : SV_Position, float2 uv : TEXCOORD, out float luma : SV_Target)
{
    luma = CalcLuminance(tex2D(ReShade::BackBuffer, uv).rgb);
}
void PS_WriteLuma512(float4 pos : SV_Position, float2 uv : TEXCOORD, out float luma : SV_Target)
{
    // Pull from the full-res mip nearest 1024 so the box covers the full footprint.
    const float srcMip = max(0.0, ceil(log2(max(BUFFER_WIDTH, BUFFER_HEIGHT) / 1024.0)));
    luma = BoxDownsample(sLumaFull, uv, exp2(srcMip) * ReShade::PixelSize, srcMip);
}
void PS_WriteLuma256(float4 pos : SV_Position, float2 uv : TEXCOORD, out float luma : SV_Target)
{
    luma = BoxDownsample(sLuma512, uv, float2(1.0 / 512.0, 1.0 / 512.0), 0.0);
}
void PS_WriteLuma128(float4 pos : SV_Position, float2 uv : TEXCOORD, out float luma : SV_Target)
{
    luma = BoxDownsample(sLuma256, uv, float2(1.0 / 256.0, 1.0 / 256.0), 0.0);
}
void PS_WriteLuma64(float4 pos : SV_Position, float2 uv : TEXCOORD, out float luma : SV_Target)
{
    luma = BoxDownsample(sLuma128, uv, float2(1.0 / 128.0, 1.0 / 128.0), 0.0);
}

// Debug visualization pass

float4 PS_Debug(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 output = float4(0.0, 0.0, 0.0, 1.0);

    int levelCount    = GetMipLevelCount();
    int maxValidIndex = levelCount - 1;

    // Raw selected mip — passed directly to tex2Dlod so the GPU
    // clamps it if out of range (mirrors real shader behavior).
    float selectedMip = float(MipLevel);

    // For grid highlighting, clamp to the last valid cell.
    // If MipLevel=12 but the chain only goes to 11, we highlight cell 11
    // because that is physically what the sampler reads.
    int highlightCell = min(MipLevel, maxValidIndex);

    // MODE 0 - Fullscreen Mip View
    if (DebugMode == 0)
    {
        float l    = SampleLuma(uv, selectedMip);
        output.rgb = l.xxx;

        if (ShowSamplePoint)
        {
            float cross = DrawCrosshair(uv, SampleUV, 0.015, 0.0018);
            output.rgb  = lerp(output.rgb, float3(0.0, 1.0, 0.2), cross);
        }
    }

    // MODE 1 - Mip Chain Grid
    // Cells 0..(levelCount-1), 4-column layout.
    // Highlighted cell = min(MipLevel, maxValidIndex).
    else if (DebugMode == 1)
    {
        int    cols   = 4;
        int    rows   = (levelCount + cols - 1) / cols;
        float  cellW  = 1.0 / float(cols);
        float  cellH  = 1.0 / float(rows);

        int    col     = int(uv.x / cellW);
        int    row     = int(uv.y / cellH);
        int    thisMip = row * cols + col;

        float2 cellMin = float2(float(col) * cellW, float(row) * cellH);
        float2 cellMax = cellMin + float2(cellW, cellH);

        float border = DrawRectBorder(uv, cellMin, cellMax, GridCellBorder);

        if (thisMip < levelCount)
        {
            float2 cellUV  = (uv - cellMin) / float2(cellW, cellH);
            float  l       = SampleLuma(cellUV, float(thisMip));
            output.rgb     = l.xxx;

            if (GridHighlightSelected && thisMip == highlightCell)
                output.rgb = lerp(output.rgb, float3(0.15, 0.35, 1.0), 0.3);
        }
        else
        {
            // Dark teal: visually distinguishable from real mip cells
            // (which are grayscale) so it is clear these slots are
            // intentionally empty, not corrupted or missing data.
            output.rgb = float3(0.02, 0.07, 0.08);
        }

        output.rgb = lerp(output.rgb, float3(1.0, 1.0, 1.0), border);
    }

    // MODE 2 - Sample Region Overlay
    // One texel at mip M spans (2^M / texWidth) of the image in X
    // and (2^M / texHeight) in Y.
    // When 2^M >= texWidth, frac >= 1.0, which clamps to the full
    // image — this is correct. At that mip the texture is 1x1 and
    // that single texel IS the whole image. Beyond that mip the GPU
    // keeps returning the same 1x1 value, so the region stays at 100%.
    else if (DebugMode == 2)
    {
        float3 scene = tex2D(ReShade::BackBuffer, uv).rgb;
        float  lBase = CalcLuminance(scene);
        output.rgb   = lBase.xxx * 0.55;

        if (ShowRegionOverlay)
        {
            // Snap the box to the actual texel grid at this mip: work out the
            // texture's size at the selected mip, find which texel SampleUV lands
            // in, and outline exactly that texel's screen footprint. At the 1x1
            // mip (or beyond) sizeAtMip collapses to 1 and the box covers the
            // whole image, which is correct.
            float2 texSize   = GetTexSize();
            float2 sizeAtMip = max(floor(texSize / exp2(selectedMip)), 1.0);
            float2 texelIdx  = clamp(floor(SampleUV * sizeAtMip), 0.0, sizeAtMip - 1.0);

            float2 rMin = clamp(texelIdx        / sizeAtMip, 0.0, 1.0);
            float2 rMax = clamp((texelIdx + 1.0) / sizeAtMip, 0.0, 1.0);

            float inRegion = step(rMin.x, uv.x) * step(uv.x, rMax.x)
                           * step(rMin.y, uv.y) * step(uv.y, rMax.y);
            output.rgb = lerp(output.rgb, float3(1.0, 0.88, 0.1), inRegion * 0.4);

            float rectBorder = DrawRectBorder(uv, rMin, rMax, 0.0022);
            output.rgb = lerp(output.rgb, float3(1.0, 0.45, 0.0), rectBorder);
        }

        if (ShowSamplePoint)
        {
            float cross = DrawCrosshair(uv, SampleUV, 0.015, 0.0018);
            output.rgb  = lerp(output.rgb, float3(0.0, 1.0, 0.2), cross);
        }
    }

    // MODE 3 - Luminance Heatmap
    else if (DebugMode == 3)
    {
        float l    = SampleLuma(uv, selectedMip);
        output.rgb = (HeatmapColorRange == 0) ? l.xxx : HeatColor(l);

        if (ShowSamplePoint)
        {
            float cross = DrawCrosshair(uv, SampleUV, 0.015, 0.0018);
            output.rgb  = lerp(output.rgb, float3(1.0, 1.0, 1.0), cross);
        }
    }

    return output;
}

// Technique

technique MipScope
<
    ui_label   = "MipScope";
    ui_tooltip = "Mipmap and luminance inspector for ReShade.\n"
                 "Visualizes how mip levels and texture sizes affect\n"
                 "what a sampler actually reads from a luma texture.";
>
{
    pass WriteLumaFull
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_WriteLumaFull;
        RenderTarget = TexLumaFull;
    }
    pass WriteLuma512
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_WriteLuma512;
        RenderTarget = TexLuma512;
    }
    pass WriteLuma256
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_WriteLuma256;
        RenderTarget = TexLuma256;
    }
    pass WriteLuma128
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_WriteLuma128;
        RenderTarget = TexLuma128;
    }
    pass WriteLuma64
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_WriteLuma64;
        RenderTarget = TexLuma64;
    }
    pass Debug
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_Debug;
    }
}
