extends Node3D
class_name SkyController

## 昼夜循环总时长（秒）。例如 600 表示 10 分钟一天
@export var day_length_seconds: float = 600.0
## 时间流速倍率（1 为正常；2 为加速两倍）
@export var time_scale: float = 1.0
## 当前时间（0~1）。约定：0.25 日出、0.5 正午、0.75 日落、0.0/1.0 午夜
@export_range(0.0, 1.0, 0.0001) var time_of_day: float = 0.35
## 是否自动推进时间
@export var time_running: bool = true

## 维度：主世界/下界/末地（最简实现：仅影响基础天空色）
@export_enum("主世界:0", "下界:1", "末地:2") var dimension: int = 0

## 主世界：上半天空白天基础色（默认 #78A7FF）
@export var overworld_sky_top_day: Color = Color8(0x78, 0xA7, 0xFF, 0xFF)
## 主世界：下半天空白天基础色（默认 #C0D8FF）
@export var overworld_sky_bottom_day: Color = Color8(0xC0, 0xD8, 0xFF, 0xFF)
## 夜晚天空颜色（默认 #0F0F0F）
@export var night_color: Color = Color8(0x0F, 0x0F, 0x0F, 0xFF)
## 日出/日落过渡宽度（越大黄昏越长、过渡越慢）
@export_range(0.01, 0.25, 0.001) var twilight_width: float = 0.10

## 太阳贴图（默认会尝试加载 res://resources/textures/environment/celestial/sun.png）
@export var sun_texture: Texture2D
## 月亮月相贴图列表（8 张）。为空时会按默认路径加载
@export var moon_phase_textures: Array[Texture2D] = []

## 太阳是否使用“加法混合”（可隐藏贴图的黑色背景，效果更接近 MC）
@export var sun_additive_blend: bool = true
## 月亮是否使用“加法混合”（可避免月落/月出时贴图黑底穿帮，更接近 MC）
@export var moon_additive_blend: bool = true

## 天体距离（需小于相机 far，当前主相机 far=200）
@export var celestial_distance: float = 140.0
## 太阳显示直径（世界单位）。数值越大，屏幕上太阳越大
@export var sun_world_diameter: float = 40.0
## 月亮显示直径（世界单位）。数值越大，屏幕上月亮越大
@export var moon_world_diameter: float = 36.0
## 太阳额外缩放倍率（用于微调）
@export var sun_scale: float = 1.0
## 月亮额外缩放倍率（用于微调）
@export var moon_scale: float = 1.0
## 天体轨道绕 Y 轴的倾斜角（度），用于让太阳/月亮不是严格沿一个平面转动
@export var orbit_yaw_deg: float = 45.0

## WorldEnvironment 节点路径（默认 ../WorldEnvironment）
@export var world_environment_path: NodePath = NodePath("../WorldEnvironment")
## 主相机节点路径（为空则自动查找当前 viewport 的 Camera3D）
@export var camera_path: NodePath
## VoxelWorld 节点路径（用于把“天空亮度（渲染用）”同步给体素材质）
@export var voxel_world_path: NodePath = NodePath("../VoxelWorld")

## 是否显示云层（最简实现：平面云，效果接近 MC 的“流畅”云）
@export var clouds_enabled: bool = true
## 云纹理（默认加载 res://resources/textures/environment/clouds.png）
@export var clouds_texture: Texture2D
## 云层高度（MC 1.17+ 约为 Y=192~196，这里取中间值 194）
@export var clouds_height: float = 194.0
## 云层在水平方向的“纹理缩放”（世界单位/一张纹理）。数值越大，云越“大块”
@export var clouds_tile_world_size: float = 4096.0
## 云整体不透明度（0~1）。数值越大云越“实”，也越容易遮住太阳
@export_range(0.0, 1.0, 0.01) var clouds_opacity: float = 0.35
## 云层厚度（世界单位）。0 表示单层平面云
@export_range(0.0, 32.0, 0.1) var clouds_thickness: float = 5.0
## 云层厚度的分层数（越大越厚实，但更耗填充率）
@export_range(1, 12, 1) var clouds_layers: int = 5
## 云层移动速度（世界单位/秒）。MC 云会向西飘浮，这里默认向 -X
@export var clouds_speed_world: Vector2 = Vector2(-12.0, 0.0)
## 云层可见的最大半径（世界单位）。越大越接近“渲染到地平线”，但更耗一些填充率
@export var clouds_radius: float = 900.0
## 云颜色（白天）
@export var clouds_day_color: Color = Color(1.0, 1.0, 1.0, 1.0)
## 云颜色（夜晚，略偏暗蓝）
@export var clouds_night_color: Color = Color(0.25, 0.30, 0.45, 1.0)
## 夜晚云透明度倍率（0~1）。数值越小夜晚越“淡”
@export_range(0.0, 1.0, 0.01) var clouds_night_alpha_mul: float = 0.55

