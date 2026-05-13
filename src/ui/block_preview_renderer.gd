extends Node
class_name BlockPreviewRenderer

## ============================================================
## 方块3D预览渲染器 (BlockPreviewRenderer) — SubViewport离屏渲染图标
## ============================================================
## 职责：
##   1. 创建专用SubViewport + 正交相机 + 方向光 + 环境光
##   2. 为每个方块类型构造一个6面立方体网格（复用体素Shader材质）
##   3. 单帧渲染到SubViewport → 抓取Image → 生成ImageTexture缓存
##   4. 异步队列渲染（request_preview → 队列 → _process_queue_deferred）
##   5. 发出 preview_ready 信号通知Hotbar刷新
##
## 设计动机：
##   - 避免为每个方块预渲染PNG图标（8种方块=8张图，但新增方块需重新制图）
##   - SubViewport复用：所有方块共用一个Viewport依次渲染，不产生多个Viewport开销
##   - 异步队列：不阻塞主循环，渲染完成通过信号通知UI刷新
##
## 相机：正交投影 + 对角方向位置 (2.2, 2.0, 2.2) → 同时看到上/前/侧三面
## ============================================================

signal preview_ready(block_id: int, texture: Texture2D)

const BlockRegistryScript := preload("res://src/voxel/block_registry.gd")
const VoxelLitShader: Shader = preload("res://shaders/voxel_lit.gdshader")

## 预览渲染分辨率（像素）。越大越清晰，但渲染与缓存开销更高
@export var preview_size_px: int = 64
## 预览相机正交大小（决定方块在图标里占比）
@export var camera_ortho_size: float = 1.6
## 预览相机位置（建议使用对角方向，例如 (2, 2, 2)，可同时看到上/前/侧三面）
@export var camera_position: Vector3 = Vector3(2.2, 2.0, 2.2)
## 预览方块绕 Y 轴旋转角度（度）
@export var model_yaw_deg: float = 0.0
## 预览方块绕 X 轴旋转角度（度，负值表示向下俯视）
@export var model_pitch_deg: float = 0.0

## 方向光旋转角（度）
@export var light_rotation_deg: Vector3 = Vector3(-45.0, 45.0, 0.0)
## 方向光强度
@export var light_energy: float = 1.2
## 环境光颜色
@export var ambient_color: Color = Color(1.0, 1.0, 1.0, 1.0)
## 环境光强度
@export var ambient_energy: float = 0.65

var _atlas_texture: Texture2D
var _atlas_columns: int = 4
var _atlas_rows: int = 2
var _tile_pixels: int = 16
var _uv_padding_pixels: float = 0.0

var _cache: Dictionary = {}
var _in_flight: Dictionary = {}
var _queue: Array[int] = []
var _rendering: bool = false

var _viewport: SubViewport
var _root_3d: Node3D
var _camera: Camera3D
var _light: DirectionalLight3D
var _env: WorldEnvironment
var _mesh: MeshInstance3D
var _material: ShaderMaterial


func _ready() -> void:
	# 目的：建立一个“专用 SubViewport 渲染器”，把方块用固定相机/固定光照渲染成 Texture2D，供 UI 贴图使用。
	# 特点：
	# - 不需要预渲染 PNG 图标（完全实时 3D 渲染 + 缓存结果）
	# - 只用一个 SubViewport 复用渲染，避免为每个格子创建一个 Viewport 导致开销爆炸
	_ensure_viewport()
	_try_bind_from_voxel_world()


func request_preview(block_id: int) -> Texture2D:
	# 作用：请求某个方块的预览纹理。
	# - 如果缓存已存在：立即返回 Texture2D
	# - 如果缓存不存在：加入队列异步渲染，先返回 null；渲染完成会发出 preview_ready 信号
	if _cache.has(block_id):
		return _cache[block_id]

	if _in_flight.has(block_id):
		return null

	_in_flight[block_id] = true
	_queue.push_back(block_id)
	_process_queue()
	return null


