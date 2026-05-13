shader_type spatial;
// ============================================================
// 云层着色器 (clouds.gdshader)
// ============================================================
// 作用：渲染天空中的半透明云层（多层PlaneMesh堆叠，跟随相机移动）
// 所属模块：SkyController — 由天空控制器创建多层MeshInstance3D，共享此材质
//
// 工作原理：
//   1. 从世界坐标的 xz 平面采样云纹理（world_pos.xz / tile_world_size + uv_offset）
//   2. 只取纹理红通道作为不透明度（灰度图 → alpha）
//   3. 不透明度受 base_opacity（基础透明度）和 alpha_mul（层分摊系数）控制
//   4. 使用 blend_mix 混合模式，使云层半透明叠加在天空上
//   5. render_mode unshaded — 不受场景光照影响（云自身发光，保持颜色稳定）
//   6. depth_draw_never — 不写深度缓冲区（避免云层遮挡方块线框等UI元素）
// ============================================================

render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;
// unshaded: 无光照 — 云层颜色不受太阳/月亮方向光影响
// blend_mix: Alpha混合 — 云层以半透明方式叠加到天空背景上
// cull_disabled: 双面渲染 — 从云层下方也能看到云（云层是平面，需要双面可见）
// depth_draw_never: 不写深度 — 避免半透明云层错误遮挡其他物体

// -----------------------------------------------------------
// Uniform 参数 — 由 SkyController 在 _apply_clouds() 中每帧更新
// -----------------------------------------------------------

// 云纹理 — 单通道灰度图（只用R通道），repeat模式使云平铺
uniform sampler2D clouds_tex : source_color, filter_nearest, repeat_enable;

// 云颜色（RGB）— 由SkyController按昼夜插值设置的云的颜色
//  白天：白色 clouds_day_color
//  夜晚：偏暗蓝 clouds_night_color
uniform vec4 clouds_color : source_color = vec4(1.0);

// 云层基础不透明度 — 控制云的整体浓度（值越大云越实）
// 对应SkyController的 clouds_opacity（默认0.35）
uniform float base_opacity : hint_range(0.0, 1.0) = 0.35;

// 单层透明度乘数 — 多层叠加时的层分摊系数
// 计算方式: alpha_mul = (base_opacity * night_alpha_mul) / layer_count
// 保证总不透明度不超过预期值
uniform float alpha_mul : hint_range(0.0, 2.0) = 1.0;

// UV偏移 — 云层在世界空间中的移动
// 每帧累加: uv_offset = clouds_speed_world * time / tile_world_size
// x分量控制x方向飘动，y分量控制z方向飘动
uniform vec2 uv_offset = vec2(0.0);

// 纹理覆盖的世界尺寸 — 一张纹理平铺覆盖多少世界单位
// 值越大云端看起来越"大块"（纹理拉伸），值越小云端越密
// 对应SkyController的 clouds_tile_world_size（默认4096.0）
uniform float tile_world_size : hint_range(1.0, 8192.0) = 4096.0;

// 世界坐标 — 从 vertex() 传递到 fragment()
varying vec3 world_pos;

// ============================================================
// Vertex Shader — 计算世界坐标
// ============================================================
void vertex() {
	// 将模型局部坐标变换到世界空间
	// MODEL_MATRIX 包含了云层根节点的全局位置（随相机移动）
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// ============================================================
// Fragment Shader — 采样纹理并计算透明度
// ============================================================
void fragment() {
	// 步骤1：从世界坐标xz平面计算UV
	// 世界坐标除以 tile_world_size → 纹理空间坐标
	// 加上 uv_offset → 实现云层随时间飘动
	vec2 uv = world_pos.xz / max(tile_world_size, 0.0001) + uv_offset;

	// 步骤2：采样云纹理
	// 使用纹理R通道作为不透明度（灰度云图）
	vec4 t = texture(clouds_tex, uv);

	// 步骤3：计算最终Alpha
	// alpha = R通道 * 基础浓度 * 层分摊系数
	// clamp 到 0~1 防止叠加超出范围
	float a = clamp(t.r, 0.0, 1.0)
	        * clamp(base_opacity, 0.0, 1.0)
	        * clamp(alpha_mul, 0.0, 2.0);

	// 步骤4：输出
	ALBEDO = clouds_color.rgb;  // 云颜色（RGB通由SkyController设置）
	ALPHA = a;                  // 云不透明度（决定与天空的混合比例）
}