## 是否由 SkyController 自动创建“太阳方向光 + 月亮方向光”（用于照明与投影）
@export var use_celestial_lights: bool = true
## 黄昏/黎明的光照颜色（让日出日落更暖，接近 MC 观感）
@export var twilight_light_color: Color = Color(1.0, 0.70, 0.40, 1.0)
## 太阳光是否投射阴影
@export var sun_cast_shadows: bool = true
## 月光是否投射阴影
@export var moon_cast_shadows: bool = true

var _world_env: WorldEnvironment
var _camera: Camera3D
var _voxel_world: Node
var _sun_light: DirectionalLight3D
var _moon_light: DirectionalLight3D

var _sky: Sky
var _sky_mat: ProceduralSkyMaterial

## 白天方向光强度（太阳）
@export var day_light_energy: float = 2.4
## 夜晚方向光强度（月光）。设为 0 可关闭夜间阴影与照明
@export var night_light_energy: float = 0.18
## 白天方向光颜色（偏暖）
@export var day_light_color: Color = Color(1.0, 0.98, 0.92, 1.0)
## 夜晚方向光颜色（偏冷）
@export var night_light_color: Color = Color(0.55, 0.65, 1.0, 1.0)

## 白天环境光强度（决定阴影里的基础亮度；数值越大洞穴越亮）
@export var ambient_day_energy: float = 0.22
## 夜晚环境光强度
@export var ambient_night_energy: float = 0.02
## 白天环境光颜色（偏冷更接近天空散射）
@export var ambient_day_color: Color = Color(0.9, 0.95, 1.0, 1.0)
## 夜晚环境光颜色（更暗、更冷）
@export var ambient_night_color: Color = Color(0.12, 0.16, 0.25, 1.0)
## 环境光能量变化的平滑速度（避免进出洞口“啪”一下跳变）
@export_range(0.0, 40.0, 0.1) var ambient_smooth_speed: float = 10.0

## 是否启用方向光阴影（投射体素地形/玩家的影子）
@export var shadows_enabled: bool = true
## 阴影最大距离（越大阴影覆盖越远，但更耗性能）
@export var shadow_max_distance: float = 120.0
## 阴影偏移（防止阴影痤疮；过大会“飘”）
@export var shadow_bias: float = 0.015
## 法线偏移（进一步减少痤疮；过大会导致阴影断开）
@export var shadow_normal_bias: float = 0.6

var _sun_sprite: Sprite3D
var _moon_sprite: Sprite3D
var _clouds_root: Node3D
var _clouds_planes: Array[MeshInstance3D] = []
var _clouds_mat: ShaderMaterial
var _clouds_time: float = 0.0

var _day_count: int = 0
var _last_time_of_day: float = -1.0
var _ambient_energy_current: float = -1.0


func _ready() -> void:
	_resolve_nodes()
	_ensure_sky()
	_ensure_celestials()
	_ensure_clouds()
	_ensure_celestial_lights()
	_apply_all(0.0)


