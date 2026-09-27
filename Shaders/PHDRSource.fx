/*-----------------------------------------------------------|
| ::                    PHDR Source                        :: |
'------------------------------------------------------------|
|  Turns a game's HDR output into an SDR image for PHDRPlus, |
|  on a plain SDR monitor.                                   |
|                                                            |
|  Needs the HDR Bridge add-on, which lets a game switch on  |
|  HDR when the monitor cannot, and makes Windows show the   |
|  result as SDR.                                            |
|                                                            |
|  Two techniques, placed around PHDRPlus in the list:       |
|    PHDR Source: Tone Map      first, above PHDRPlus        |
|    PHDRPlus                   as for any SDR game          |
|    PHDR Source: Output        last                         |
|                                                            |
|  License: MIT                                              |
'------------------------------------------------------------*/

#if !defined(__RESHADE__) || __RESHADE__ < 50100
    #error "ReShade 5.1+ is required, for BUFFER_COLOR_SPACE"
#endif

// Pixel settings are authored against this screen height and converted at the
// point of use, as in PHDRPlus, so a preset covers the same fraction of any
// monitor.
#define REFERENCE_HEIGHT 1080.0

static const float3 LUMA_709 = float3(0.2126, 0.7152, 0.0722);

float GetLuminance(float3 color)
{
    return dot(color, LUMA_709);
}

float ToPixels(float authored)
{
    return max(1.0, authored * (float(BUFFER_HEIGHT) / REFERENCE_HEIGHT));
}

//---------------------------|
// :: Source Colour Space :: |
//---------------------------|

// 2 is scRGB: linear, BT.709 primaries, 1.0 = 80 nits, in a half float swap
// chain. 3 is HDR10: PQ and BT.2020 in a 10-bit one. Anything else, SDR above
// all, passes straight through, so the effect can stay switched on in a game
// that is not in HDR.
#ifndef BUFFER_COLOR_SPACE
    #define BUFFER_COLOR_SPACE 1
#endif

#if BUFFER_COLOR_SPACE == 2 || BUFFER_COLOR_SPACE == 3
    #define PHDRS_ACTIVE 1
#else
    #define PHDRS_ACTIVE 0
#endif

//----------|
// :: UI :: |
//----------|

uniform float DisplayWhite <
    ui_type = "slider";
    ui_min = 100.0; ui_max = 1000.0;
    ui_step = 5.0;
    ui_label = "Display White";
    ui_category = "Tone Mapping";
    ui_tooltip = "Nits that SDR white stands for. Higher leaves more room for\n"
                 "highlights and darkens the picture.";
> = 450.0;

uniform float Exposure <
    ui_type = "slider";
    ui_min = -3.0; ui_max = 3.0;
    ui_step = 0.05;
    ui_label = "Exposure";
    ui_category = "Tone Mapping";
    ui_tooltip = "Brightens or darkens the HDR frame, in stops. The white point moves\n"
                 "with it, so highlights keep their detail.";
> = 0.6;

uniform float AutoExposureBrighten <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
    ui_label = "Auto Exposure: Brighten";
    ui_category = "Tone Mapping";
    ui_tooltip = "How far a scene darker than the Key is brightened toward it. 0 keeps\n"
                 "the game's own exposure, 1 lifts every dark scene to the Key.";
> = 0.2;

uniform float AutoExposureDarken <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
    ui_label = "Auto Exposure: Darken";
    ui_category = "Tone Mapping";
    ui_tooltip = "How far a scene brighter than the Key is darkened toward it. 0 keeps\n"
                 "the game's own exposure, 1 holds every bright scene at the Key.";
> = 0.2;

uniform float AutoExposureKey <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 200.0;
    ui_step = 0.5;
    ui_label = "Auto Exposure Key";
    ui_category = "Tone Mapping";
    ui_tooltip = "Average scene brightness, in nits, that Auto Exposure leaves alone.\n"
                 "Darker scenes are lifted toward it, brighter ones pulled down.";
> = 8.0;

uniform float HighlightAdaptation <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
    ui_label = "Highlight Adaptation";
    ui_category = "Tone Mapping";
    ui_tooltip = "Darkens the picture when a bright light fills the view, the sun or a\n"
                 "lamp at night, the way eyes adapt to it. 0 meters the average only.";
> = 0.35;

uniform float AdaptBrighter <
    ui_type = "slider";
    ui_min = 0.05; ui_max = 3.0;
    ui_step = 0.05;
    ui_label = "Adapt to Brighter";
    ui_category = "Tone Mapping";
    ui_tooltip = "Seconds the exposure takes to settle when the view gets brighter.";
> = 0.4;

uniform float AdaptDarker <
    ui_type = "slider";
    ui_min = 0.05; ui_max = 10.0;
    ui_step = 0.05;
    ui_label = "Adapt to Darker";
    ui_category = "Tone Mapping";
    ui_tooltip = "Seconds the exposure takes to settle when the view gets darker. Eyes\n"
                 "take longer to adapt to the dark than to the light.";
> = 1.5;

uniform float HighlightColour <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
    ui_label = "Highlight Colour";
    ui_category = "Tone Mapping";
    ui_tooltip = "0 lets bright colours bleach toward white as an SDR grade does,\n"
                 "1 keeps their hue and saturation: cloud and sun detail.";
> = 1.0;

uniform float Saturation <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Saturation";
    ui_category = "Tone Mapping";
    ui_tooltip = "Colour gain after tone mapping. 1.0 keeps the HDR frame's own colour.";
> = 1.0;

uniform float ShadowContrast <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.5;
    ui_step = 0.05;
    ui_label = "Shadow Contrast";
    ui_category = "Tone Mapping";
    ui_tooltip = "Steepens the tones below the scene's average brightness, the way an\n"
                 "SDR grade does, for more texture in the shadows. 0 is off.";
> = 0.0;

uniform float ShadowSpan <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Shadow Span";
    ui_category = "Tone Mapping";
    ui_tooltip = "How far below the scene's average, in stops, Shadow Contrast reaches\n"
                 "before it hands the deepest shadows back unchanged.";
> = 5.0;

uniform float ShadowLift <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 3.0;
    ui_step = 0.05;
    ui_label = "Shadow Lift";
    ui_category = "Tone Mapping";
    ui_tooltip = "Raises the deepest shadows, which the tone curve otherwise passes\n"
                 "through at their true brightness. Black stays black. 0 is off.";
> = 0.0;

uniform bool EnableHdrDeband <
    ui_label = "Enable";
    ui_category = "Debanding: HDR Frame";
    ui_tooltip = "Repairs the steps many games leave in smooth skies and glows of their\n"
                 "HDR output, before tone mapping makes them visible.";
> = true;

uniform float HdrDebandThreshold <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Threshold";
    ui_category = "Debanding: HDR Frame";
    ui_tooltip = "How flat an area must be to count as a band, in steps of 4% brightness.";
> = 5.0;

