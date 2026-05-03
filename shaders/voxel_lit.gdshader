shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

uniform sampler2D atlas_texture : source_color;
uniform vec3 albedo_tint : source_color = vec3(1.0);
uniform float shininess : hint_range(1.0, 256.0) = 64.0;

void fragment() {
	// 纹理图集采样：UV 由网格生成算法按“面”分配到对应的图集格子上
	vec4 tex = texture(atlas_texture, UV);
	ALBEDO = tex.rgb * albedo_tint;
	ALPHA = tex.a;
}

void light() {
	// --- INDEPENDENT DESIGN START ---
	// Blinn-Phong 光照模型（每盏灯逐像素计算）
	// 说明：
	// - N：表面法线（已在网格生成时为每个面写入常量法线）
	// - L：从片元指向光源方向
	// - V：从片元指向相机方向
	// - H：半程向量（Blinn）
	vec3 N = normalize(NORMAL);
	vec3 L = normalize(LIGHT);
	vec3 V = normalize(VIEW);

	float NdotL = max(dot(N, L), 0.0);

	vec3 H = normalize(L + V);
	float NdotH = max(dot(N, H), 0.0);

	// 漫反射：Lambert
	vec3 diffuse = ALBEDO * LIGHT_COLOR.rgb * NdotL;

	// 镜面反射：Blinn-Phong（shininess 控制高光锐利程度）
	float spec = pow(NdotH, shininess) * step(0.0, NdotL);
	vec3 specular = LIGHT_COLOR.rgb * spec;

	DIFFUSE_LIGHT += diffuse;
	SPECULAR_LIGHT += specular;
	// --- INDEPENDENT DESIGN END ---
}