func clear_cache() -> void:
	_cache.clear()
	_in_flight.clear()
	_queue.clear()
	_rendering = false


func _process_queue() -> void:
	if _rendering:
		return
	_rendering = true
	call_deferred("_process_queue_deferred")


func _process_queue_deferred() -> void:
	while not _queue.is_empty():
		var block_id: int = _queue.pop_front()
		_in_flight.erase(block_id)
		if _cache.has(block_id):
			continue

		_try_bind_from_voxel_world()
		if _atlas_texture == null:
			# 没有 atlas_texture 无法渲染；保留为 null，UI 可以退回到 icon_texture 或空图标
			continue

		var block: Resource = BlockRegistryScript.get_block(block_id)
		if block == null:
			continue

		var tex: Texture2D = await _render_once(block_id, block)
		if tex != null:
			_cache[block_id] = tex
			preview_ready.emit(block_id, tex)

	_rendering = false


func _try_bind_from_voxel_world() -> void:
	# 目的：尽可能复用世界里正在使用的 Atlas 与参数，保证 UI 预览与世界渲染一致。
	# 说明：当前项目 VoxelWorld 若未指定 atlas_texture，会在 _ready 里运行时生成默认图集。
	if _atlas_texture != null:
		return

	var root: Node = get_tree().current_scene
	if root == null:
		return
	var world: Node = root.get_node_or_null("VoxelWorld")
	if world == null:
		return

	var t: Texture2D = world.get("atlas_texture")
	if t == null:
		return
	_atlas_texture = t

	# 说明：本项目环境里避免使用 int(...) 作为“类型转换构造器”，统一走字符串转换。
	_atlas_columns = max(1, str(world.get("atlas_columns")).to_int())
	_atlas_rows = max(1, str(world.get("atlas_rows")).to_int())

	# 说明：tile_pixels 是“图集每格像素尺寸”；VoxelWorld 里是内部变量，这里用图集尺寸反推。
	var atlas_w: int = _atlas_texture.get_width()
	_tile_pixels = max(1, floori(atlas_w / (_atlas_columns * 1.0)))

	_uv_padding_pixels = 0.0

	if _material != null:
		_apply_material_params()


func _ensure_viewport() -> void:
	if _viewport != null:
		return

	_viewport = SubViewport.new()
	_viewport.name = "BlockPreviewViewport"
	_viewport.disable_3d = false
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_viewport.size = Vector2i(preview_size_px, preview_size_px)
	add_child(_viewport)

	_root_3d = Node3D.new()
	_root_3d.name = "Root3D"
	_viewport.add_child(_root_3d)

	_light = DirectionalLight3D.new()
	_light.name = "DirectionalLight3D"
	_light.shadow_enabled = false
	_light.light_energy = light_energy
	_light.rotation_degrees = light_rotation_deg
	_root_3d.add_child(_light)

	_env = WorldEnvironment.new()
	_env.name = "WorldEnvironment"
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.0, 0.0, 0.0, 0.0)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = ambient_color
	e.ambient_light_energy = ambient_energy
	_env.environment = e
	_root_3d.add_child(_env)

	_mesh = MeshInstance3D.new()
	_mesh.name = "BlockMesh"
	_root_3d.add_child(_mesh)

	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = camera_ortho_size
	_camera.near = 0.01
	_camera.far = 50.0
	_camera.position = camera_position
	_root_3d.add_child(_camera)
	_camera.look_at(Vector3.ZERO, Vector3.UP)

	_material = ShaderMaterial.new()
	_material.shader = VoxelLitShader


func _apply_material_params() -> void:
	# 目的：关闭随机草色变化，保证 GUI 预览稳定一致；并复用世界同一张图集。
	_material.set_shader_parameter("atlas_texture", _atlas_texture)
	_material.set_shader_parameter("atlas_rows", _atlas_rows * 1.0)
	_material.set_shader_parameter("biome_variation_strength", 0.0)
	_material.set_shader_parameter("albedo_tint", Vector3(1.0, 1.0, 1.0))
	_material.set_shader_parameter("leaves_tint", Vector3(0.25, 0.70, 0.25))
	_material.set_shader_parameter("sky_brightness", 1.0)
	_material.set_shader_parameter("min_light", 1.0)
	_material.set_shader_parameter("light_curve", 1.0)