uniform float HdrDebandRadius <
    ui_type = "slider";
    ui_min = 4.0; ui_max = 64.0;
    ui_step = 1.0;
    ui_label = "Radius";
    ui_category = "Debanding: HDR Frame";
    ui_tooltip = "How far the first pass looks for the true value of a flat area, in\n"
                 "pixels at 1080p. Later passes reach further.";
> = 32.0;

uniform int HdrDebandPasses <
    ui_type = "slider";
    ui_min = 1; ui_max = 4;
    ui_label = "Passes";
    ui_category = "Debanding: HDR Frame";
    ui_tooltip = "How many passes, each reaching further and judging more strictly.";
> = 3;

uniform int HdrDebandSamples <
    ui_type = "combo";
    ui_items = "8 samples\0"
               "16 samples\0"
               "24 samples\0"
               "32 samples\0";
    ui_label = "Samples";
    ui_category = "Debanding: HDR Frame";
    ui_tooltip = "Samples per pass, spread over a disc.";
> = 1;

uniform float HdrDebandDetail <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 4.0;
    ui_step = 0.05;
    ui_label = "Detail Guard";
    ui_category = "Debanding: HDR Frame";
    ui_tooltip = "How much pixel-to-pixel variation marks an area as texture and puts it\n"
                 "out of reach. 0 disables the guard.";
> = 0.85;

uniform float HdrDebandCorrection <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Correction Limit";
    ui_category = "Debanding: HDR Frame";
    ui_tooltip = "Furthest the debander may move a pixel, in steps of 4% brightness.";
> = 6.0;

uniform float ColourDeband <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Colour Deband";
    ui_category = "Debanding: HDR Frame";
    ui_tooltip = "How much harder colour is smoothed than brightness. Raise it if skies\n"
                 "show coloured contours; 1 treats both alike.";
> = 1.0;

uniform bool EnableDeband <
    ui_label = "Enable";
    ui_category = "Debanding: SDR Frame";
    ui_tooltip = "Repairs banding in the SDR frame, after PHDRPlus. What PHDRPlus changed\n"
                 "and what it left alone are judged separately, below.";
> = true;

uniform float DebandMaxCorrection <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Correction Limit";
    ui_category = "Debanding: SDR Frame";
    ui_tooltip = "Furthest the debander may move a pixel, in 8-bit steps.";
> = 2.0;

uniform float DebandSplit <
    ui_type = "slider";
    ui_min = 0.25; ui_max = 8.0;
    ui_step = 0.05;
    ui_label = "Split Point";
    ui_category = "Debanding: SDR Frame";
    ui_tooltip = "How far PHDRPlus must have moved a pixel, in 8-bit steps, before it is\n"
                 "handed to the Shader Effect settings instead of the Source Image ones.";
> = 1.0;

uniform int DebandTaps <
    ui_type = "combo";
    ui_items = "8 samples\0"
               "16 samples\0"
               "24 samples\0"
               "32 samples\0";
    ui_label = "Samples";
    ui_category = "Debanding: SDR Frame";
    ui_tooltip = "Samples per pass, spread over a disc.";
> = 1;

uniform bool EnableDebandEffect <
    ui_label = "Enable";
    ui_category = "Debanding: Shader Effect";
    ui_tooltip = "Deband what PHDRPlus changed.";
> = true;

uniform float DebandEffectThreshold <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Threshold";
    ui_category = "Debanding: Shader Effect";
    ui_tooltip = "How flat an area must be to count as a band, in 8-bit steps.";
> = 1.75;

uniform float DebandEffectRadius <
    ui_type = "slider";
    ui_min = 4.0; ui_max = 64.0;
    ui_step = 1.0;
    ui_label = "Radius";
    ui_category = "Debanding: Shader Effect";
    ui_tooltip = "How far the first pass looks for the true value of a flat area, in\n"
                 "pixels at 1080p. Later passes reach further.";
> = 13.0;

uniform int DebandEffectIterations <
    ui_type = "slider";
    ui_min = 1; ui_max = 4;
    ui_label = "Passes";
    ui_category = "Debanding: Shader Effect";
    ui_tooltip = "How many passes, each reaching further and judging more strictly.";
> = 2;

uniform float DebandEffectDetail <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 4.0;
    ui_step = 0.05;
    ui_label = "Detail Guard";
    ui_category = "Debanding: Shader Effect";
    ui_tooltip = "How much pixel-to-pixel variation marks an area as texture and puts it\n"
                 "out of reach. 0 disables the guard.";
> = 1.0;

uniform bool EnableDebandSource <
    ui_label = "Enable";
    ui_category = "Debanding: Source Image";
    ui_tooltip = "Deband the tone mapped frame where PHDRPlus left it alone.";
> = true;

uniform float DebandSourceThreshold <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Threshold";
    ui_category = "Debanding: Source Image";
    ui_tooltip = "How flat an area must be to count as a band, in 8-bit steps.";
> = 1.65;

uniform float DebandSourceRadius <
    ui_type = "slider";
    ui_min = 4.0; ui_max = 64.0;
    ui_step = 1.0;
    ui_label = "Radius";
    ui_category = "Debanding: Source Image";
    ui_tooltip = "How far the first pass looks for the true value of a flat area, in\n"
                 "pixels at 1080p. Later passes reach further.";
> = 12.0;

uniform int DebandSourceIterations <
    ui_type = "slider";
    ui_min = 1; ui_max = 4;
    ui_label = "Passes";
    ui_category = "Debanding: Source Image";
    ui_tooltip = "How many passes, each reaching further and judging more strictly.";
> = 1;

uniform float DebandSourceDetail <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 4.0;
    ui_step = 0.05;
    ui_label = "Detail Guard";
    ui_category = "Debanding: Source Image";
    ui_tooltip = "How much pixel-to-pixel variation marks an area as texture and puts it\n"
                 "out of reach. 0 disables the guard.";
> = 0.85;

uniform bool EnableDithering <
    ui_label = "Enable Dithering";
    ui_category = "Output";
    ui_tooltip = "Adds a sub-level noise pattern so gradients survive Windows cutting\n"
                 "the picture to 8 bits on its way to the monitor.";
> = true;

uniform float DitherStrength <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 3.0;
    ui_step = 0.01;
    ui_label = "Dither Strength";
    ui_category = "Output";
    ui_tooltip = "Dither amplitude in 8-bit steps. 1.0 is what the maths asks for.";
> = 2.0;

uniform bool DebugMeter <
    ui_label = "Debug Meter";
    ui_category = "Output";
    ui_tooltip = "Bars in the top left corner: scene average and bright level in nits,\n"
                 "measured peak in nits, and exposure gain in stops.";
> = false;

uniform bool DebugDeband <
    ui_label = "Debug Deband";
    ui_category = "Output";
    ui_tooltip = "Shows where the SDR frame debanding moved pixels, one grey level per\n"
                 "half an 8-bit step.";
> = false;

