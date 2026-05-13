shader_type spatial;
// ============================================================
// 体素方块着色器 (voxel_lit.gdshader)
// ============================================================
// 作用：渲染所有体素方块的表面，实现纹理采样、群系染色、侧面覆盖层叠加、光照计算。
// 所属模块：渲染层 — 被 VoxelWorld 创建为 ShaderMaterial，赋值给每个 Chunk 的 MeshInstance3D。
//
// 数据流概要：
//   CPU端（VoxelChunk.rebuild_mesh）写入顶点属性 →
//     POSITION: 面顶点的世界坐标
//     NORMAL: 面的法线方向
//     TEXCOORD0 (UV): 指向 Texture Atlas 中对应 tile 的 UV 坐标
//     TEXCOORD1 (UV2): x=打包的群系ID与树叶标志, y=alpha裁剪阈值
//     COLOR: r=草顶面掩码, g=草侧面覆盖层掩码, b=天光值(0~1), a=方块光(预留)
//   GPU端（本Shader）在 fragment() 中解码上述属性，计算最终颜色。
//
// 关键视觉效果：
//   1. 群系染色 — 草方块顶面/侧面覆盖层颜色随群系(平原绿/森林深绿/干旱黄)变化
//   2. 侧面覆盖层 — 草方块侧面叠加一层半透明草皮纹理
//   3. Alpha裁剪 — 玻璃/树叶等通过 ALPHA_SCISSOR_THRESHOLD 实现镂空
//   4. 天光衰减 — 洞穴内天光值逐格递减，实现明暗过渡
// ============================================================

render_mode cull_back, depth_draw_opaque, diffuse_lambert, specular_disabled;
// cull_back: 背面剔除 — 只渲染面向相机的面(外法线朝向相机)，配合CPU端CW绕序
// depth_draw_opaque: 不透明深度写入 — 确保体素方块正确遮挡，写入深度缓冲区
// diffuse_lambert: 使用Lambert漫反射模型
// specular_disabled: 禁用引擎默认镜面高光（改用ROUGHNESS/METALLIC/SPECULAR手动控制）

// -----------------------------------------------------------
// Uniform 参数 — 由CPU端通过 ShaderMaterial.set_shader_parameter() 设置
// -----------------------------------------------------------

// 纹理图集：一张大图包含所有方块的贴图tile
uniform sampler2D atlas_texture : source_color, filter_nearest, repeat_disable;
// filter_nearest: 最近邻采样 — 保持像素风锐利
// repeat_disable: 不重复 — UV超出[0,1]时钳位，防止采样到相邻tile

// 群系颜色查找表开关（colormap = 预烘焙的颜色渐变图）
uniform bool use_colormap = false;

// 三张群系颜色查找表：草色 / 树叶色 / 干旱草色
// filter_linear: 线性插值 — colormap需要平滑过渡
uniform sampler2D grass_colormap : source_color, filter_linear, repeat_disable;
uniform sampler2D foliage_colormap : source_color, filter_linear, repeat_disable;
uniform sampler2D dry_foliage_colormap : source_color, filter_linear, repeat_disable;

// 反照率色调 — 对所有纹理颜色做乘法调色（保留用于全局微调）
uniform vec3 albedo_tint : source_color = vec3(1.0);

// 基础染色颜色（兜底，colormap关闭时使用）
uniform vec3 grass_tint : source_color = vec3(0.35, 0.70, 0.25);
uniform vec3 leaves_tint : source_color = vec3(0.25, 0.70, 0.25);

// 群系颜色变化强度 — 控制世界坐标噪声对染色的微调幅度
uniform float biome_variation_strength : hint_range(0.0, 1.0) = 0.65;
// 群系颜色变化的空间尺度
uniform float biome_variation_scale : hint_range(0.0001, 0.1) = 0.0025;
// 群系分布尺度（与CPU端 biome_map_scale 对应）
uniform float biome_map_scale : hint_range(0.0001, 0.02) = 0.0012;
// 区块世界尺寸 = chunk_size * voxel_scale（用于世界坐标计算）
uniform float chunk_world_size : hint_range(1.0, 1024.0) = 16.0;
// 群系种子（与CPU端 terrain_seed 一致）
uniform int biome_seed = 1337;