func _process(delta: float) -> void:
	if time_running and day_length_seconds > 0.01:
		var step: float = (delta * time_scale) / day_length_seconds
		var next_time: float = fposmod(time_of_day + step, 1.0)
		if _last_time_of_day >= 0.0:
			# 以“正午（0.5）穿越点”作为“新的一天”计数点：
			# - 午夜时月亮通常可见且接近正上空，若在此刻换月相会明显穿帮
			# - 正午时月亮不可见，把月相推进放到这里可以从根因上避免“抬头看月亮突然变相”
			if _last_time_of_day < 0.5 and (next_time >= 0.5 or next_time < _last_time_of_day):
				_day_count += 1
		time_of_day = next_time

	_apply_all(delta)
	_last_time_of_day = time_of_day


func _resolve_nodes() -> void:
	_world_env = get_node_or_null(world_environment_path) as WorldEnvironment

	if camera_path != NodePath(""):
		_camera = get_node_or_null(camera_path) as Camera3D
	if _camera == null:
		var cam: Camera3D = get_viewport().get_camera_3d()
		_camera = cam

	if voxel_world_path != NodePath(""):
		_voxel_world = get_node_or_null(voxel_world_path)
	if _voxel_world == null:
		_voxel_world = get_node_or_null("../VoxelWorld")


func _ensure_sky() -> void:
	if _world_env == null:
		return
	if _world_env.environment == null:
		_world_env.environment = Environment.new()

	var env: Environment = _world_env.environment
	env.background_mode = Environment.BG_SKY

	if env.sky == null:
		_sky = Sky.new()
		env.sky = _sky
	else:
		_sky = env.sky

	if _sky.sky_material == null or not (_sky.sky_material is ProceduralSkyMaterial):
		_sky_mat = ProceduralSkyMaterial.new()
		_sky.sky_material = _sky_mat
	else:
		_sky_mat = _sky.sky_material as ProceduralSkyMaterial

	_sky_mat.sun_angle_max = 0.0
	if env.has_method("set_tonemap_auto_exposure"):
		env.call("set_tonemap_auto_exposure", false)
	elif env.has_method("set_auto_exposure_enabled"):
		env.call("set_auto_exposure_enabled", false)
	if env.has_method("set_tonemap_exposure"):
		env.call("set_tonemap_exposure", 1.0)


func _ensure_celestials() -> void:
	if sun_texture == null:
		sun_texture = load("res://resources/textures/environment/celestial/sun.png")

	if moon_phase_textures.is_empty():
		var base: String = "res://resources/textures/environment/celestial/moon/"
		var names: Array[String] = [
			"new_moon.png",
			"waxing_crescent.png",
			"first_quarter.png",
			"waxing_gibbous.png",
			"full_moon.png",
			"waning_gibbous.png",
			"third_quarter.png",
			"waning_crescent.png",
		]
		for n in names:
			var t: Texture2D = load(base + n)
			if t != null:
				moon_phase_textures.push_back(t)

	if _sun_sprite == null:
		_sun_sprite = Sprite3D.new()
		_sun_sprite.name = "SunSprite3D"
		_sun_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_sun_sprite.shaded = false
		_sun_sprite.no_depth_test = true
		_sun_sprite.modulate = Color(1.0, 1.0, 1.0, 1.0)
		add_child(_sun_sprite)

	if _moon_sprite == null:
		_moon_sprite = Sprite3D.new()
		_moon_sprite.name = "MoonSprite3D"
		_moon_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_moon_sprite.shaded = false
		_moon_sprite.no_depth_test = true
		_moon_sprite.modulate = Color(1.0, 1.0, 1.0, 1.0)
		add_child(_moon_sprite)

	_apply_sprite_material(_sun_sprite, sun_texture, sun_additive_blend)
	if _moon_sprite != null and not moon_phase_textures.is_empty():
		_apply_sprite_material(_moon_sprite, moon_phase_textures[0], moon_additive_blend)


