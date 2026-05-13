extends CharacterBody3D

## ============================================================
## 下落实体 (FallingBlock) — 沙子柱整体物理下落
## ============================================================
## 职责：
##   1. 将连续沙柱整体打包为一个物理实体（CharacterBody3D）
##   2. 垂直下落（仅Y方向重力，无水平运动）
##   3. 落地后通过射线检测找到支撑面
##   4. 逐格回填体素方块到世界（从底到顶）
##   5. 自销毁（queue_free）
##
## 设计目标：解决多块沙子并发下落丢块问题。
## 每块沙子独立下落 → 多实体重叠争抢位置 → 丢块。
## 解决：整柱打包 → 单一实体 → 落地一次性逐格回填 → 数量不变。
##
## 网格：按高度重复侧面纹理（_build_block_column_mesh），
## 顶面和底面各一个面，侧面按每格高度循环生成。
## ============================================================

const BlockRegistryScript := preload("res://src/voxel/block_registry.gd")

@export var block_id: int = 0
@export var voxel_scale: float = 1.0
@export var height_blocks: int = 1
@export var gravity: float = 22.0
@export var terminal_speed: float = 32.0

@onready var _mesh: MeshInstance3D = $BlockMesh
@onready var _collision_shape: CollisionShape3D = $CollisionShape3D

var _material: ShaderMaterial

func _ready() -> void:
	collision_layer = 2
	collision_mask = 3
	set_meta("is_falling_block", true)
	_apply_visuals()
	_apply_collision()

