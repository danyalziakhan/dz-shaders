// MipScope.fx: mipmap and luminance inspector
// Version: 1.0
// Author:  Danyal Zia Khan
// License: MIT
//
// Shows what an eye adaptation shader actually reads when it samples one mip
// of a luminance texture, at full resolution or at a fixed downsampled size.
//
// Requires ReShade 6.x and ReShade.fxh.

#include "ReShade.fxh"

uniform int DebugMode <
    ui_type    = "combo";
    ui_label   = "Debug Mode";
    ui_tooltip = "0: the selected mip stretched over the screen.\n"
                 "1: every mip in a grid, the selected one tinted blue.\n"
                 "2: the scene, with a box over the area one texel of the\n"
                 "   selected mip covers.\n"
                 "3: luminance in false color.";
    ui_items   = "0 - Fullscreen Mip View\0"
                 "1 - Mip Chain Grid\0"
                 "2 - Sample Region Overlay\0"
                 "3 - Luminance Heatmap\0";
> = 0;

uniform int TexturePreset <
    ui_type    = "combo";
    ui_label   = "Texture Size";
    ui_tooltip = "Luma texture to inspect. Full Resolution matches the screen;\n"
                 "the fixed sizes show how a downsampled luma texture behaves.";
    ui_items   = "Full Resolution\0"
                 "512 x 512\0"
                 "256 x 256\0"
                 "128 x 128\0"
                 "64 x 64\0";
> = 0;

// 11 is the last mip of a full resolution chain on any screen under 4096
// pixels wide. Shorter chains clamp, which is part of what the tool shows.
uniform int MipLevel <
    ui_type    = "slider";
    ui_label   = "Mip Level";
    ui_tooltip = "Mip to show. Last mip of each chain:\n"
                 "  Full res 1080p   10\n"
                 "  Full res 1440p   11\n"
                 "  512 x 512         9\n"
                 "  256 x 256         8\n"
                 "  128 x 128         7\n"
                 "  64 x 64           6\n"
                 "The last mip is 1x1, the average of the whole image. Anything\n"
                 "past it is clamped there by the GPU, as it would be in a real\n"
                 "adaptation shader. Dark teal cells in the grid are unused slots.";
    ui_min     = 0;
    ui_max     = 11;
> = 0;

uniform float2 SampleUV <
    ui_type    = "drag";
    ui_label   = "Sample UV";
    ui_tooltip = "Point being sampled. 0.5, 0.5 is the centre of the screen.";
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
    ui_tooltip = "Mode 2 only: outline the screen area the sampled texel covers.";
> = true;

uniform int HeatmapColorRange <
    ui_type    = "combo";
    ui_label   = "Heatmap Color Ramp";
    ui_tooltip = "Mode 3 only. Rainbow runs blue through green to red; Grayscale\n"
                 "is easier to compare between levels.";
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
    ui_tooltip = "Mode 1 only: tint the selected mip blue. Past the end of the chain\n"
                 "the last cell is tinted, since that is what the GPU reads.";
> = true;

// Each texture declares its complete chain, down to 1x1.
//
// The full resolution chain is floor(log2(longest axis)) + 1 levels. ReShade
// refuses a texture that asks for more levels than its size allows, so the
// count has to follow the screen; a fixed 12 failed below 2048 pixels wide.
#if (BUFFER_WIDTH >= 8192) || (BUFFER_HEIGHT >= 8192)
    #define LUMA_FULL_MIPS 14
#elif (BUFFER_WIDTH >= 4096) || (BUFFER_HEIGHT >= 4096)
    #define LUMA_FULL_MIPS 13
#elif (BUFFER_WIDTH >= 2048) || (BUFFER_HEIGHT >= 2048)
    #define LUMA_FULL_MIPS 12
#elif (BUFFER_WIDTH >= 1024) || (BUFFER_HEIGHT >= 1024)
    #define LUMA_FULL_MIPS 11
#elif (BUFFER_WIDTH >= 512) || (BUFFER_HEIGHT >= 512)
    #define LUMA_FULL_MIPS 10
#else
    #define LUMA_FULL_MIPS 9
#endif

texture TexLumaFull
{
    Width      = BUFFER_WIDTH;
    Height     = BUFFER_HEIGHT;
    Format     = R16F;
    MipLevels  = LUMA_FULL_MIPS;
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

float CalcLuminance(float3 c)
{
    return dot(c, float3(0.212656, 0.715158, 0.072186));
}

// Same count as LUMA_FULL_MIPS, worked out at run time for the grid.
int FullResMipCount()
{
    return int(floor(log2(float(max(BUFFER_WIDTH, BUFFER_HEIGHT))))) + 1;
}

int GetMipLevelCount()
{
    switch (TexturePreset)
    {
        case 0:  return FullResMipCount();
        case 1:  return 10;
        case 2:  return 9;
        case 3:  return 8;
        default: return 7;
    }
}

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

// Blue at 0, green at 0.5, red at 1.
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

// A 2:1 box reduction from four taps half a source texel apart. Point
// sampling the backbuffer into each smaller texture would skip most pixels and
// alias the chain, which is not how a real downsampled luma texture looks.
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
    // Read the full-res mip nearest 1024 so the box covers its whole footprint.
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

float4 PS_Debug(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 output = float4(0.0, 0.0, 0.0, 1.0);

    int levelCount    = GetMipLevelCount();
    int maxValidIndex = levelCount - 1;

    // Passed to tex2Dlod unclamped, so the GPU clamps it as it would for any
    // shader. The grid highlight clamps itself to match.
    float selectedMip = float(MipLevel);
    int highlightCell = min(MipLevel, maxValidIndex);

    // Fullscreen mip view
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

    // Mip chain grid, four columns
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
            // Unused slot. Teal so it cannot be mistaken for a grey mip.
            output.rgb = float3(0.02, 0.07, 0.08);
        }

        output.rgb = lerp(output.rgb, float3(1.0, 1.0, 1.0), border);
    }

    // Sample region overlay
    else if (DebugMode == 2)
    {
        float3 scene = tex2D(ReShade::BackBuffer, uv).rgb;
        float  lBase = CalcLuminance(scene);
        output.rgb   = lBase.xxx * 0.55;

        if (ShowRegionOverlay)
        {
            // Outline the texel SampleUV lands in on this mip's own grid, rather
            // than a box centred on the cursor. At 1x1 it covers the screen.
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

    // Luminance heatmap
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

technique MipScope
<
    ui_label   = "MipScope";
    ui_tooltip = "Shows what a sampler reads from each mip of a luma texture.\n"
                 "Replaces the picture, so switch it off to play.";
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