func _ensure_clouds() -> void:
	if not clouds_enabled:
		if _clouds_root != null and is_instance_valid(_clouds_root):
			_clouds_root.visible = false
		return

	if clouds_texture == null:
		clouds_texture = load("res://resources/textures/environment/clouds.png")

	if _clouds_root == null:
		_clouds_root = Node3D.new()
		_clouds_root.name = "Clouds"
		_clouds_root.visible = true
		add_child(_clouds_root)

	if _clouds_mat == null:
		_clouds_mat = ShaderMaterial.new()
		_clouds_mat.shader = load("res://shaders/clouds.gdshader") as Shader
	_clouds_planes.clear()

	var r: float = max(10.0, clouds_radius)
	var layer_count: int = clampi(clouds_layers, 1, 12)
	var thickness: float = max(0.0, clouds_thickness)
	var step_y: float = 0.0 if layer_count <= 1 else (thickness / float(layer_count - 1))

	for i in range(layer_count):
		var m: MeshInstance3D = MeshInstance3D.new()
		m.name = "CloudLayer" + str(i)
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.visible = true
		var plane: PlaneMesh = PlaneMesh.new()
		plane.size = Vector2(r * 2.0, r * 2.0)
		m.mesh = plane
		m.material_override = _clouds_mat
		m.position = Vector3(0.0, step_y * float(i), 0.0)
		_clouds_root.add_child(m)
		_clouds_planes.append(m)

	_clouds_root.visible = true

	if _clouds_mat != null:
		if clouds_texture != null:
			_clouds_mat.set_shader_parameter("clouds_tex", clouds_texture)
		_clouds_mat.set_shader_parameter("tile_world_size", max(1.0, clouds_tile_world_size))
		_clouds_mat.set_shader_parameter("base_opacity", clampf(clouds_opacity, 0.0, 1.0))


func _apply_clouds(delta: float) -> void:
	if _clouds_root == null or _clouds_mat == null:
		return

	if not clouds_enabled:
		_clouds_root.visible = false
		return

	if _camera == null or not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_3d()
	if _camera == null:
		return

	_clouds_root.visible = true
	_clouds_time += max(0.0, delta)

	var cam_pos: Vector3 = _camera.global_position

	var dy: float = absf(clouds_height - cam_pos.y)
	var required_far: float = sqrt(clouds_radius * clouds_radius + dy * dy) + 20.0
	if _camera.far < required_far:
		_camera.far = required_far

	_clouds_root.global_position = Vector3(cam_pos.x, clouds_height, cam_pos.z)

	var sun_height: float = _get_sun_height()
	var night_t: float = _night_factor(sun_height)
	var c: Color = clouds_day_color.lerp(clouds_night_color, night_t)
	var a_mul: float = lerpf(1.0, clampf(clouds_night_alpha_mul, 0.0, 1.0), night_t)

	_clouds_mat.set_shader_parameter("clouds_color", Vector4(c.r, c.g, c.b, 1.0))
	var layer_count: int = clampi(clouds_layers, 1, 12)
	var base_op: float = clampf(clouds_opacity, 0.0, 1.0)
	_clouds_mat.set_shader_parameter("base_opacity", base_op)
	_clouds_mat.set_shader_parameter("alpha_mul", a_mul / max(1.0, float(layer_count)))

	var off: Vector2 = clouds_speed_world * _clouds_time / max(1.0, clouds_tile_world_size)
	_clouds_mat.set_shader_parameter("uv_offset", off)


func _apply_all(_delta: float) -> void:
	if _sky_mat != null:
		_apply_sky_colors()
	_apply_environment_ambient(_delta)
	_apply_celestial_sprites()
	_apply_celestial_lights()
	_apply_voxel_sky_brightness()
	_apply_clouds(_delta)


func _apply_voxel_sky_brightness() -> void:
	if _voxel_world == null or not is_instance_valid(_voxel_world):
		return
	if not _voxel_world.has_method("set_sky_brightness"):
		return

	var sun_height: float = _get_sun_height()
	var w: float = max(0.001, twilight_width)
	var sun_factor: float = _smoothstep(0.0, w, sun_height)
	var sky_brightness: float = lerpf(0.12, 1.0, sun_factor)
	_voxel_world.call("set_sky_brightness", sky_brightness)


