shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_lambert, specular_disabled;

uniform sampler2D atlas_texture : source_color, filter_nearest, repeat_disable;
uniform bool use_colormap = false;
uniform sampler2D grass_colormap : source_color, filter_linear, repeat_disable;
uniform sampler2D foliage_colormap : source_color, filter_linear, repeat_disable;
uniform sampler2D dry_foliage_colormap : source_color, filter_linear, repeat_disable;
uniform vec3 albedo_tint : source_color = vec3(1.0);
uniform vec3 grass_tint : source_color = vec3(0.35, 0.70, 0.25);
uniform vec3 leaves_tint : source_color = vec3(0.25, 0.70, 0.25);
uniform float biome_variation_strength : hint_range(0.0, 1.0) = 0.65;
uniform float biome_variation_scale : hint_range(0.0001, 0.1) = 0.0025;
uniform float biome_map_scale : hint_range(0.0001, 0.02) = 0.0012;
uniform float chunk_world_size : hint_range(1.0, 1024.0) = 16.0;
uniform int biome_seed = 1337;
uniform float voxel_scale : hint_range(0.1, 10.0) = 1.0;
uniform float atlas_rows : hint_range(1.0, 8.0) = 2.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;
uniform float sky_brightness : hint_range(0.0, 1.0) = 1.0;
uniform float min_light : hint_range(0.0, 1.0) = 0.06;
uniform float light_curve : hint_range(0.1, 3.0) = 1.6;

varying vec3 world_pos;
varying float v_sky_light;
varying float v_block_light;

float _hash12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float _hash22(vec2 p) {
	return fract(sin(dot(p, vec2(269.5, 183.3))) * 43758.5453);
}

float _noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = _hash12(i);
	float b = _hash12(i + vec2(1.0, 0.0));
	float c = _hash12(i + vec2(0.0, 1.0));
	float d = _hash12(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_sky_light = COLOR.b;
	v_block_light = COLOR.a;
}

void fragment() {
	vec4 tex = textureLod(atlas_texture, UV, 0.0);
	float alpha_cutoff = clamp(UV2.y, 0.0, 1.0);

	float grass_top_mask = clamp(COLOR.r, 0.0, 1.0);
	float grass_side_overlay_mask = clamp(COLOR.g, 0.0, 1.0);
	float leaf_mask = step(0.5, UV2.x);
	float biome_part = UV2.x - leaf_mask * 0.5;
	float biome_id = floor(clamp(biome_part * 8.0, 0.0, 2.999));
	vec2 th = vec2(0.60, 0.60);
	if (biome_id > 1.5) {
		th = vec2(1.0, 0.05);
	} else if (biome_id > 0.5) {
		th = vec2(0.70, 0.90);
	}

	vec3 grass_base = grass_tint;
	vec3 leaves_base = leaves_tint;
	if (use_colormap) {
		vec3 grass_cm = texture(grass_colormap, th).rgb;
		vec3 fol = texture(foliage_colormap, th).rgb;
		vec3 dry = texture(dry_foliage_colormap, th).rgb;
		float is_dry = step(1.5, biome_id);
		grass_base = mix(grass_cm, mix(grass_cm, dry, 0.85), is_dry);
		leaves_base = mix(fol, dry, is_dry);
	}
	float is_plains = 1.0 - step(0.5, biome_id);
	float is_forest = step(0.5, biome_id) * (1.0 - step(1.5, biome_id));
	float grass_mul = 1.0;
	grass_mul = mix(grass_mul, 1.10, is_plains);
	grass_mul = mix(grass_mul, 0.82, is_forest);
	grass_base = clamp(grass_base * grass_mul, vec3(0.0), vec3(1.0));
	leaves_base = clamp(leaves_base * mix(1.0, 0.88, is_forest), vec3(0.0), vec3(1.0));

	vec3 tint = mix(grass_base, leaves_base, leaf_mask);

	vec3 base_rgb = tex.rgb * albedo_tint;
	vec3 top_rgb = tex.rgb * mix(vec3(1.0), tint, grass_top_mask) * albedo_tint;

	float dv = 1.0 / max(atlas_rows, 1.0);
	vec2 overlay_uv = UV + vec2(0.0, dv);
	vec4 overlay = textureLod(atlas_texture, overlay_uv, 0.0);
	vec3 overlay_rgb = overlay.rgb * tint * albedo_tint;

	vec3 side_rgb = base_rgb * (1.0 - overlay.a * grass_side_overlay_mask) + overlay_rgb * (overlay.a * grass_side_overlay_mask);
	vec3 albedo = mix(side_rgb, top_rgb, grass_top_mask);

	float sky01 = clamp(v_sky_light, 0.0, 1.0) * clamp(sky_brightness, 0.0, 1.0);
	float blk01 = clamp(v_block_light, 0.0, 1.0);
	float light01 = max(sky01, blk01);
	light01 = pow(clamp(light01, 0.0, 1.0), light_curve);

	float shade = 0.8;
	if (NORMAL.y > 0.9) {
		shade = 1.0;
	} else if (NORMAL.y < -0.9) {
		shade = 0.5;
	}
	light01 = max(light01, min_light) * shade;

	ALBEDO = albedo * light01;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;
	AO = 1.0;

	METALLIC = 0.0;
	ROUGHNESS = roughness;
	SPECULAR = 0.0;
}