uniform float FrameTime < source = "frametime"; >;
uniform int FrameCount < source = "framecount"; >;

// Windows cuts the picture to 8 bits on its way to an SDR display whatever the
// swap chain holds, so that is the step the dither has to hide.
static const float OutputSteps = 255.0;

// Layout of the blue noise atlas, shared with PHDRPlus. Kept in sync with
// tools/make_stbn.py.
#define STBN_SIZE  64
#define STBN_COLS  8
#define STBN_DEPTH 32

// Enough mip levels for a full resolution chain to reach 1x1.
#if (BUFFER_WIDTH >= 4096) || (BUFFER_HEIGHT >= 4096)
    #define METER_MIPS 13
#elif (BUFFER_WIDTH >= 2048) || (BUFFER_HEIGHT >= 2048)
    #define METER_MIPS 12
#elif (BUFFER_WIDTH >= 1024) || (BUFFER_HEIGHT >= 1024)
    #define METER_MIPS 11
#elif (BUFFER_WIDTH >= 512) || (BUFFER_HEIGHT >= 512)
    #define METER_MIPS 10
#else
    #define METER_MIPS 9
#endif

void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
{
    texcoord.x = (id == 2) ? 2.0 : 0.0;
    texcoord.y = (id == 1) ? 2.0 : 0.0;
    position = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

namespace PHDRSource
{
    texture TexColor : COLOR;
    sampler sTexColor
    {
        Texture = TexColor;
    };

    texture TexBlueNoise < source = "dz_stbn_512x256.png"; >
    {
        Width  = 512;
        Height = 256;
        Format = RGBA8;
    };

    sampler sTexBlueNoise
    {
        Texture   = TexBlueNoise;
        AddressU  = WRAP;
        AddressV  = WRAP;
        MinFilter = POINT;
        MagFilter = POINT;
        MipFilter = POINT;
    };

#if PHDRS_ACTIVE
    // The game's frame decoded to scRGB once, with invalid pixels repaired, so
    // the debander's many taps neither decode PQ again nor read a NaN. The
    // second mip is for the debander's wider passes.
    texture TexSource
    {
        Width     = BUFFER_WIDTH;
        Height    = BUFFER_HEIGHT;
        Format    = RGBA16F;
        MipLevels = 2;
    };

    sampler sTexSource
    {
        Texture = TexSource;
    };

    // The debanded HDR frame, in scRGB, held back one pass so the metering and
    // the tone map both read the repaired image.
    texture TexHdr
    {
        Width  = BUFFER_WIDTH;
        Height = BUFFER_HEIGHT;
        Format = RGBA16F;
    };

    sampler sTexHdr
    {
        Texture = TexHdr;
    };

    // The tone mapped frame as PHDRPlus received it. Output compares against it
    // to tell what PHDRPlus changed from what it left alone.
    texture TexProxy
    {
        Width  = BUFFER_WIDTH;
        Height = BUFFER_HEIGHT;
        Format = RGBA16F;
    };

    sampler sTexProxy
    {
        Texture = TexProxy;
    };

    // .r is the brightest channel in scRGB units, .g log luminance in nits. The
    // mip chain box-averages both into blocks: the brightest block gives a peak
    // that ignores single hot pixels, and the mean of .g a geometric mean.
    texture TexMeter
    {
        Width     = BUFFER_WIDTH;
        Height    = BUFFER_HEIGHT;
        Format    = RGBA16F;
        MipLevels = METER_MIPS;
    };

    sampler sTexMeter
    {
        Texture = TexMeter;
    };

    // Per tile of a 16 x 16 grid: the brightest block, and the sum of log
    // luminance over its blocks, so the final reduction reads 256 values.
    texture TexTiles
    {
        Width  = 16;
        Height = 16;
        Format = RGBA32F;
    };

    sampler sTexTiles
    {
        Texture   = TexTiles;
        MinFilter = POINT;
        MagFilter = POINT;
        MipFilter = POINT;
    };

    // .x = log peak nits, .y = log average nits, .z = log of the centre-weighted
    // bright level in nits, all smoothed over time. .w is 1 once written, so the
    // first frame starts from its own reading.
    texture TexStats
    {
        Width  = 1;
        Height = 1;
        Format = RGBA32F;
    };

    sampler sTexStats
    {
        Texture   = TexStats;
        MinFilter = POINT;
        MagFilter = POINT;
        MipFilter = POINT;
    };

    texture TexStatsLast
    {
        Width  = 1;
        Height = 1;
        Format = RGBA32F;
    };

    sampler sTexStatsLast
    {
        Texture   = TexStatsLast;
        MinFilter = POINT;
        MagFilter = POINT;
        MipFilter = POINT;
    };
#endif

    struct VS_OUTPUT
    {
        float4 pos : SV_POSITION;
        float2 uv  : TEXCOORD0;
    };

    static const float2 PixelSize  = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    static const float2 ScreenSize = float2(BUFFER_WIDTH, BUFFER_HEIGHT);

//-----------------|
// :: Functions :: |
//-----------------|

// One voxel of the blue noise volume for this pixel, on the given slice. The
// stored bytes are rank order, so shifting to the centre of each bin turns the
// 256 levels into an unbiased [0,1) rather than a ramp that reaches both ends.
float3 SampleBlueNoise(int2 pixel, int slice)
{
    int2 cell  = int2(slice % STBN_COLS, slice / STBN_COLS);
    int2 coord = cell * STBN_SIZE + (pixel & int2(STBN_SIZE - 1, STBN_SIZE - 1));
    float3 raw = tex2Dfetch(sTexBlueNoise, coord).rgb;
    return (raw * 255.0 + 0.5) / 256.0;
}

// Reshape a uniform sample into a triangular one over [-0.5, 1.5]. Remapped,
// not summed: a sum of two lookups averages away the pattern's arrangement.
float ReshapeUniformToTriangle(float v)
{
    v = frac(v + 0.5);
    float orig = v * 2.0 - 1.0;
    float rnd  = (orig == 0.0) ? -1.0 : (orig * rsqrt(abs(orig)));
    return rnd - sign(orig) + 0.5;
}

// The sRGB piecewise curve, both ways. Measured: DWM encodes an scRGB swap
// chain for an SDR display with exactly this curve.
float3 SrgbToLinear(float3 c)
{
    float3 lo = c / 12.92;
    float3 hi = pow((c + 0.055) / 1.055, 2.4);
    return float3(c.r <= 0.04045 ? lo.r : hi.r,
                  c.g <= 0.04045 ? lo.g : hi.g,
                  c.b <= 0.04045 ? lo.b : hi.b);
}

float3 LinearToSrgb(float3 c)
{
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    return float3(c.r <= 0.0031308 ? lo.r : hi.r,
                  c.g <= 0.0031308 ? lo.g : hi.g,
                  c.b <= 0.0031308 ? lo.b : hi.b);
}

#if PHDRS_ACTIVE
// SMPTE ST 2084, nits to signal and back.
float PqEncode(float nits)
{
    float y = pow(max(nits, 0.0) / 10000.0, 0.1593017578125);
    return pow((0.8359375 + 18.8515625 * y) / (1.0 + 18.6875 * y), 78.84375);
}

float PqDecode(float e)
{
    float p = pow(max(e, 0.0), 1.0 / 78.84375);
    return 10000.0 * pow(max(p - 0.8359375, 0.0) / max(18.8515625 - 18.6875 * p, 1e-6), 1.0 / 0.1593017578125);
}

// The game's frame as scRGB, whichever HDR form it arrived in. HDR10 is PQ in
// BT.2020, decoded to nits and converted to BT.709; a colour outside BT.709
// comes out with a negative channel, as it would in scRGB.
float3 DecodeSource(int2 pixel)
{
    float3 c = tex2Dfetch(sTexColor, clamp(pixel, int2(0, 0), int2(BUFFER_WIDTH - 1, BUFFER_HEIGHT - 1))).rgb;
#if BUFFER_COLOR_SPACE == 3
    float3 nits = float3(PqDecode(c.r), PqDecode(c.g), PqDecode(c.b));
    c = float3(dot(nits, float3( 1.6604910, -0.5876411, -0.0728499)),
               dot(nits, float3(-0.1245505,  1.1328999, -0.0083494)),
               dot(nits, float3(-0.0181508, -0.1005789,  1.1187297))) / 80.0;
#endif
    return c;
}

// A float swap chain can hold NaN and infinity, which some renderers leave in
// single pixels for a frame at a time. Clamping them is not enough: min and max
// turn a NaN channel into one of the bounds, the gamut step then zeroes it and
// keeps the others, and a pixel whose green and blue were NaN comes out pure
// red, flickering as it comes and goes. The exponent bits are tested directly,
// since without strict IEEE mode the compiler may fold isnan away. Anything
// beyond 10000 in scRGB, 800000 nits, is an overflow rather than a light.
bool Invalid(float3 c)
{
    uint3 e = asuint(c) & 0x7F800000u;
    return any(e == 0x7F800000u) || any(abs(c) > 10000.0);
}

float3 ReadScRgb(float2 uv)
{
    return tex2Dlod(sTexSource, float4(uv, 0.0, 0.0)).rgb;
}

// A colour with a negative channel is outside BT.709. This is the shape of the
// ACES reference gamut compression: each channel's distance from the brightest
// one is left alone up to a threshold, and the stretch from there out to a limit
// is squeezed into what is left below the gamut edge. The brightest channel
// never moves, so saturated sea and foliage end up on the edge at full
// strength instead of pulled toward grey. The limits are how far the BT.2020
// primaries sit outside BT.709, so anything a game can send lands inside.
static const float3 GamutThreshold = float3(0.95, 0.95, 0.95);
static const float3 GamutLimit     = float3(1.594, 1.087, 1.117);
static const float  GamutPower     = 1.2;

float3 CompressGamut(float3 c)
{
    float ach = max(max(c.r, c.g), c.b);
    if (ach <= 0.0)
        return 0.0;

    float3 d     = (ach - c) / ach;
    float3 range = GamutLimit - GamutThreshold;
    float3 scale = range / pow(pow((1.0 - GamutThreshold) / range, -GamutPower) - 1.0, 1.0 / GamutPower);
    float3 over  = max(d - GamutThreshold, 0.0) / scale;
    d = min(d, GamutThreshold) + scale * over / pow(1.0 + pow(over, GamutPower), 1.0 / GamutPower);

    // Past the limit the distance is still above 1, so clamp what remains.
    return max(ach - d * ach, 0.0);
}

// ITU-R BT.2390 EETF: maps [0, src_peak] onto [0, dst_peak], both in nits. In
// PQ, where steps are perceptually even, it is the identity up to a knee at
// 1.5 * target - 0.5 of the source range and a Hermite spline above that,
// arriving at the target peak with zero slope. Anything above the source peak
// clips there. With the target at or above the source the knee sits past the
// top, so a dim scene passes through at its own brightness.
float Bt2390(float nits, float src_peak, float dst_peak)
{
    float src_e  = PqEncode(src_peak);
    float e      = min(PqEncode(nits) / src_e, 1.0);
    float target = PqEncode(dst_peak) / src_e;
    float ks     = 1.5 * target - 0.5;

    if (e > ks)
    {
        float t  = (e - ks) / (1.0 - ks);
        float t2 = t * t;
        float t3 = t2 * t;
        e = (2.0 * t3 - 3.0 * t2 + 1.0) * ks
          + (t3 - 2.0 * t2 + t) * (1.0 - ks)
          + (-2.0 * t3 + 3.0 * t2) * target;
    }
    return PqDecode(e * src_e);
}

// Metering constants. The floor keeps black bars and night sky from dragging
// the log average to nothing. A rising peak is followed quickly because until
// the filter catches up it clips; a falling one can take its time.
static const float MeterFloor   = 0.1;  // nits
static const float MeterTime    = 0.5;  // seconds
static const float PeakRiseTime = 0.1;  // seconds
static const float AutoMaxStops = 3.0;

// Below the knee BT.2390 passes nits straight through, which leaves the
// deepest shadows well under where an SDR grade usually puts them, most
// visibly in backlit scenes. This lifts the brightest channel by 1 + Shadow
// Lift at black, easing back to no change at ToeEnd of white with a matching
// slope there, and scales the other two with it so hue and saturation hold.
static const float ToeEnd = 0.05;

// Linear SDR level Shadow Contrast never darkens below, about code 2 in sRGB.
static const float ShadowFloor = 0.0005;

float3 Toe(float3 c)
{
    float u = saturate(max(max(c.r, c.g), c.b) / ToeEnd);
    return c * (1.0 + ShadowLift * (1.0 - u) * (1.0 - u));
}

// Manual exposure, auto exposure on the average, and highlight adaptation, in
// stops. A log average hardly moves for a small bright area however intense it
// is, which is why looking at the sun barely darkened the picture. The bright
// level is a centre-weighted linear average, which a bright area does move,
// and its lead over the log average is how much of the view is taken by
// bright light. About a stop of lead is ordinary in any scene, so only what is
// beyond that darkens, and scenes with no standout light are left alone.
static const float HighlightFreeStops = 1.0;

float GainStops(float4 stats)
{
    // Separate strengths either side of the Key, so dark scenes can be lifted
    // toward it without pulling daylight down by the same measure. Exposure
    // scales every tone alike and keeps texture, where a shadow curve that
    // lifts the dark end compresses it.
    float to_key  = log2(AutoExposureKey / exp(stats.y));
    float auto_ev = to_key * (to_key > 0.0 ? AutoExposureBrighten : AutoExposureDarken);
    float lead    = max((stats.z - stats.y) / 0.6931472 - HighlightFreeStops, 0.0);
    return Exposure + clamp(auto_ev - HighlightAdaptation * lead, -AutoMaxStops, AutoMaxStops);
}

// scRGB to a gamma encoded SDR image, for PHDRPlus to treat as the game's own.
// stats is TexStats: smoothed log peak, log average and log bright level.
float3 ToneMap(float3 scrgb, float4 stats)
{
    float  gain = exp2(GainStops(stats));
    float3 nits = CompressGamut(scrgb) * (80.0 * gain);

    // The measured peak moves with the exposure, so it still lands on white and
    // only what sits below it gets brighter or darker.
    float white = DisplayWhite;
    float peak  = max(exp(stats.x) * gain, white);

    // Per channel, a bright colour runs its strongest channel into the knee
    // first and bleaches toward white. Curving the brightest channel and
    // scaling the other two with it keeps hue and saturation instead. Neither
    // can pass white.
    float3 per_channel = float3(Bt2390(nits.r, peak, white),
                                Bt2390(nits.g, peak, white),
                                Bt2390(nits.b, peak, white));
    float  m        = max(max(nits.r, nits.g), nits.b);
    float3 hue_kept = nits * (Bt2390(m, peak, white) / max(m, 1e-6));
    float3 c        = lerp(per_channel, hue_kept, HighlightColour) / white;

    // An SDR grade is steeper in the shadows than BT.2390, which passes them
    // through unchanged. With Shadow Lift at 0 and Exposure doing the
    // brightening, Odyssey's HDR shadows already match its SDR frame, and each
    // step of this pushes more of the frame toward black, so it is off by
    // default and there for games that grade harder. It steepens the stops
    // just below the scene average and hands the slope back further down, so
    // the average and the deepest shadows both stay where they were. With x
    // the stops below the average over Shadow Span, the offset is -contrast *
    // span * x^2 exp(-x^2): no crease at the average, the deepest dip one span
    // down.
    // Monotonic up to about 2.5.
    //
    // Stops from the average say nothing about how close a pixel is to black.
    // Black Flag's dim HDR output lost 6% of a frame to code 2 or below with
    // the full dip. So the span shrinks to fit between the average and
    // ShadowFloor, and the dip d is rolled off against h, the stops a pixel has
    // left above the floor: d (1 - exp(-h/d)) never exceeds h.
    if (ShadowContrast > 0.0)
    {
        float y    = max(GetLuminance(c), 1e-7);
        float avg  = max(exp(stats.y) * gain / white, 1e-6);
        float span = clamp(log2(avg / ShadowFloor) * 0.5, 0.5, ShadowSpan);
        float x    = max(-log2(y / avg), 0.0) / span;
        float d    = ShadowContrast * span * x * x * exp(-x * x);
        float h    = max(log2(y / ShadowFloor), 0.0);
        c *= exp2(-d * (1.0 - exp(-h / max(d, 1e-6))));
    }

    c = Toe(c);

    // Saturation about luminance in linear light. Raising it can push a channel
    // below zero, which the gamut step brings back to the edge, or past 1.0,
    // which is pulled toward luminance until it fits.
    float Y = GetLuminance(c);
    c = CompressGamut(Y + (c - Y) * Saturation);

    // Pull anything past white toward luminance until it fits. A pixel whose
    // luminance is itself past white has no colour left to give and is white.
    Y = GetLuminance(c);
    float hi = max(max(c.r, c.g), c.b);
    if (Y >= 1.0)
        c = 1.0;
    else if (hi > 1.0)
        c = Y + (c - Y) * ((1.0 - Y) / (hi - Y));

    return LinearToSrgb(saturate(c));
}

float3 SoftLimit(float3 v, float limit)
{
    float3 a    = abs(v);
    float knee  = limit * 0.5;
    float3 over = max(a - knee, 0.0);
    return sign(v) * min(a, knee + over * knee / (knee + over));
}

// Many games' HDR output arrives already banded, each channel stepping on its
// own by 1 to 2%, which tone mapping turns into coloured contours two or three
// SDR levels tall. A step that size is a ratio, so the debander runs on the log
// of each channel. One step in its settings is 4%: Odyssey dithers its band
// edges, and at 1% the Detail Guard read that dither as texture and left the
// bands alone.
static const float BandStep  = 0.04;  // log units per step
static const float BandFloor = 1e-4;  // scRGB; below this a ratio means nothing

float3 LogScRgb(float2 uv, float lod = 0.0)
{
    return log(clamp(tex2Dlod(sTexSource, float4(uv, 0.0, lod)).rgb, BandFloor, 65504.0));
}

float3 Deband(float2 uv, float3 centre, float jitter, int taps)
{
    float2 ps = PixelSize;

    // Channels at or below the floor, which includes the negative ones outside
    // BT.709, have no log and are left exactly as they came.
    float3 valid = step(BandFloor, centre);
    float3 lc    = log(clamp(centre, BandFloor, 65504.0));

    // Brightness and colour are debanded separately. The rainbows are colour
    // steps, each channel stepping at its own place, while the texture worth
    // keeping lives almost entirely in brightness, so colour can be smoothed
    // harder before anything real is lost. Brightness is the mean of the three
    // log channels, colour each channel's offset from it.
    const float third = 1.0 / 3.0;
    float cm = max(ColourDeband, 1.0);

    float3 hf = abs(LogScRgb(uv + float2( ps.x, 0.0)) - lc)
              + abs(LogScRgb(uv + float2(-ps.x, 0.0)) - lc)
              + abs(LogScRgb(uv + float2(0.0,  ps.y)) - lc)
              + abs(LogScRgb(uv + float2(0.0, -ps.y)) - lc);
    float  hf_l = dot(hf, third);
    float3 hf_c = abs(hf - hf_l);

    float guard_l = 1.0, guard_c = 1.0;
    if (HdrDebandDetail > 0.0)
    {
        // Brightness is judged by the spread over a 5x5 area, not by the step
        // to the four neighbours. A band's dithered edge is a thin line in a
        // flat plateau, so over an area it averages out; texture varies
        // everywhere. The per-pixel test had to sit high to let that dither
        // through, and faint texture, dark stone at night above all, fell
        // under it and was smoothed. Measured in 4% steps on Odyssey: banded
        // sky 0.45 at the 90th percentile, night stone, frescoes and skin 0.9
        // to 1.1 at the 10th.
        float s = 0.0, s2 = 0.0;
        [unroll]
        for (int y = -1; y <= 1; y++)
        {
            [unroll]
            for (int x = -1; x <= 1; x++)
            {
                float v = dot(LogScRgb(uv + float2(x, y) * 2.0 * ps), third);
                s += v; s2 += v * v;
            }
        }
        float spread     = sqrt(max(s2 / 9.0 - (s / 9.0) * (s / 9.0), 0.0)) / BandStep;
        float measured_c = max(max(hf_c.r, hf_c.g), hf_c.b) * 0.25 / (BandStep * cm);
        guard_l = 1.0 - smoothstep(HdrDebandDetail * 0.6, HdrDebandDetail, spread);
        guard_c = 1.0 - smoothstep(HdrDebandDetail * 0.5, HdrDebandDetail, measured_c);
    }

    if (guard_l <= 0.0 && guard_c <= 0.0)
        return centre;

    float  l0    = dot(lc, third);
    float3 c0    = lc - l0;
    float  res_l = l0;
    float3 res_c = c0;

    [loop]
    for (int i = 1; i <= HdrDebandPasses; i++)
    {
        float r_i   = ToPixels(HdrDebandRadius) * float(i);
        float bound = HdrDebandThreshold * BandStep / float(i);
        float angle = (jitter + float(i) * 0.618034) * 6.2831853;

        // Past the first pass the taps land 64 px and more apart, scattered by
        // the jitter, and nearly every one missed the cache: this was over half
        // the cost of the whole chain. Bands that wide lose nothing at half
        // resolution. Measured on Odyssey the output moved a quarter as much as
        // it already does from one frame's jitter to the next, for 1 ms at 1200p.
        float  lod     = i > 1 ? 1.0 : 0.0;
        float  bound_c = bound * cm;
        float  sum_w = 0.0, sum_l = 0.0, sumsq_l = 0.0;
        float3 sum_c = 0.0, sumsq_c = 0.0;

        // Each sample counts by how much it resembles this pixel, so a sample
        // across an edge drops out and only the pixel's own side is averaged.
        // An unweighted average let a disc half on a dark pole and half on sky
        // pass as flat, and left a glow of the pole's colour along the edge.
        [loop]
        for (int k = 0; k < taps; k++)
        {
            float  t  = (float(k) + 0.5) / float(taps);
            float  a  = angle + float(k) * 2.39996323;
            float2 at = uv + float2(cos(a), sin(a)) * (r_i * sqrt(t)) * ps;

            float3 d   = LogScRgb(at, lod) - lc;
            float  d_l = dot(d, third);
            float3 d_c = d - d_l;
            float  w   = (1.0 - smoothstep(bound, bound * 2.0, abs(d_l)))
                       * (1.0 - smoothstep(bound_c, bound_c * 2.0, max(max(abs(d_c.r), abs(d_c.g)), abs(d_c.b))));
            sum_w += w;
            sum_l += w * d_l;  sumsq_l += w * d_l * d_l;
            sum_c += w * d_c;  sumsq_c += w * d_c * d_c;
        }

        // Too few similar samples means a detail rather than a band.
        float  cover  = smoothstep(0.3, 0.6, sum_w / float(taps));
        float  inv    = 1.0 / max(sum_w, 1e-4);
        float  mean_l = sum_l * inv;
        float3 mean_c = sum_c * inv;
        float  sd_l   = sqrt(max(sumsq_l * inv - mean_l * mean_l, 0.0));
        float3 sd_c   = sqrt(max(sumsq_c * inv - mean_c * mean_c, 0.0));

        float w_l = (1.0 - smoothstep(bound * 0.5, bound, abs(mean_l)))
                  * (1.0 - smoothstep(bound, bound * 2.0, sd_l)) * cover;
        float3 w_c = (1.0 - smoothstep(bound_c * 0.5, bound_c, abs(mean_c)))
                   * (1.0 - smoothstep(bound_c, bound_c * 2.0, sd_c)) * cover;

        res_l = lerp(res_l, l0 + mean_l, w_l * guard_l);
        res_c = lerp(res_c, c0 + mean_c, w_c * guard_c);
    }

    float  limit = HdrDebandCorrection * BandStep;
    float3 res   = (l0 + SoftLimit(res_l - l0, limit)) + (c0 + SoftLimit(res_c - c0, limit * cm));
    return lerp(centre, exp(res), valid);
}

// The SDR frame debander, the same one PHDRPlus runs on an SDR swap chain,
// counting in 8-bit steps because that is the cut Windows makes on the way
// out. Three tests have to agree: the neighbourhood average sits close to the
// pixel, the samples agree with each other, and the value does not change
// pixel to pixel. The tests read the tone mapped frame; the repair lands in
// what PHDRPlus made of it.
float3 DebandSdr(float2 uv, float3 out_centre, float3 src_centre, float jitter,
                 float threshold, float radius, int iterations, int taps, float detail)
{
    float2 ps = PixelSize;
    float step_size = 1.0 / OutputSteps;

    float guard = 1.0;
    if (detail > 0.0)
    {
        float3 hf = abs(tex2D(sTexProxy, uv + float2( ps.x, 0.0)).rgb - src_centre)
                  + abs(tex2D(sTexProxy, uv + float2(-ps.x, 0.0)).rgb - src_centre)
                  + abs(tex2D(sTexProxy, uv + float2(0.0,  ps.y)).rgb - src_centre)
                  + abs(tex2D(sTexProxy, uv + float2(0.0, -ps.y)).rgb - src_centre);

        float measured = max(max(hf.r, hf.g), hf.b) * 0.25 * OutputSteps;
        guard = 1.0 - smoothstep(detail * 0.5, detail, measured);
    }

    if (guard <= 0.0)
        return out_centre;

    float3 res = out_centre;

    [loop]
    for (int i = 1; i <= iterations; i++)
    {
        float r_i   = ToPixels(radius) * float(i);
        float bound = threshold * step_size / float(i);
        float angle = (jitter + float(i) * 0.618034) * 6.2831853;

        float3 src_sum   = 0.0;
        float3 src_sumsq = 0.0;
        float3 out_sum   = 0.0;

        [loop]
        for (int k = 0; k < taps; k++)
        {
            float  t  = (float(k) + 0.5) / float(taps);
            float  a  = angle + float(k) * 2.39996323;
            float4 at = float4(uv + float2(cos(a), sin(a)) * (r_i * sqrt(t)) * ps, 0.0, 0.0);

            float3 sd_ = tex2Dlod(sTexProxy, at).rgb - src_centre;
            float3 od_ = saturate(tex2Dlod(sTexColor, at).rgb) - out_centre;

            src_sum   += sd_;
            src_sumsq += sd_ * sd_;
            out_sum   += od_;
        }

        float  inv      = 1.0 / float(taps);
        float3 src_mean = src_sum * inv;
        float3 src_sd   = sqrt(max(src_sumsq * inv - src_mean * src_mean, 0.0));
        float3 out_avg  = out_centre + out_sum * inv;

        float3 flat_weight = 1.0 - smoothstep(bound * 0.5, bound, abs(src_mean));
        float3 calm_weight = 1.0 - smoothstep(bound, bound * 2.0, src_sd);

        res = lerp(res, out_avg, flat_weight * calm_weight * guard);
    }

    return out_centre + SoftLimit(res - out_centre, DebandMaxCorrection / OutputSteps);
}

// Debug meter, top left, four bars 400 px long at 1080p:
//   1. scene log average, smoothed    log scale, 0.1 to 10000 nits
//   2. centre-weighted bright level   same scale, smoothed
//   3. measured peak, smoothed        same scale
//   4. exposure gain                  -4 to +4 stops, filled from 0
// Tall ticks mark each decade (0.1, 1, 10, 100, 1000, 10000 nits) or each
// stop, short ticks mark 2 and 5 within a decade.
float3 DrawMeter(float2 uv, float3 c)
{
    float  s     = float(BUFFER_HEIGHT) / REFERENCE_HEIGHT;
    float2 p     = uv * ScreenSize / s;
    float2 o     = float2(16.0, 16.0);
    float  len   = 400.0;
    float  bar_h = 12.0;
    float  pitch = 18.0;

    if (p.x < o.x - 4.0 || p.x > o.x + len + 4.0 || p.y < o.y - 4.0 || p.y > o.y + 4.0 * pitch)
        return c;

    float4 stats = tex2Dfetch(sTexStats, 0);
    int    row   = int(floor((p.y - o.y) / pitch));
    float  y     = p.y - o.y - float(row) * pitch;
    float  x     = (p.x - o.x) / len;
    float3 col   = float3(0.08, 0.08, 0.08);

    if (row < 0 || row > 3 || y > bar_h || x < 0.0 || x > 1.0)
        return col;

    float  value;
    float3 fill;
    bool   stops = (row == 3);
    if (row == 0)      { value = stats.y; fill = float3(0.2, 0.8, 0.3); }
    else if (row == 1) { value = stats.z; fill = float3(0.6, 0.95, 0.6); }
    else if (row == 2) { value = stats.x; fill = float3(1.0, 0.6, 0.15); }
    else               { value = GainStops(stats); fill = float3(0.3, 0.55, 1.0); }

    // log nits to [0, 1] over five decades, or stops to [0, 1] over -4 to +4
    float t = stops ? saturate(value / 8.0 + 0.5) : saturate((value / 2.302585 + 1.0) / 5.0);
    bool  lit = stops ? (x >= min(t, 0.5) && x <= max(t, 0.5)) : (x <= t);
    col = lit ? fill : float3(0.25, 0.25, 0.25);

    float px = 1.0 / len;
    [loop]
    for (int k = 0; k <= 8; k++)
    {
        float tall = stops ? float(k) / 8.0 : float(k) / 5.0;
        if (!stops && k > 5)
            break;
        if (abs(x - tall) < px * 0.75)
            col = float3(1.0, 1.0, 1.0);
        if (!stops && k < 5 && y > bar_h * 0.5)
        {
            if (abs(x - (float(k) + 0.30103) / 5.0) < px * 0.75 || abs(x - (float(k) + 0.69897) / 5.0) < px * 0.75)
                col = float3(0.85, 0.85, 0.85);
        }
    }
    return col;
}
#endif

//---------------------|
// :: Pixel Shaders :: |
//---------------------|

#if PHDRS_ACTIVE
// Decode once, and replace an invalid pixel with the mean of its valid direct
// neighbours, or black when none of them is valid either.
float4 PS_Source(VS_OUTPUT input) : SV_Target
{
    int2   pixel = int2(input.pos.xy);
    float3 c     = DecodeSource(pixel);
    if (Invalid(c))
    {
        float3 sum = 0.0;
        float  n   = 0.0;
        const int2 offsets[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
        [unroll]
        for (int i = 0; i < 4; i++)
        {
            float3 v = DecodeSource(pixel + offsets[i]);
            if (!Invalid(v))
            {
                sum += v;
                n   += 1.0;
            }
        }
        c = n > 0.0 ? sum / n : 0.0;
    }
    return float4(c, 1.0);
}

float4 PS_Deband(VS_OUTPUT input) : SV_Target
{
    float3 c = ReadScRgb(input.uv);

    if (EnableHdrDeband)
    {
        int   slice  = int((uint(FrameCount) + uint(STBN_DEPTH / 2)) % uint(STBN_DEPTH));
        float jitter = SampleBlueNoise(int2(input.uv * ScreenSize), slice).g;
        int   taps   = 8 * (clamp(HdrDebandSamples, 0, 3) + 1);
        c = Deband(input.uv, c, jitter, taps);
    }
    return float4(c, 1.0);
}

float4 PS_Meter(VS_OUTPUT input) : SV_Target
{
    float3 c = tex2D(sTexHdr, input.uv).rgb;
    float  Y = GetLuminance(c) * 80.0;
    return float4(max(max(max(c.r, c.g), c.b), 0.0), log(max(Y, MeterFloor)), max(Y, 0.0) / 80.0, 0.0);
}

// Blocks are about 16 pixels across at 1080p, so the peak describes a lit
// region rather than one hot pixel.
int BlockMip()
{
    return int(max(0.0, round(log2(16.0 * float(BUFFER_HEIGHT) / REFERENCE_HEIGHT))));
}

int2 BlockGrid()
{
    int mip = BlockMip();
    return int2(max(BUFFER_WIDTH >> mip, 1), max(BUFFER_HEIGHT >> mip, 1));
}

// The brightest block inside this texel's tile, and the sum of the blocks' log
// luminance. The mean is taken here rather than from the top mip because an
// odd sized level drops its last row or column, and by the top of the chain
// that leaves a reading of the middle of the screen.
float4 PS_Tiles(VS_OUTPUT input) : SV_Target
{
    int  mip  = BlockMip();
    int2 size = BlockGrid();
    int2 tile = int2(input.pos.xy);
    int2 lo   = tile * size / 16;
    int2 hi   = (tile + 1) * size / 16;

    float peak    = 0.0;
    float log_sum = 0.0;
    float lin_sum = 0.0;
    float w_sum   = 0.0;
    [loop]
    for (int y = lo.y; y < hi.y; y++)
    {
        [loop]
        for (int x = lo.x; x < hi.x; x++)
        {
            float2 uv = (float2(x, y) + 0.5) / float2(size);
            float3 m  = tex2Dlod(sTexMeter, float4(uv, 0.0, mip)).rgb;
            peak     = max(peak, m.r);
            log_sum += m.g;

            // Centre weight for the bright level, falling to about a third at
            // the top and bottom edges, measured in screen heights.
            float2 d = (float2(x, y) + 0.5 - float2(size) * 0.5) / float(size.y);
            float  w = exp(-dot(d, d) / (2.0 * 0.35 * 0.35));
            lin_sum += w * m.b;
            w_sum   += w;
        }
    }
    return float4(peak, log_sum, lin_sum, w_sum);
}

float4 PS_Stats(VS_OUTPUT input) : SV_Target
{
    float peak    = 0.0;
    float log_sum = 0.0;
    float lin_sum = 0.0;
    float w_sum   = 0.0;
    [loop]
    for (int i = 0; i < 256; i++)
    {
        float4 t = tex2Dfetch(sTexTiles, int2(i % 16, i / 16));
        peak     = max(peak, t.r);
        log_sum += t.g;
        lin_sum += t.b;
        w_sum   += t.a;
    }

    int2  grid       = BlockGrid();
    float log_peak   = log(max(peak * 80.0, MeterFloor));
    float log_avg    = log_sum / float(grid.x * grid.y);
    float log_bright = log(max(lin_sum / max(w_sum, 1e-6) * 80.0, MeterFloor));

    float4 last = tex2Dfetch(sTexStatsLast, 0);
    if (last.w < 0.5)
        return float4(log_peak, log_avg, log_bright, 1.0);

    // Getting brighter is followed faster than getting darker, as eyes do. A
    // rising peak is faster still, since until the filter catches up it clips.
    float dt  = FrameTime * 0.001;
    float tau = (log_peak > last.x) ? PeakRiseTime : MeterTime;
    float lp  = lerp(last.x, log_peak, 1.0 - exp(-dt / tau));
    float la  = lerp(last.y, log_avg,    1.0 - exp(-dt / ((log_avg    > last.y) ? AdaptBrighter : AdaptDarker)));
    float lb  = lerp(last.z, log_bright, 1.0 - exp(-dt / ((log_bright > last.z) ? AdaptBrighter : AdaptDarker)));
    return float4(lp, la, lb, 1.0);
}

float4 PS_SaveStats(VS_OUTPUT input) : SV_Target
{
    return tex2Dfetch(sTexStats, 0);
}

float4 PS_ToneMap(VS_OUTPUT input) : SV_Target
{
    float4 stats = tex2Dfetch(sTexStats, 0);
    return float4(ToneMap(tex2D(sTexHdr, input.uv).rgb, stats), 1.0);
}

float4 PS_Hand(VS_OUTPUT input) : SV_Target
{
    return tex2D(sTexProxy, input.uv);
}

// After PHDRPlus the frame is gamma encoded SDR, which is not what the swap
// chain holds. Deband and dither against the 8-bit cut Windows makes on the
// way to the monitor, then hand the frame back in the form the swap chain is
// shown as: linear light for scRGB, and for HDR10 the sRGB values themselves,
// since HDR Bridge leaves an HDR10 swap chain labelled sRGB for Windows.
// PHDRPlus compiles its own debanding and dither out on an HDR swap chain, so
// all of it happens here.
float4 PS_Output(VS_OUTPUT input) : SV_Target
{
    float3 c = saturate(tex2D(sTexColor, input.uv).rgb);

    if (EnableDeband)
    {
        float3 src  = tex2D(sTexProxy, input.uv).rgb;
        int    taps = 8 * (clamp(DebandTaps, 0, 3) + 1);

        // Half a loop from the dither's slice, and on a channel the HDR frame
        // debander does not use, so neither lines up with the other or the grain.
        int   slice  = int((uint(FrameCount) + uint(STBN_DEPTH / 2)) % uint(STBN_DEPTH));
        float jitter = SampleBlueNoise(int2(input.uv * ScreenSize), slice).b;

        // How far PHDRPlus moved this pixel, in 8-bit steps. Banding it opened
        // up is gone after hard and banding it left alone more gently.
        float3 moved  = abs(c - src);
        float  effect = smoothstep(DebandSplit * 0.5, DebandSplit, max(max(moved.r, moved.g), moved.b) * OutputSteps);

        float3 strong = c;
        float3 gentle = c;

        [branch]
        if (EnableDebandEffect && effect > 0.0)
            strong = DebandSdr(input.uv, c, src, jitter, DebandEffectThreshold, DebandEffectRadius,
                               DebandEffectIterations, taps, DebandEffectDetail);

        [branch]
        if (EnableDebandSource && effect < 1.0)
            gentle = DebandSdr(input.uv, c, src, jitter, DebandSourceThreshold, DebandSourceRadius,
                               DebandSourceIterations, taps, DebandSourceDetail);

        float3 debanded = saturate(lerp(gentle, strong, effect));

        if (DebugDeband)
            c = saturate(abs(debanded - c) * OutputSteps * 0.5);
        else
            c = debanded;
    }

    if (EnableDithering)
    {
        int2   pixel = int2(input.uv * ScreenSize);
        float3 n     = SampleBlueNoise(pixel, int(uint(FrameCount) % uint(STBN_DEPTH)));
        float3 d     = float3(ReshapeUniformToTriangle(n.r),
                              ReshapeUniformToTriangle(n.g),
                              ReshapeUniformToTriangle(n.b)) - 0.5;

        // Banding needs a stretch of near-constant colour, so gate on the
        // screen-space slope and leave textured regions alone.
        float g    = abs(ddx(GetLuminance(c))) + abs(ddy(GetLuminance(c)));
        float mask = saturate(1.0 - g * 64.0);
        c = saturate(c + d * (mask * mask * DitherStrength / OutputSteps));
    }

    if (DebugMeter)
        c = DrawMeter(input.uv, c);

#if BUFFER_COLOR_SPACE == 2
    return float4(SrgbToLinear(c), 1.0);
#else
    return float4(c, 1.0);
#endif
}
#else
float4 PS_Passthrough(VS_OUTPUT input) : SV_Target
{
    return tex2D(sTexColor, input.uv);
}
#endif

technique PHDRSource_ToneMap
<
    ui_label = "PHDR Source: Tone Map";
    ui_tooltip = "Place first, above PHDRPlus. Turns the game's HDR frame into SDR.";
>
{
#if PHDRS_ACTIVE
    pass Source    { VertexShader = PostProcessVS; PixelShader = PS_Source;    RenderTarget = TexSource;    }
    pass Deband    { VertexShader = PostProcessVS; PixelShader = PS_Deband;    RenderTarget = TexHdr;       }
    pass Meter     { VertexShader = PostProcessVS; PixelShader = PS_Meter;     RenderTarget = TexMeter;     }
    pass Tiles     { VertexShader = PostProcessVS; PixelShader = PS_Tiles;     RenderTarget = TexTiles;     }
    pass Stats     { VertexShader = PostProcessVS; PixelShader = PS_Stats;     RenderTarget = TexStats;     }
    pass SaveStats { VertexShader = PostProcessVS; PixelShader = PS_SaveStats; RenderTarget = TexStatsLast; }
    pass ToneMap   { VertexShader = PostProcessVS; PixelShader = PS_ToneMap;   RenderTarget = TexProxy;     }
    pass Hand      { VertexShader = PostProcessVS; PixelShader = PS_Hand; }
#else
    pass Passthrough { VertexShader = PostProcessVS; PixelShader = PS_Passthrough; }
#endif
}

technique PHDRSource_Output
<
    ui_label = "PHDR Source: Output";
    ui_tooltip = "Place last, below PHDRPlus. Hands the SDR result back to the HDR swap chain.";
>
{
#if PHDRS_ACTIVE
    pass Output { VertexShader = PostProcessVS; PixelShader = PS_Output; }
#else
    pass Passthrough { VertexShader = PostProcessVS; PixelShader = PS_Passthrough; }
#endif
}
}