// 体素缩放因子
uniform float voxel_scale : hint_range(0.1, 10.0) = 1.0;

// 图集行数 — 用于侧面覆盖层UV偏移计算（覆盖层在下一行）
uniform float atlas_rows : hint_range(1.0, 8.0) = 2.0;

// PBR材质参数
uniform float roughness : hint_range(0.0, 1.0) = 0.95;

// 天空亮度 — 由SkyController驱动，昼夜变化时更新（0=黑夜, 1=正午）
uniform float sky_brightness : hint_range(0.0, 1.0) = 1.0;

// 最低光照 — 保证背光面不会全黑（模拟环境光散射）
uniform float min_light : hint_range(0.0, 1.0) = 0.06;

// 光照曲线指数 — 控制光照衰减的非线性程度（>1 使暗部更暗）
uniform float light_curve : hint_range(0.1, 3.0) = 1.6;

// -----------------------------------------------------------
// Varying — 从 vertex() 传递到 fragment() 的插值变量
// -----------------------------------------------------------
varying vec3 world_pos;      // 当前片元的世界坐标
varying float v_sky_light;   // 天光值(0~1)，从顶点色 COLOR.b 读取
varying float v_block_light; // 方块光(0~1)，从顶点色 COLOR.a 读取（预留）

// ============================================================
// 辅助函数：噪声生成
// 用途：在世界空间中生成伪随机噪声，用于群系颜色微调和群系边界过渡
// ============================================================

// 二维哈希函数 — 输入二维坐标，输出一个伪随机值 [0,1)
// 原理：点积 + sin 产生高频振荡，再 fract 取小数部分
float _hash12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// 另一种种子常数的哈希函数变体
float _hash22(vec2 p) {
	return fract(sin(dot(p, vec2(269.5, 183.3))) * 43758.5453);
}

