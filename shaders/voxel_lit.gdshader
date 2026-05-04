shader_type spatial;
render_mode cull_back, depth_draw_always, diffuse_burley, specular_schlick_ggx;

uniform sampler2D atlas_texture : source_color, filter_nearest, repeat_disable;
uniform vec3 albedo_tint : source_color = vec3(1.0);
uniform vec3 grass_tint : source_color = vec3(0.35, 0.70, 0.25);
uniform vec3 leaves_tint : source_color = vec3(0.25, 0.70, 0.25);
uniform float biome_variation_strength : hint_range(0.0, 1.0) = 0.15;
uniform float biome_variation_scale : hint_range(0.0, 2.0) = 0.06;
uniform float atlas_rows : hint_range(1.0, 8.0) = 2.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 tex = textureLod(atlas_texture, UV, 0.0);
	float alpha_cutoff = clamp(UV2.y, 0.0, 1.0);
	if (alpha_cutoff > 0.0 && tex.a < alpha_cutoff) {
		discard;
	}

	float grass_top_mask = clamp(COLOR.r, 0.0, 1.0);
	float grass_side_overlay_mask = clamp(COLOR.g, 0.0, 1.0);
	float roughness = clamp(COLOR.b, 0.0, 1.0);
	float specular = clamp(COLOR.a, 0.0, 1.0);
	float leaf_mask = clamp(UV2.x, 0.0, 1.0);
	float n = fract(sin(dot(world_pos.xz * biome_variation_scale, vec2(12.9898, 78.233))) * 43758.5453);
	float biome = mix(1.0, 0.85 + 0.30 * n, biome_variation_strength);
	vec3 base_tint = mix(grass_tint, leaves_tint, leaf_mask);
	vec3 tint = base_tint * biome;

	vec3 base_rgb = tex.rgb * albedo_tint;
	vec3 top_rgb = tex.rgb * mix(vec3(1.0), tint, grass_top_mask) * albedo_tint;

	float dv = 1.0 / max(atlas_rows, 1.0);
	vec2 overlay_uv = UV + vec2(0.0, dv);
	vec4 overlay = textureLod(atlas_texture, overlay_uv, 0.0);
	vec3 overlay_rgb = overlay.rgb * tint * albedo_tint;

	vec3 side_rgb = base_rgb * (1.0 - overlay.a * grass_side_overlay_mask) + overlay_rgb * (overlay.a * grass_side_overlay_mask);
	ALBEDO = mix(side_rgb, top_rgb, grass_top_mask);
	ALPHA = 1.0;

	METALLIC = 0.0;
	ROUGHNESS = roughness;
	SPECULAR = specular;
}