func _physics_process(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	velocity.y = max(-terminal_speed, velocity.y - gravity * max(0.0, delta))
	move_and_slide()
	if is_on_floor():
		_try_settle()

func _apply_collision() -> void:
	if _collision_shape == null:
		return
	var h: int = max(1, height_blocks)
	var s: BoxShape3D = BoxShape3D.new()
	s.size = Vector3(1.0, h * 1.0, 1.0) * max(0.01, voxel_scale) * 0.98
	_collision_shape.shape = s

func _apply_visuals() -> void:
	if _mesh == null:
		return
	var h: int = max(1, height_blocks)
	_mesh.mesh = _build_block_column_mesh(block_id, BlockRegistryScript.get_block(block_id), h)
	_mesh.material_override = _build_material_from_world()
	_mesh.scale = Vector3.ONE * max(0.01, voxel_scale)

func _find_voxel_world() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.find_child("VoxelWorld", true, false)

func _build_material_from_world() -> ShaderMaterial:
	if _material != null:
		return _material
	_material = ShaderMaterial.new()
	_material.shader = preload("res://shaders/voxel_lit.gdshader")
	var world: Node = _find_voxel_world()
	if world != null:
		var atlas: Texture2D = world.get("atlas_texture")
		var rows: float = str(world.get("atlas_rows")).to_float()
		if atlas != null:
			_material.set_shader_parameter("atlas_texture", atlas)
		if rows > 0.0:
			_material.set_shader_parameter("atlas_rows", rows)
		var sky_brightness: float = str(world.get("_sky_brightness_current")).to_float()
		if sky_brightness >= 0.0:
			_material.set_shader_parameter("sky_brightness", sky_brightness)
	return _material

## 落地处理 — 射线找支撑面 → 检查目标区域是否为空 → 逐格回填体素方块
## 核心：整柱下落→落地→一次性逐格回填，保证数量不变（不丢块）
func _try_settle() -> void:
	var world: Node = _find_voxel_world()
	if world == null:
		queue_free()
		return
	var s: float = max(0.0001, voxel_scale)
	var h: int = max(1, height_blocks)
	var half_h: float = (h * 0.5) * s  # 半柱高（世界单位）

	# 向下射线检测：从实体中心点向下探测，找支撑面Y
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from_pos: Vector3 = global_position
	var to_pos: Vector3 = global_position + Vector3.DOWN * (half_h + s * 2.0)  # 探测距离=半柱高+2格余量

	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()
	q.from = from_pos
	q.to = to_pos
	q.collision_mask = 3  # 地形(1) | 实体(2) = 3
	q.exclude = [self]    # 排除自己

	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():  # 下方无碰撞体 → 掉出世界
		queue_free()
		return
	var collider: Object = hit.get("collider", null)
	# 不要在另一个下落实体上停住（防堆积穿透）
	if collider != null and collider.has_meta("is_falling_block") and bool(collider.get_meta("is_falling_block")):
		return

	# 计算支撑面Y坐标 → 底部体素的Y坐标
	var hit_pos: Vector3 = hit.get("position", global_position)
	var eps: float = s * 0.001
	var support_y: int = floori((hit_pos.y - eps) / s)  # 支撑面所在的体素Y
	var vx: int = floori(global_position.x / s)        # 柱的体素X
	var vz: int = floori(global_position.z / s)        # 柱的体素Z
	var bottom_y: int = support_y + 1                   # 沙柱底格应该放的Y
	var target: Vector3i = Vector3i(vx, bottom_y, vz)

	# 验证目标区域全为空（防止重叠放置）
	if world.has_method("get_voxel_global"):
		var tries: int = 0
		while tries < 8:  # 最多向上尝试8格
			var ok: bool = true
			var yi: int = 0
			while yi < h:
				var v0: int = int(world.call("get_voxel_global", target + Vector3i(0, yi, 0)))
				if v0 != 0:  # 非空气 → 该位置被占用
					ok = false
					break
				yi += 1
			if ok:
				break
			target.y += 1  # 上移一格再试
			tries += 1
		if tries >= 8:  # 8次都失败 → 放弃
			queue_free()
			return

	# 逐格回填方块（从底到顶）
	if world.has_method("set_voxel_global"):
		var yi2: int = 0
		while yi2 < h:
			world.call("set_voxel_global", target + Vector3i(0, yi2, 0), block_id)
			yi2 += 1

	queue_free()  # 落地完成 → 清理实体

func _build_block_column_mesh(_block_id: int, block: Resource, height: int) -> ArrayMesh:
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var uv2s: PackedVector2Array = PackedVector2Array()
	var colors: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()

	var h: int = max(1, height)
	var y_min: float = -0.5 * (h * 1.0)
	var base: int = 0
	var i: int = 0
	while i < h:
		var y0: float = y_min + (i * 1.0)
		var y1: float = y0 + 1.0
		base = _add_face(block, VoxelTypes.Face.POS_X, [Vector3(0.5, y0, -0.5), Vector3(0.5, y0, 0.5), Vector3(0.5, y1, 0.5), Vector3(0.5, y1, -0.5)], Vector3.RIGHT, vertices, normals, uvs, uv2s, colors, indices, base, y0)
		base = _add_face(block, VoxelTypes.Face.NEG_X, [Vector3(-0.5, y0, -0.5), Vector3(-0.5, y1, -0.5), Vector3(-0.5, y1, 0.5), Vector3(-0.5, y0, 0.5)], Vector3.LEFT, vertices, normals, uvs, uv2s, colors, indices, base, y0)
		base = _add_face(block, VoxelTypes.Face.POS_Z, [Vector3(-0.5, y0, 0.5), Vector3(-0.5, y1, 0.5), Vector3(0.5, y1, 0.5), Vector3(0.5, y0, 0.5)], Vector3.FORWARD, vertices, normals, uvs, uv2s, colors, indices, base, y0)
		base = _add_face(block, VoxelTypes.Face.NEG_Z, [Vector3(-0.5, y0, -0.5), Vector3(0.5, y0, -0.5), Vector3(0.5, y1, -0.5), Vector3(-0.5, y1, -0.5)], Vector3.BACK, vertices, normals, uvs, uv2s, colors, indices, base, y0)
		i += 1
	var y_top: float = y_min + (h * 1.0)
	base = _add_face(block, VoxelTypes.Face.POS_Y, [Vector3(-0.5, y_top, -0.5), Vector3(0.5, y_top, -0.5), Vector3(0.5, y_top, 0.5), Vector3(-0.5, y_top, 0.5)], Vector3.UP, vertices, normals, uvs, uv2s, colors, indices, base, y_top)
	base = _add_face(block, VoxelTypes.Face.NEG_Y, [Vector3(-0.5, y_min, -0.5), Vector3(-0.5, y_min, 0.5), Vector3(0.5, y_min, 0.5), Vector3(0.5, y_min, -0.5)], Vector3.DOWN, vertices, normals, uvs, uv2s, colors, indices, base, y_min)

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
	base: int,
	segment_y0: float = -0.5
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
		var uv_local: Vector2 = _uv_local_for_face(face, corners[i], segment_y0)
		uvs.push_back(r.position + Vector2(r.size.x * uv_local.x, r.size.y * uv_local.y))
		uv2s.push_back(Vector2(uv2_x, alpha_cutoff))
		colors.push_back(Color(grass_top_mask, grass_side_mask, 1.0, 0.0))

	indices.push_back(base + 0)
	indices.push_back(base + 1)
	indices.push_back(base + 2)
	indices.push_back(base + 0)
	indices.push_back(base + 2)
	indices.push_back(base + 3)
	return base + 4

func _uv_local_for_face(face: int, corner: Vector3, segment_y0: float) -> Vector2:
	var y_local: float = corner.y - segment_y0
	match face:
		VoxelTypes.Face.POS_X:
			return Vector2(1.0 - (corner.z + 0.5), 1.0 - y_local)
		VoxelTypes.Face.NEG_X:
			return Vector2((corner.z + 0.5), 1.0 - y_local)
		VoxelTypes.Face.POS_Z:
			return Vector2((corner.x + 0.5), 1.0 - y_local)
		VoxelTypes.Face.NEG_Z:
			return Vector2(1.0 - (corner.x + 0.5), 1.0 - y_local)
		VoxelTypes.Face.POS_Y:
			return Vector2((corner.x + 0.5), (corner.z + 0.5))
		VoxelTypes.Face.NEG_Y:
			return Vector2((corner.x + 0.5), 1.0 - (corner.z + 0.5))
		_:
			return Vector2.ZERO

func _tile_uv_rect(tile: Vector2i) -> Rect2:
	var world: Node = _find_voxel_world()
	var cols: int = 1
	var rows: int = 2
	var tile_px: float = 16.0
	if world != null:
		cols = max(1, str(world.get("atlas_columns")).to_int())
		rows = max(1, str(world.get("atlas_rows")).to_int())
		tile_px = max(1.0, str(world.get("_tile_pixels")).to_float())
	var atlas_w: float = (cols * 1.0) * tile_px
	var atlas_h: float = (rows * 1.0) * tile_px
	var left: float = ((tile.x * 1.0) * tile_px) / atlas_w
	var right: float = (((tile.x + 1) * 1.0) * tile_px) / atlas_w
	var top: float = ((tile.y * 1.0) * tile_px) / atlas_h
	var bottom: float = (((tile.y + 1) * 1.0) * tile_px) / atlas_h
	return Rect2(Vector2(left, top), Vector2(right - left, bottom - top))