func _apply_sky_colors() -> void:
	var base_top: Color = night_color
	var base_bottom: Color = night_color

	if dimension == 0:
		base_top = overworld_sky_top_day
		base_bottom = overworld_sky_bottom_day

	var sun_height: float = _get_sun_height()
	var night_t: float = _night_factor(sun_height)

	var top: Color = base_top.lerp(night_color, night_t)
	var bottom: Color = base_bottom.lerp(night_color, night_t)

	_sky_mat.sky_top_color = top
	_sky_mat.sky_horizon_color = top.lerp(bottom, 0.65)
	_sky_mat.ground_horizon_color = bottom
	_sky_mat.ground_bottom_color = bottom.lerp(night_color, 0.35 + 0.65 * night_t)


func _ensure_celestial_lights() -> void:
	if not use_celestial_lights:
		return

	if _sun_light == null:
		_sun_light = DirectionalLight3D.new()
		_sun_light.name = "SunDirectionalLight3D"
		add_child(_sun_light)

	if _moon_light == null:
		_moon_light = DirectionalLight3D.new()
		_moon_light.name = "MoonDirectionalLight3D"
		add_child(_moon_light)


func _apply_celestial_lights() -> void:
	if not use_celestial_lights:
		return

	_ensure_celestial_lights()
	if _sun_light == null or _moon_light == null:
		return

	var sun_dir: Vector3 = _get_sun_dir()
	var sun_height: float = sun_dir.y

	var w: float = max(0.001, twilight_width)
	var sun_factor: float = _smoothstep(0.0, w, sun_height)
	var moon_factor: float = _smoothstep(0.0, w, -sun_height)
	var twilight_t: float = clampf(1.0 - absf(sun_height) / w, 0.0, 1.0)

	var sun_energy: float = day_light_energy * sun_factor
	var moon_energy: float = night_light_energy * moon_factor

	var sun_color: Color = day_light_color.lerp(twilight_light_color, twilight_t)
	var moon_color: Color = night_light_color

	_sun_light.light_energy = sun_energy
	_sun_light.light_color = sun_color
	_sun_light.shadow_enabled = shadows_enabled and sun_cast_shadows and sun_energy > 0.01
	_sun_light.directional_shadow_max_distance = max(5.0, shadow_max_distance)
	_sun_light.shadow_bias = shadow_bias
	_sun_light.shadow_normal_bias = shadow_normal_bias
	var sun_gt: Transform3D = _sun_light.global_transform
	var sun_ray_dir: Vector3 = -sun_dir
	if _camera != null and is_instance_valid(_camera) and _sun_sprite != null and is_instance_valid(_sun_sprite):
		var to_sun: Vector3 = (_sun_sprite.global_position - _camera.global_position).normalized()
		if to_sun.length() > 0.00001:
			sun_ray_dir = -to_sun
	sun_gt.basis = _basis_from_ray_dir(sun_ray_dir)
	_sun_light.global_transform = sun_gt

	_moon_light.light_energy = moon_energy
	_moon_light.light_color = moon_color
	_moon_light.shadow_enabled = shadows_enabled and moon_cast_shadows and moon_energy > 0.01
	_moon_light.directional_shadow_max_distance = max(5.0, shadow_max_distance)
	_moon_light.shadow_bias = shadow_bias
	_moon_light.shadow_normal_bias = shadow_normal_bias
	var moon_gt: Transform3D = _moon_light.global_transform
	var moon_ray_dir: Vector3 = sun_dir
	if _camera != null and is_instance_valid(_camera) and _moon_sprite != null and is_instance_valid(_moon_sprite):
		var to_moon: Vector3 = (_moon_sprite.global_position - _camera.global_position).normalized()
		if to_moon.length() > 0.00001:
			moon_ray_dir = -to_moon
	moon_gt.basis = _basis_from_ray_dir(moon_ray_dir)
	_moon_light.global_transform = moon_gt