func _render_once(block_id: int, block: Resource) -> Texture2D:
	# 说明：单次渲染流程：
	# 1) 构建立方体网格（含 UV + 顶点色掩码/粗糙度/高光）
	# 2) 设置材质与相机/光照固定参数
	# 3) 让 SubViewport 更新一帧
	# 4) 抓取 Image，生成 ImageTexture 作为缓存
	_viewport.size = Vector2i(preview_size_px, preview_size_px)
	_apply_material_params()

	_mesh.mesh = _build_block_cube_mesh(block_id, block)
	_mesh.material_override = _material
	_mesh.rotation = Vector3(deg_to_rad(model_pitch_deg), deg_to_rad(model_yaw_deg), 0.0)

	_camera.size = camera_ortho_size
	_camera.position = camera_position
	_camera.look_at(Vector3.ZERO, Vector3.UP)

	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	# 说明：部分平台/驱动下，UPDATE_ONCE 的结果可能在下一帧末尾才可读；这里多等一帧保证抓图稳定。
	await get_tree().process_frame

	var vt: Texture2D = _viewport.get_texture()
	if vt == null:
		return null
	var img: Image = vt.get_image()
	if img == null:
		return null

	return ImageTexture.create_from_image(img)


func _build_block_cube_mesh(block_id: int, block: Resource) -> ArrayMesh:
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var uv2s: PackedVector2Array = PackedVector2Array()
	var colors: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()

	var p0: Vector3 = Vector3(-0.5, -0.5, -0.5)
	var p1: Vector3 = Vector3(0.5, -0.5, -0.5)
	var p2: Vector3 = Vector3(0.5, 0.5, -0.5)
	var p3: Vector3 = Vector3(-0.5, 0.5, -0.5)
	var p4: Vector3 = Vector3(-0.5, -0.5, 0.5)
	var p5: Vector3 = Vector3(0.5, -0.5, 0.5)
	var p6: Vector3 = Vector3(0.5, 0.5, 0.5)
	var p7: Vector3 = Vector3(-0.5, 0.5, 0.5)

	var base: int = 0
	base = _add_face(block_id, block, VoxelTypes.Face.POS_X, [p1, p5, p6, p2], Vector3.RIGHT, vertices, normals, uvs, uv2s, colors, indices, base)
	base = _add_face(block_id, block, VoxelTypes.Face.NEG_X, [p0, p3, p7, p4], Vector3.LEFT, vertices, normals, uvs, uv2s, colors, indices, base)
	base = _add_face(block_id, block, VoxelTypes.Face.POS_Y, [p3, p2, p6, p7], Vector3.UP, vertices, normals, uvs, uv2s, colors, indices, base)
	base = _add_face(block_id, block, VoxelTypes.Face.NEG_Y, [p0, p4, p5, p1], Vector3.DOWN, vertices, normals, uvs, uv2s, colors, indices, base)
	base = _add_face(block_id, block, VoxelTypes.Face.POS_Z, [p4, p7, p6, p5], Vector3.FORWARD, vertices, normals, uvs, uv2s, colors, indices, base)
	base = _add_face(block_id, block, VoxelTypes.Face.NEG_Z, [p0, p1, p2, p3], Vector3.BACK, vertices, normals, uvs, uv2s, colors, indices, base)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _add_face(
	_block_id: int,
	block: Resource,
	face: int,
	corners: Array,
	normal: Vector3,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	base: int
) -> int:
	var tile: Vector2i = Vector2i.ZERO
	if block != null and block.has_method("tile_for_face"):
		tile = block.call("tile_for_face", face)
	var r: Rect2 = _tile_uv_rect(tile)

	var tint_mode: int = 0
	var use_side_overlay: bool = false
	var alpha_cutoff: float = 0.0
	if block != null:
		tint_mode = str(block.get("tint_mode")).to_int()
		use_side_overlay = bool(block.get("use_side_overlay"))
		alpha_cutoff = str(block.get("alpha_cutoff")).to_float()

	var leaf_flag: float = 1.0 if tint_mode == 2 else 0.0
	var biome_id: float = 0.0
	var uv2_x: float = leaf_flag * 0.5 + (biome_id + 0.5) * (1.0 / 8.0)

	var grass_top_mask: float = 0.0
	if tint_mode == 1 and face == VoxelTypes.Face.POS_Y:
		grass_top_mask = 1.0
	elif tint_mode == 2:
		grass_top_mask = 1.0

	var grass_side_mask: float = 0.0
	if use_side_overlay and (face == VoxelTypes.Face.POS_X or face == VoxelTypes.Face.NEG_X or face == VoxelTypes.Face.POS_Z or face == VoxelTypes.Face.NEG_Z):
		grass_side_mask = 1.0

	for i in range(4):
		vertices.push_back(corners[i])
		normals.push_back(normal)
		var uv_local: Vector2 = _face_uv_local(face, corners[i])
		uvs.push_back(r.position + Vector2(r.size.x * uv_local.x, r.size.y * uv_local.y))
		uv2s.push_back(Vector2(uv2_x, alpha_cutoff))
		colors.push_back(Color(grass_top_mask, grass_side_mask, 1.0, 1.0))

	indices.push_back(base + 0)
	indices.push_back(base + 1)
	indices.push_back(base + 2)
	indices.push_back(base + 0)
	indices.push_back(base + 2)
	indices.push_back(base + 3)

	return base + 4