// 二维值噪声 — 在四个格点哈希值之间做平滑插值
// 原理：把空间分成整数格子，每个格点一个随机值，
//       然后在四个格点之间用 smoothstep 插值得到连续的噪声值
float _noise2(vec2 p) {
	vec2 i = floor(p);           // 当前格子的左下角整数坐标
	vec2 f = fract(p);           // 在当前格子内的小数偏移
	// 四个角点的哈希值
	float a = _hash12(i);
	float b = _hash12(i + vec2(1.0, 0.0));
	float c = _hash12(i + vec2(0.0, 1.0));
	float d = _hash12(i + vec2(1.0, 1.0));
	// Hermite平滑曲线: 3t² - 2t³, 使格点间过渡连续且可导
	vec2 u = f * f * (3.0 - 2.0 * f);
	// 在x方向插值，再在y方向插值 = 双线性插值
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// ============================================================
// Vertex Shader — 将CPU端传来的顶点属性转发给 fragment()
// ============================================================
void vertex() {
	// 计算世界坐标：
	// MODEL_MATRIX * VERTEX = 模型空间→世界空间的变换
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// 天光值：COLOR.b 由CPU端在网格生成时写入
	// 值为 BFS 天光传播计算出的 0~15 归一化到 0~1
	v_sky_light = COLOR.b;

	// 方块光：COLOR.a 为预留字段（当前均为0）
	v_block_light = COLOR.a;
}

// ============================================================
// Fragment Shader — 计算每个像素的最终颜色
// ============================================================
void fragment() {
	// -------- 步骤1：采样基础纹理 --------
	// 从纹理图集的当前UV位置采样（filter_nearest 保证像素风锐利）
	vec4 tex = textureLod(atlas_texture, UV, 0.0);

	// -------- 步骤2：解码顶点色编码 --------
	// alpha_cutoff = UV2.y: 当前方块类型的 Alpha 裁剪阈值
	//   0.0 = 不裁剪（实体方块）
	//   >0.0 = 像素alpha < 阈值时丢弃片元（树叶镂空/玻璃透明）
	float alpha_cutoff = clamp(UV2.y, 0.0, 1.0);

	// grass_top_mask = COLOR.r: 顶面染色掩码
	//   1.0 = 草顶面（需要群系染色）
	//   适用：草方块顶面、树叶所有面
	float grass_top_mask = clamp(COLOR.r, 0.0, 1.0);

	// grass_side_overlay_mask = COLOR.g: 侧面覆盖层掩码
	//   1.0 = 需要在基础纹理上叠加覆盖层纹理
	//   适用：草方块侧面（叠加草皮覆盖层）
	float grass_side_overlay_mask = clamp(COLOR.g, 0.0, 1.0);

	// -------- 步骤3：解码 UV2.x 中的打包数据 --------
	// UV2.x 编码格式：
	//   高半段: leaf_flag (0=非树叶, 0.5=树叶)
	//   低半段: biome_id (0/1/2 = 平原/森林/干旱)
	//
	// 解码逻辑：
	//   leaf_mask = 1.0 当 UV2.x >= 0.5（通过 step 函数）
	//   biome_part = UV2.x 去掉 leaf_mask 偏移后的值
	//   biome_id = biome_part * 8 后取整，钳制到 0~2.999 → 得 0/1/2
	float leaf_mask = step(0.5, UV2.x);
	float biome_part = UV2.x - leaf_mask * 0.5;
	float biome_id = floor(clamp(biome_part * 8.0, 0.0, 2.999));

	// -------- 步骤4：查群系颜色查找表(colormap) --------
	// th = 在colormap纹理上采样的水平坐标
	//   不同的 biome_id 对应 colormap 上不同位置的颜色：
	//   biome_id=0 (平原): th.x=0.60 (偏绿)
	//   biome_id=1 (森林): th.x=0.70 (偏深绿)
	//   biome_id=2 (干旱): th.x=1.00 (偏黄)
	//   th.y 控制采样行（0.60=正常, 0.90=偏湿, 0.05=偏干）
	vec2 th = vec2(0.60, 0.60);
	if (biome_id > 1.5) {
		// 干旱群系
		th = vec2(1.0, 0.05);
	} else if (biome_id > 0.5) {
		// 森林群系
		th = vec2(0.70, 0.90);
	}

	// 初始化草色/叶色为基础值（colormap关闭时的兜底）
	vec3 grass_base = grass_tint;
	vec3 leaves_base = leaves_tint;

	if (use_colormap) {
		// 从三张预烘焙颜色查找表中采样群系色
		vec3 grass_cm = texture(grass_colormap, th).rgb;           // 草色表
		vec3 fol = texture(foliage_colormap, th).rgb;              // 叶色表
		vec3 dry = texture(dry_foliage_colormap, th).rgb;          // 干旱色表
		// is_dry = 1.0 如果 biome_id >= 2（干旱）
		float is_dry = step(1.5, biome_id);
		// 草色：干旱时混合grass_cm和dry，非干旱直接使用grass_cm
		grass_base = mix(grass_cm, mix(grass_cm, dry, 0.85), is_dry);
		// 叶色：干旱时使用dry，否则使用fol
		leaves_base = mix(fol, dry, is_dry);
	}

	// 群系微调系数
	float is_plains = 1.0 - step(0.5, biome_id);                    // 平原=1, 其他=0
	float is_forest = step(0.5, biome_id) * (1.0 - step(1.5, biome_id)); // 森林=1, 其他=0
	float grass_mul = 1.0;
	grass_mul = mix(grass_mul, 1.10, is_plains);   // 平原: 草色*1.10 (更亮绿)
	grass_mul = mix(grass_mul, 0.82, is_forest);    // 森林: 草色*0.82 (更暗绿)
	grass_base = clamp(grass_base * grass_mul, vec3(0.0), vec3(1.0));
	leaves_base = clamp(leaves_base * mix(1.0, 0.88, is_forest), vec3(0.0), vec3(1.0));

	// 根据 leaf_mask 选择草色还是叶色
	// leaf_mask=0 → tint = grass_base（用于草方块）
	// leaf_mask=1 → tint = leaves_base（用于树叶）
	vec3 tint = mix(grass_base, leaves_base, leaf_mask);

	// -------- 步骤5：颜色合成 --------
	// 基础颜色 = 纹理RGB * 全局色调
	vec3 base_rgb = tex.rgb * albedo_tint;
	// 顶面颜色 = 纹理RGB * (顶面掩码选择: tint或白色) * 全局色调
	vec3 top_rgb = tex.rgb * mix(vec3(1.0), tint, grass_top_mask) * albedo_tint;

	// 侧面覆盖层处理：
	// overlay_uv = 当前UV向下偏移一行（dv = 1/atlas_rows）
	// 图集组织：第0行=基础贴图, 第1行=覆盖层贴图
	float dv = 1.0 / max(atlas_rows, 1.0);
	vec2 overlay_uv = UV + vec2(0.0, dv);
	vec4 overlay = textureLod(atlas_texture, overlay_uv, 0.0);
	// 覆盖层染色后的颜色
	vec3 overlay_rgb = overlay.rgb * tint * albedo_tint;

	// 侧面颜色 =
	//   基础纹理部分: base_rgb * (1 - overlay.a * 侧面掩码)
	//   + 覆盖层部分: overlay_rgb * (overlay.a * 侧面掩码)
	// 即：overlay的alpha通道控制覆盖层的不透明度
	vec3 side_rgb = base_rgb * (1.0 - overlay.a * grass_side_overlay_mask)
	              + overlay_rgb * (overlay.a * grass_side_overlay_mask);

	// 最终反照率 = 在顶面和侧面之间按顶面掩码混合
	vec3 albedo = mix(side_rgb, top_rgb, grass_top_mask);

	// -------- 步骤6：光照计算 --------
	// 综合光照 = max(天光, 方块光) * 天空亮度
	float sky01 = clamp(v_sky_light, 0.0, 1.0) * clamp(sky_brightness, 0.0, 1.0);
	float blk01 = clamp(v_block_light, 0.0, 1.0);
	float light01 = max(sky01, blk01);

	// 应用光照曲线（指数变换使明暗更有层次感）
	light01 = pow(clamp(light01, 0.0, 1.0), light_curve);

	// 法线方向的光照衰减（模拟简单环境光遮蔽）：
	//   NORMAL.y 接近 +1（顶面） → shade=1.0（最亮，直射光）
	//   NORMAL.y 接近 -1（底面） → shade=0.5（最暗）
	//   NORMAL.y 接近 0（侧面）  → shade=0.8（中等）
	float shade = 0.8;
	if (NORMAL.y > 0.9) {
		shade = 1.0;
	} else if (NORMAL.y < -0.9) {
		shade = 0.5;
	}
	light01 = max(light01, min_light) * shade;

	// -------- 步骤7：输出 --------
	// 最终漫反射颜色 = 反照率 * 光照
	ALBEDO = albedo * light01;

	// Alpha — 纹理的alpha通道（非裁剪方块通常为1.0）
	ALPHA = tex.a;

	// Alpha裁剪阈值 — 当纹理alpha < 阈值时丢弃该片元
	// 用于实现树叶的镂空效果和玻璃的透明区域
	ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;

	// 环境光遮蔽（固定为1.0，无AO效果）
	AO = 1.0;

	// PBR参数
	METALLIC = 0.0;         // 非金属（方块是石头/泥土/木头等）
	ROUGHNESS = roughness;  // 粗糙度（由uniform统一控制，当前为0.95 = 非常粗糙）
	SPECULAR = 0.0;         // 镜面反射强度（已禁用，通过specular_disabled）
}
