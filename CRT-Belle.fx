// CRT Belle - Aperture grille CRT shader by sahara-min
// Licensed under CC BY-NC 4.0 — https://creativecommons.org/licenses/by-nc/4.0/
// (c) 2025 sahara-min

#include "ReShade.fxh"

uniform int _help_ <
	ui_label = " ";
	ui_text =
	"Make sure your DuckStation graphic settings match the following for the best result:\n"
	"- Aspect Ratio: Auto (Game Native)\n"
	"- Crop: None\n"
	"- Scaling: Nearest Neighbour\n"
	"- Screen Position: Center\n";
	ui_category = "Help";
	ui_category_closed = true;
	ui_type = "radio";
>;

uniform float signal_blur <
	ui_label = "Signal Blur";
	ui_type = "slider";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.05;
> = 0.5;

uniform float overscan_horizontal <
	ui_label = "Overscan horizontal";
	ui_type = "slider";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.05;
> = 0.75;

uniform float overscan_vertical <
	ui_label = "Overscan vertical";
	ui_type = "slider";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.05;
> = 0.75;

uniform float beam_gamma <
	ui_label = "Beam Gamma";
	ui_type = "slider";
	ui_min = 1.8;
	ui_max = 2.8;
	ui_step = 0.05;
> = 2.2;

uniform float beam_offsets <
	ui_label = "Beam Offsets";
	ui_type = "slider";
	ui_min = -1.0;
	ui_max = 1.0;
	ui_step = 0.05;
> = -0.75;

uniform float beam_definition <
	ui_label = "Beam Definition";
	ui_type = "slider";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.05;
> = 0.75;

uniform float dark_glow <
	ui_label = "Dark Glow";
	ui_type = "slider";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.05;
> = 0.25;

uniform int phosphor_width <
	ui_label = "Phosphor Width";
	ui_type = "slider";
	ui_min = 1;
	ui_max = 3;
> = 2;

uniform int phosphor_gap <
	ui_label = "Phosphor Gap";
	ui_type = "slider";
	ui_min = 0;
	ui_max = 1;
> = 0;

uniform float phosphor_tint <
	ui_label = "Phosphor Tint";
	ui_type = "slider";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.05;
> = 0.25;

uniform float brightness_boost <
	ui_label = "Brightness Boost";
	ui_type = "slider";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.05;
> = 1.0;

static const float signal_blur_scale = 2.0;
static const float overscan_scale = 0.1;
static const float dark_glow_scale = 0.005;
static const float beam_spot_falloff = 0.25;
static const float brightness_boost_scale = 2.0;

static const int num_scanlines = 240; // Assuming 240p

static const float pi = 3.14159265;

static const float screen_width = ReShade::ScreenSize.x;
static const float screen_height = ReShade::ScreenSize.y;

texture2D signal_texture {
	Width = BUFFER_WIDTH;
	Height = num_scanlines;
	Format = RGBA16F;
};

sampler2D signal_sampler {
	Texture = signal_texture;
	MinFilter = Point;
	MagFilter = Point;
	MipFilter = Point;
};

texture2D phosphor_texture {
	Width = BUFFER_WIDTH;
	Height = BUFFER_HEIGHT;
	Format = RGBA16F;
};

sampler2D phosphor_sampler {
	Texture = phosphor_texture;
	MinFilter = Point;
	MagFilter = Point;
	MipFilter = Point;
};

float3 SignalSampleInput(float u, float v) {
	return tex2D(ReShade::BackBuffer, float2(u, v)).rgb;
}

float4 SignalMainPS(float4 xy: SV_Position, float2 uv : TEXCOORD) : SV_Target {

	// This pass emulates signal bandwidth by applying a horizontal blur to input.

	float pixel_uv_width = 1.0 / screen_width;
	float scanline_xy_height = screen_height / num_scanlines;

	float blur_strength = signal_blur_scale * signal_blur;
	
	// Apply horizontal overscan in this pass to maintain pixel-perfect blur
	// fidelity.
	float u_scale = 1.0 + overscan_scale * overscan_horizontal;

	float u = (uv.x - 0.5) / u_scale + 0.5;
	float v = uv.y;

	float3 color = float3(0.0, 0.0, 0.0);
	float weight_sum = 0.0;
	// Scale blur with scanline height for consitent blur across resolutions.
	float width = round(blur_strength * u_scale * scanline_xy_height);

	for (float i = -width; i <= width; i++) {
		// Fast Gaussian approximation using a raised cosine bell.
		float weight = 0.5 * (cos(pi * i / (width + 1.0)) + 1.0);
		color += weight * SignalSampleInput(u + pixel_uv_width * i, v);
		weight_sum += weight;
	}

	return float4(color / weight_sum, 1.0);
}

float CrtApplyBeamGamma(float c) {
	return pow(c, beam_gamma);
}

float CrtApplyDarkGlow(float c) {
	float s = dark_glow_scale * dark_glow;
	return s + (1.0 - s) * c;
}