func _face_uv_local(face: int, corner: Vector3) -> Vector2:
	# 说明：保持侧面贴图“草皮朝上”的约定，与体素世界网格生成逻辑一致。
	# 约定：uv_local 的 (0,0) 为 tile 左上角，(1,1) 为 tile 右下角
	match face:
		VoxelTypes.Face.POS_X:
			return Vector2(1.0 - (corner.z + 0.5), 1.0 - (corner.y + 0.5))
		VoxelTypes.Face.NEG_X:
			return Vector2((corner.z + 0.5), 1.0 - (corner.y + 0.5))
		VoxelTypes.Face.POS_Z:
			return Vector2((corner.x + 0.5), 1.0 - (corner.y + 0.5))
		VoxelTypes.Face.NEG_Z:
			return Vector2(1.0 - (corner.x + 0.5), 1.0 - (corner.y + 0.5))
		VoxelTypes.Face.POS_Y:
			return Vector2((corner.x + 0.5), (corner.z + 0.5))
		VoxelTypes.Face.NEG_Y:
			return Vector2((corner.x + 0.5), 1.0 - (corner.z + 0.5))
		_:
			return Vector2.ZERO


func _tile_uv_rect(tile: Vector2i) -> Rect2:
	# 说明：把 tile 坐标（整格索引）转换为 atlas 的 UV Rect（0..1）。
	var cols: int = max(1, _atlas_columns)
	var rows: int = max(1, _atlas_rows)
	var tp: float = max(1.0, _tile_pixels * 1.0)
	var pad_px: float = clampf(_uv_padding_pixels, 0.0, tp * 0.49)

	var atlas_w: float = (cols * 1.0) * tp
	var atlas_h: float = (rows * 1.0) * tp

	var left: float = ((tile.x * 1.0) * tp + pad_px) / atlas_w
	var right: float = (((tile.x + 1) * 1.0) * tp - pad_px) / atlas_w
	var top: float = ((tile.y * 1.0) * tp + pad_px) / atlas_h
	var bottom: float = (((tile.y + 1) * 1.0) * tp - pad_px) / atlas_h

	return Rect2(Vector2(left, top), Vector2(right - left, bottom - top))
