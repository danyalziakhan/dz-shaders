/*
    Blood Highlight

    Isolates blood-toned pixels and desaturates everything else, making
    blood stand out without turning the rest of the scene black and white.

    Based on color isolation techniques from the prod80 ReShade Repository:
    https://github.com/prod80/prod80-ReShade-Repository
*/

#include "ReShade.fxh"

namespace dz_BloodHighlight
{
    // Rec. 709 luminance weights.
    static const float3 LUMINANCE_WEIGHTS = float3(0.212656, 0.715158, 0.072186);

    uniform float bloodTone <
        ui_label    = "Blood Tone";
        ui_tooltip  = "Target hue. 0 is dark crimson, as in pooled blood; 0.5 is pure red;\n"
                      "1 is the orange-red of dried blood. The default suits most games.";
        ui_category = "Blood Targeting";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 1.0;
    > = 0.5;

    uniform float bloodHueRange <
        ui_label    = "Detection Range";
        ui_tooltip  = "How wide a slice of hue counts as blood. Raise it if parts of a\n"
                      "splash are missed, lower it if rust or red armour lights up.";
        ui_category = "Blood Targeting";
        ui_type     = "slider";
        ui_min      = 0.01;
        ui_max      = 0.20;
    > = 0.08;

    uniform float bloodSatThreshold <
        ui_label    = "Blood Saturation Threshold";
        ui_tooltip  = "Minimum saturation for a pixel to count as blood. Raise it to drop\n"
                      "dull reds such as rust, worn cloth and brick; lower it if blood is\n"
                      "only partly caught.";
        ui_category = "Blood Targeting";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 1.0;
    > = 0.55;

    uniform float bloodShadowCutoff <
        ui_label    = "Shadow Cutoff";
        ui_tooltip  = "Pixels darker than this are never blood, which keeps near-black\n"
                      "shadow out. The default excludes almost nothing.";
        ui_category = "Blood Targeting";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 1.0;
    > = 0.01;

    uniform float bloodHighlightCutoff <
        ui_label    = "Highlight Cutoff";
        ui_tooltip  = "Pixels brighter than this are never blood, which keeps out fire, UI\n"
                      "and lit red surfaces. Raise it if blood on a bright floor or white\n"
                      "cloth is cut out.";
        ui_category = "Blood Targeting";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 1.0;
    > = 0.40;

    uniform float edgeSoftness <
        ui_label    = "Edge Softness";
        ui_tooltip  = "Width of the ramp on the saturation and highlight gates. Lower gives\n"
                      "a hard edge to the isolation, higher feathers blood into the scene.";
        ui_category = "Blood Targeting";
        ui_type     = "slider";
        ui_min      = 0.01;
        ui_max      = 0.30;
    > = 0.10;

    uniform float backgroundColorStrength <
        ui_label    = "Background Color Strength";
        ui_tooltip  = "Colour kept outside the blood. 1 is untouched, 0 is greyscale. The\n"
                      "default desaturates just enough for blood to stand out.";
        ui_category = "Scene";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 1.0;
    > = 0.9;

    uniform float backgroundBrightness <
        ui_label    = "Background Brightness";
        ui_tooltip  = "Dims everything except blood, so blood reads brighter without its\n"
                      "colour changing. 1 is untouched.";
        ui_category = "Scene";
        ui_type     = "slider";
        ui_min      = 0.2;
        ui_max      = 1.0;
    > = 1.0;

    uniform float maskSmoothing <
        ui_label    = "Mask Smoothing";
        ui_tooltip  = "Blends the mask with a 3x3 blur of itself, which calms the shimmer\n"
                      "of noisy red pixels in motion and softens blood edges a little.\n"
                      "0 is off.";
        ui_category = "Scene";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 1.0;
    > = 0.0;

    uniform float bloodColorIntensity <
        ui_label    = "Blood Color Intensity";
        ui_tooltip  = "Saturation of the isolated blood. 1 leaves it as it was, above 1\n"
                      "makes it more vivid, below 1 greys it.";
        ui_category = "Scene";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 2.0;
    > = 1.2;

    uniform bool showDebugMask <
        ui_label    = "Show Debug Mask";
        ui_tooltip  = "Shows the blood mask, white on black.";
        ui_category = "Debug";
    > = false;

    // RGB to HSV, all three in [0, 1] with red at hue 0. Each gate below tests
    // one axis on its own, which RGB would not allow.
    //
    // Source: http://lolengine.net/blog/2013/07/27/rgb-to-hsv-in-glsl
    float3 rgbToHsv(float3 rgb)
    {
        float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        // Two comparisons put the largest component in q.x without branching.
        float4 p = rgb.g < rgb.b ? float4(rgb.bg, K.wz) : float4(rgb.gb, K.xy);
        float4 q = rgb.r < p.x   ? float4(p.xyw, rgb.r) : float4(rgb.r, p.yzx);

        float d = q.x - min(q.w, q.y); // chroma
        float e = 1.0e-10;             // keeps black from dividing by zero

        return float3(
            abs(q.z + (q.w - q.y) / (6.0 * d + e)), // hue
            d / (q.x + e),                            // saturation
            q.x                                       // value
        );
    }