float CrtShapeBeamSpot(float intensity, float offset) {
	
	// We'll model the beam spot profile using a raised cosine bell.

	// Find the amplitude (A) and width (w) that conserves intensity (I).
	// The beam spot width w depends on A:
	//   w = w0 + (1.0 - w0) * A
	// We want the total area (A * w) to match the signal intensity:
	//   A * w = I
	// Substitute w:
	//   A * (w0 + (1.0 - w0) * A) = I
	// Expand and rearrange into standard quadratic form:
	//   (1.0 - w0) * A^2 + w0 * A - I = 0
	// Solve for A using the quadratic formula:

	float I = intensity;
	// Clamp to avoid division by zero in quadratic formula when a == 0 and
	// when computing "pi * x / w" when w == 0.
	float w0 = clamp(1.0 - beam_definition, 0.001, 0.999);

	// Quadratic formula coefficients.
	float a = 1.0 - w0;
	float b = w0;
	float c = -I;

	// Quadratic formula gives us the amplitude.
	float A = (-b + sqrt(b * b - 4.0 * a * c)) / (2.0 * a);

	float w = w0 + (1.0 - w0) * A;

	// Raised cosine bell with shape control (k).
	float k = 1.0 - beam_spot_falloff;
	float x = clamp(offset, -w, w);
	float y = cos(pi * x / w);

	// sign() and abs() handle negative y for any k.
	return A * 0.5 * (sign(y) * pow(abs(y), k) + 1.0);
}

float CrtSampleSignal(float scanline_center, float time, int component) {
	float u = time;
	float v = scanline_center / num_scanlines;
	return tex2D(signal_sampler, float2(u, v))[component];
}

float CrtSampleBeam(float scanline_center, float y, float time, int component) {
	float voltage = CrtSampleSignal(scanline_center, time, component);
	float intensity = CrtApplyBeamGamma(voltage);
	float offset = y - scanline_center;
	return CrtShapeBeamSpot(intensity, offset);
}

float CrtSampleBeamsWithOverlap(float y, float time, int component) {
	float scanline_a = floor(y) + 0.5; // Center of scanline/beam
	float scanline_b = scanline_a > y ? scanline_a - 1.0 : scanline_a + 1.0;
	float intensity_a = CrtSampleBeam(scanline_a, y, time, component);
	float intensity_b = CrtSampleBeam(scanline_b, y, time, component);
	return intensity_a + intensity_b;
}

float4 CrtMainPS(float4 xy: SV_Position, float2 uv : TEXCOORD) : SV_Target {

	int phosphor_pitch = phosphor_width + phosphor_gap;
	int phosphor_subpixel = xy.x % phosphor_pitch;
	int component = xy.x / phosphor_pitch % 3;

	// Ensure all phosphors in a triad sample from the same points in the signal
	// time. E.g. the first green pixel samples from the same time as the first
	// red pixel.
	float pixel_uv_width = 1.0 / screen_width;
	float time = uv.x - phosphor_pitch * pixel_uv_width * component;

	// Apply vertical overscan and individual beam vertical offset.
	float v_scale = 1.0 + overscan_scale * overscan_vertical;
	float y_offset = beam_offsets * (component - 1);
	float y = ((uv.y - 0.5) / v_scale + 0.5) * num_scanlines + y_offset;

	float intensity = CrtSampleBeamsWithOverlap(y, time, component);
	intensity = CrtApplyDarkGlow(intensity);

	// Apply aperture grille vertical phosphor stripe mask.
	intensity *= float(phosphor_subpixel >= phosphor_gap);
	float3 intensity3 = intensity;
	float t = phosphor_tint;
	if (component == 0)
		intensity3 *= lerp(float3(1.0, 0.0, 0.0), float3(1.00, 0.06, 0.00), t);
	if (component == 1)
		intensity3 *= lerp(float3(0.0, 1.0, 0.0), float3(0.18, 1.00, 0.00), t);
	if (component == 2)
		intensity3 *= lerp(float3(0.0, 0.0, 1.0), float3(0.03, 0.06, 1.00), t);

	return float4(intensity3, 1.0);
}

float3 PostSamplePhosphor(float u, float v) {
	return tex2D(phosphor_sampler, float2(u, v)).rgb;
}

float3 PostSrgbEncode(float3 c) {
	return (c <= 0.0031308) ? (c * 12.92) : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

float4 PostMainPS(float4 xy: SV_Position, float2 uv : TEXCOORD) : SV_Target {

	// To compensate for brightness loss from applying the mask in the previous
	// pass, apply a horizontal glow using the same blur technique as the Signal
	// pass.

	float pixel_uv_width = 1.0 / screen_width;

	float u = uv.x;
	float v = uv.y;

	float3 color = float3(0.0, 0.0, 0.0);
	float weight_sum = 0.0;
	float width = 3.0 * (phosphor_width + phosphor_gap) - 1.0;

	for (int i = -width; i <= width; i++) {
		// Fast Gaussian approximation using a raised cosine bell.
		float weight = (cos(pi * i / (width + 1.0)) + 1.0) / 2.0;
		color += weight * PostSamplePhosphor(u + pixel_uv_width * i, v);
		weight_sum += weight;
	}

	color *= brightness_boost_scale * brightness_boost / weight_sum;
	color += PostSamplePhosphor(u, v);

	// Finally clip pixels outside the 4:3 aspect ratio.
	float x_distance_from_center = abs(xy.x - 0.5 * screen_width);
	float crt_xy_halfwidth = 0.5 * screen_height * 4.0 / 3.0;
	if (x_distance_from_center > crt_xy_halfwidth)
		return float4(0.0, 0.0, 0.0, 1.0);

	return float4(PostSrgbEncode(color), 1.0);
}

technique CrtBelle {

	pass Signal {
		VertexShader = PostProcessVS;
		PixelShader = SignalMainPS;
		RenderTarget = signal_texture;
	}

	pass Crt {
		VertexShader = PostProcessVS;
		PixelShader = CrtMainPS;
		RenderTarget = phosphor_texture;
	}

	pass Post {
		VertexShader = PostProcessVS;
		PixelShader = PostMainPS;
	}
}
