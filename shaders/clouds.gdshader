shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform sampler2D clouds_tex : source_color, filter_nearest, repeat_enable;
uniform vec4 clouds_color : source_color = vec4(1.0);
uniform float base_opacity : hint_range(0.0, 1.0) = 0.35;
uniform float alpha_mul : hint_range(0.0, 2.0) = 1.0;
uniform vec2 uv_offset = vec2(0.0);
uniform float tile_world_size : hint_range(1.0, 8192.0) = 4096.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = world_pos.xz / max(tile_world_size, 0.0001) + uv_offset;
	vec4 t = texture(clouds_tex, uv);
	float a = clamp(t.r, 0.0, 1.0) * clamp(base_opacity, 0.0, 1.0) * clamp(alpha_mul, 0.0, 2.0);
	ALBEDO = clouds_color.rgb;
	ALPHA = a;
}