func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t: float = 0.0
	var d: float = edge1 - edge0
	if absf(d) > 0.000001:
		t = clampf((x - edge0) / d, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _basis_from_ray_dir(ray_dir: Vector3) -> Basis:
	var d: Vector3 = ray_dir.normalized()
	var z_axis: Vector3 = -d
	var x_axis: Vector3 = Vector3.UP.cross(z_axis)
	if x_axis.length() < 0.0001:
		x_axis = Vector3.RIGHT
	else:
		x_axis = x_axis.normalized()
	var y_axis: Vector3 = z_axis.cross(x_axis).normalized()
	var b: Basis = Basis()
	b.x = x_axis
	b.y = y_axis
	b.z = z_axis
	return b


func _apply_environment_ambient(delta: float) -> void:
	if _world_env == null or _world_env.environment == null:
		return
	var env: Environment = _world_env.environment

	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR

	var sun_height: float = _get_sun_height()
	var night_t: float = _night_factor(sun_height)

	var base_energy: float = lerpf(ambient_day_energy, ambient_night_energy, night_t)
	var base_color: Color = ambient_day_color.lerp(ambient_night_color, night_t)
	var energy: float = base_energy

	if _ambient_energy_current < 0.0:
		_ambient_energy_current = energy
	else:
		var speed: float = max(0.0, ambient_smooth_speed)
		if speed <= 0.00001:
			_ambient_energy_current = energy
		else:
			var k: float = 1.0 - exp(-speed * max(0.0, delta))
			_ambient_energy_current = lerpf(_ambient_energy_current, energy, k)

	env.ambient_light_color = base_color
	env.ambient_light_energy = _ambient_energy_current


func _apply_celestial_sprites() -> void:
	if _camera == null:
		_camera = get_viewport().get_camera_3d()
	if _camera == null:
		return

	var cam_pos: Vector3 = _camera.global_position
	var dir: Vector3 = _get_sun_dir()

	if _sun_sprite != null:
		_sun_sprite.global_position = cam_pos + dir * celestial_distance
		_apply_sprite_size(_sun_sprite, _sun_sprite.texture, sun_world_diameter, sun_scale)
		_sun_sprite.visible = _get_sun_height() > -0.12

	if _moon_sprite != null:
		_moon_sprite.global_position = cam_pos - dir * celestial_distance
		_moon_sprite.visible = _get_sun_height() < 0.12

		var moon_tex: Texture2D = _get_moon_phase_texture()
		if moon_tex != null:
			if _moon_sprite.texture != moon_tex:
				_apply_sprite_material(_moon_sprite, moon_tex, moon_additive_blend)
			_apply_sprite_size(_moon_sprite, moon_tex, moon_world_diameter, moon_scale)


func _solar_phase() -> float:
	return (time_of_day - 0.25) * TAU


func _get_sun_height() -> float:
	return sin(_solar_phase())

func _get_sun_dir() -> Vector3:
	var yaw: float = deg_to_rad(orbit_yaw_deg)
	var phase: float = _solar_phase()
	var dir: Vector3 = Vector3(cos(phase), sin(phase), 0.0)
	dir = Basis(Vector3.UP, yaw) * dir
	return dir.normalized()


func _night_factor(sun_height: float) -> float:
	var w: float = max(0.001, twilight_width)
	var t: float = clampf((w - sun_height) / (2.0 * w), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _get_moon_phase_texture() -> Texture2D:
	if moon_phase_textures.is_empty():
		return null
	var idx: int = _day_count % moon_phase_textures.size()
	return moon_phase_textures[idx]


func _apply_sprite_material(sprite: Sprite3D, tex: Texture2D, additive: bool) -> void:
	if sprite == null:
		return
	sprite.texture = tex

	if tex == null:
		sprite.material_override = null
		return

	var m: StandardMaterial3D = StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = tex
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if additive:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	else:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sprite.material_override = m


func _apply_sprite_size(sprite: Sprite3D, tex: Texture2D, world_diameter: float, extra_scale: float) -> void:
	if sprite == null or tex == null:
		return
	var tex_px: float = max(1.0, max(tex.get_width(), tex.get_height()) * 1.0)
	var diameter: float = max(0.01, world_diameter)
	var px_size: float = diameter / tex_px
	sprite.pixel_size = px_size
	sprite.scale = Vector3.ONE * max(0.01, extra_scale)
