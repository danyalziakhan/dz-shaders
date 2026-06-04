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
    // Rec. 709 luminance weights. Green is weighted highest because the eye
    // is most sensitive to it; blue the least.
    static const float3 LUMINANCE_WEIGHTS = float3(0.212656, 0.715158, 0.072186);

    uniform float bloodTone <
        ui_label    = "Blood Tone";
        ui_tooltip  = "Shifts the target hue across the blood color spectrum.\n"
                      "Left (0.0): dark crimson, pooled or venous blood.\n"
                      "Center (0.5): pure red, typical bright blood.\n"
                      "Right (1.0): orange-red, dried or coagulated blood.\n\n"
                      "Most games work fine at the default.";
        ui_category = "Blood Targeting";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 1.0;
    > = 0.5;

    uniform float bloodHueRange <
        ui_label    = "Detection Range";
        ui_tooltip  = "How wide a slice of the hue wheel is treated as blood.\n"
                      "Small values catch only pixels very close to the target hue (tight, precise).\n"
                      "Large values catch a broader band of reds and orange-reds (wider, more forgiving).\n\n"
                      "If neighboring blood pixels are not being caught, raise this.\n"
                      "If non-blood reds like rust or red armor are triggering, lower it.";
        ui_category = "Blood Targeting";
        ui_type     = "slider";
        ui_min      = 0.01;
        ui_max      = 0.20;
    > = 0.08;

    uniform float bloodSatThreshold <
        ui_label    = "Blood Saturation Threshold";
        ui_tooltip  = "Minimum saturation a pixel must have to be treated as blood.\n"
                      "Raise to exclude dull or faded reds (rust, worn cloth, dark brick).\n"
                      "Lower if blood looks muted and is not being fully highlighted.";
        ui_category = "Blood Targeting";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 1.0;
    > = 0.55;

    uniform float bloodShadowCutoff <
        ui_label    = "Shadow Cutoff";
        ui_tooltip  = "Pixels darker than this brightness are excluded from blood targeting.\n"
                      "Prevents near-black shadows from being treated as blood.\n"
                      "The default is very permissive. Only raise it if dark areas are picking up.";
        ui_category = "Blood Targeting";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 1.0;
    > = 0.01;

    uniform float bloodHighlightCutoff <
        ui_label    = "Highlight Cutoff";
        ui_tooltip  = "Pixels brighter than this brightness are excluded from blood targeting.\n"
                      "Prevents fire, bright UI elements, and lit red surfaces from triggering.\n"
                      "Lower if non-blood reds are slipping through. Raise if blood on bright\n"
                      "surfaces (white fabric, lit floors) is getting cut out.";
        ui_category = "Blood Targeting";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 1.0;
    > = 0.40;

    uniform float backgroundColorStrength <
        ui_label    = "Background Color Strength";
        ui_tooltip  = "How much color is retained in non-blood areas.\n"
                      "1.0 = fully original colors. 0.0 = completely grayscale.\n"
                      "The default (0.9) applies subtle desaturation so blood stands out\n"
                      "without making the whole scene look stylized.";
        ui_category = "Scene";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 1.0;
    > = 0.9;

    uniform float bloodColorIntensity <
        ui_label    = "Blood Color Intensity";
        ui_tooltip  = "Multiplies the saturation of isolated blood pixels.\n"
                      "1.0 = blood at its natural saturation.\n"
                      "Above 1.0 makes blood more vivid than the original image.\n"
                      "Below 1.0 pulls blood toward gray.";
        ui_category = "Scene";
        ui_type     = "slider";
        ui_min      = 0.0;
        ui_max      = 2.0;
    > = 1.2;


    // RGB to HSV conversion.
    //
    // HSV separates color into three independent axes:
    //   .x  Hue        [0, 1]  position on the color wheel (0/1 = red, 0.33 = green, 0.67 = blue)
    //   .y  Saturation [0, 1]  vividness (0 = gray, 1 = fully saturated)
    //   .z  Value      [0, 1]  brightness (0 = black, 1 = brightest channel at full)
    //
    // Working in HSV lets each isolation gate target one axis cleanly, which
    // is not possible with raw RGB.
    //
    // Source: http://lolengine.net/blog/2013/07/27/rgb-to-hsv-in-glsl
    float3 rgbToHsv(float3 rgb)
    {
        float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        // Two comparisons sort the six channels into a layout where q.x holds
        // the largest component, avoiding explicit per-channel branching.
        float4 p = rgb.g < rgb.b ? float4(rgb.bg, K.wz) : float4(rgb.gb, K.xy);
        float4 q = rgb.r < p.x   ? float4(p.xyw, rgb.r) : float4(rgb.r, p.yzx);

        float d = q.x - min(q.w, q.y); // chroma (spread between brightest and dimmest channel)
        float e = 1.0e-10;             // small epsilon to avoid division by zero on black pixels

        return float3(
            abs(q.z + (q.w - q.y) / (6.0 * d + e)), // hue
            d / (q.x + e),                            // saturation
            q.x                                       // value
        );
    }

    // Inverse of rgbToHsv. Reconstructs an RGB color from HSV components.
    // Source: http://lolengine.net/blog/2013/07/27/rgb-to-hsv-in-glsl
    float3 hsvToRgb(float3 hsv)
    {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(frac(hsv.xxx + K.xyz) * 6.0 - K.www);
        return hsv.z * lerp(K.xxx, saturate(p - K.xxx), hsv.y);
    }

    // Maps the bloodTone slider [0, 1] to a hue value in [0, 1].
    // Center (0.5) is pure red (hue 0.0). Moving left shifts toward dark
    // crimson (hue ~0.95); moving right shifts toward dried orange-red (hue ~0.05).
    float bloodToneToTargetHue(float tone)
    {
        // Remap [0, 1] to a [-0.05, +0.05] offset around red (hue 0.0).
        float offset = (tone - 0.5) * 0.1;
        // Negative offsets wrap back to the [0, 1] hue range (e.g. -0.03 -> 0.97).
        return offset < 0.0 ? offset + 1.0 : offset;
    }

    float computeLuminance(float3 color)
    {
        return dot(color, LUMINANCE_WEIGHTS);
    }

    // Quintic smooth ("smootherstep") — C2 continuous with zero slope at both
    // endpoints. Produces a softer blend at isolation edges than smoothstep.
    float quinticSmooth(float x)
    {
        return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
    }


    float4 PS_BloodHighlight(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
    {
        float4 original  = tex2D(ReShade::BackBuffer, uv);
        original.xyz     = saturate(original.xyz);

        float luma       = computeLuminance(original.xyz);
        float3 hsv       = rgbToHsv(original.xyz);
        float hue        = hsv.x;
        float saturation = hsv.y;
        float brightness = hsv.z;

        float targetHue   = bloodToneToTargetHue(bloodTone);
        float invHueWidth = rcp(bloodHueRange);

        // Three-way hue distance check handles the wraparound at red (hue 0 = hue 1).
        // A pixel at 0.99 is only 0.02 away from a target of 0.01, but direct
        // subtraction would give 0.98. The +1 and -1 variants catch both wrap directions.
        float3 hueDists;
        hueDists.x = max(1.0 - abs((hue       - targetHue) * invHueWidth), 0.0);
        hueDists.y = max(1.0 - abs((hue + 1.0 - targetHue) * invHueWidth), 0.0);
        hueDists.z = max(1.0 - abs((hue - 1.0 - targetHue) * invHueWidth), 0.0);
        float hueWeight = dot(hueDists, 1.0);

        // Saturation gate: soft ramp above the threshold.
        float satWeight = smoothstep(bloodSatThreshold - 0.1, bloodSatThreshold, saturation);

        // Brightness gate: fade in above the shadow floor, fade out above the highlight ceiling.
        float valWeight = smoothstep(bloodShadowCutoff - 0.05, bloodShadowCutoff, brightness)
                        * (1.0 - smoothstep(bloodHighlightCutoff, bloodHighlightCutoff + 0.1, brightness));

        float isolationWeight = hueWeight * satWeight * valWeight;

        float3 grayscale  = float3(luma, luma, luma);
        float3 background = lerp(grayscale, original.xyz, backgroundColorStrength);

        // Scale the saturation boost by the isolation weight so that pixels at the
        // edge of the hue band get a proportional nudge rather than a full jump.
        // Without this, edge pixels lerp between background and a fully-boosted
        // blood color, which creates visible banding at the boundary.
        float smoothWeight = quinticSmooth(isolationWeight);
        float satBoost     = lerp(1.0, bloodColorIntensity, smoothWeight);
        float3 bloodHsv    = float3(hsv.x, saturate(hsv.y * satBoost), hsv.z);
        float3 bloodColor  = hsvToRgb(bloodHsv);

        float3 result      = lerp(background, bloodColor, smoothWeight);

        return float4(result, 1.0);
    }


    technique dz_BloodHighlight
    <
        ui_label   = "Blood Highlight";
        ui_tooltip = "Isolates blood-toned pixels and subtly desaturates the rest of the scene.";
    >
    {
        pass BloodIsolation
        {
            VertexShader = PostProcessVS;
            PixelShader  = PS_BloodHighlight;
        }
    }
}