    // Source: http://lolengine.net/blog/2013/07/27/rgb-to-hsv-in-glsl
    float3 hsvToRgb(float3 hsv)
    {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(frac(hsv.xxx + K.xyz) * 6.0 - K.www);
        return hsv.z * lerp(K.xxx, saturate(p - K.xxx), hsv.y);
    }

    // Blood Tone to a hue within 0.05 either side of red, wrapping below zero
    // so crimson lands near 0.95.
    float bloodToneToTargetHue(float tone)
    {
        float offset = (tone - 0.5) * 0.1;
        return offset < 0.0 ? offset + 1.0 : offset;
    }

    float computeLuminance(float3 color)
    {
        return dot(color, LUMINANCE_WEIGHTS);
    }

    // Smootherstep. Flat to the second derivative at both ends, so the edge of
    // the isolation blends more softly than with smoothstep.
    float quinticSmooth(float x)
    {
        return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
    }

    // How strongly a colour reads as blood, 0 to 1. A function of its own so
    // Mask Smoothing can run it over the neighbours too.
    float BloodMask(float3 color)
    {
        float3 hsv       = rgbToHsv(color);
        float hue        = hsv.x;
        float saturation = hsv.y;
        float brightness = hsv.z;

        float targetHue   = bloodToneToTargetHue(bloodTone);
        float invHueWidth = rcp(bloodHueRange);

        // Hue wraps at red: 0.99 is 0.02 from a target of 0.01, not 0.98, so the
        // distance is also taken one turn either way.
        float3 hueDists;
        hueDists.x = max(1.0 - abs((hue       - targetHue) * invHueWidth), 0.0);
        hueDists.y = max(1.0 - abs((hue + 1.0 - targetHue) * invHueWidth), 0.0);
        hueDists.z = max(1.0 - abs((hue - 1.0 - targetHue) * invHueWidth), 0.0);
        float hueWeight = dot(hueDists, float3(1.0, 1.0, 1.0));

        float satWeight = smoothstep(bloodSatThreshold - edgeSoftness, bloodSatThreshold, saturation);

        float valWeight = smoothstep(0.0, bloodShadowCutoff + 0.001, brightness)
                * (1.0 - smoothstep(bloodHighlightCutoff, bloodHighlightCutoff + edgeSoftness, brightness));

        return quinticSmooth(saturate(hueWeight * satWeight * valWeight));
    }

    float4 PS_BloodHighlight(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
    {
        float3 original = saturate(tex2D(ReShade::BackBuffer, uv).rgb);

        float smoothWeight = BloodMask(original);

        // Only the mask is blurred. The colour still comes from this pixel, so
        // edges soften without red bleeding onto the background.
        [branch]
        if (maskSmoothing > 0.0)
        {
            float blurred = 0.0;
            [unroll]
            for (int y = -1; y <= 1; y++)
            [unroll]
            for (int x = -1; x <= 1; x++)
            {
                float3 c = saturate(tex2D(ReShade::BackBuffer, uv + float2(x, y) * ReShade::PixelSize).rgb);
                blurred += BloodMask(c);
            }
            blurred *= (1.0 / 9.0);
            smoothWeight = lerp(smoothWeight, blurred, maskSmoothing);
        }

        if (showDebugMask)
        {
            return float4(smoothWeight, smoothWeight, smoothWeight, 1.0);
        }

        float luma        = computeLuminance(original);
        float3 grayscale  = float3(luma, luma, luma);
        float3 background = lerp(grayscale, original, backgroundColorStrength) * backgroundBrightness;

        // The boost follows the mask weight. At full strength everywhere, a
        // pixel on the edge of the hue band would blend toward fully boosted
        // blood and leave a visible band at the boundary.
        float3 hsv         = rgbToHsv(original);
        float satBoost     = lerp(1.0, bloodColorIntensity, smoothWeight);
        float3 bloodHsv    = float3(hsv.x, saturate(hsv.y * satBoost), hsv.z);
        float3 bloodColor  = hsvToRgb(bloodHsv);

        float3 result      = lerp(background, bloodColor, smoothWeight);

        return float4(result, 1.0);
    }

    technique dz_BloodHighlight
    <
        ui_label   = "Blood Highlight";
        ui_tooltip = "Keeps blood in full colour and desaturates the rest of the scene.";
    >
    {
        pass BloodIsolation
        {
            VertexShader = PostProcessVS;
            PixelShader  = PS_BloodHighlight;
        }
    }
}
