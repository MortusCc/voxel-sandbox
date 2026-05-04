extends CharacterBody3D

const BlockRegistryScript := preload("res://src/voxel/block_registry.gd")

## 掉落物对应的方块/物品 ID
@export var item_id: int = 0
## 掉落物数量
@export var count: int = 1

@onready var _mesh: MeshInstance3D = $BlockMesh

## 重力加速度
@export var gravity: float = 18.0
## 落地后的水平摩擦（越大越快停下来）
@export var ground_friction: float = 10.0

## 吸附时的加速度（越大越“嗖”）
@export var attract_accel: float = 35.0
## 吸附时的目标速度上限
@export var attract_speed: float = 12.0
## 距离玩家多近时触发拾取
@export var pickup_distance: float = 0.6
## 吸附目标高度（相对玩家位置的 Y 偏移）
@export var attract_target_height: float = 0.45
## 免吸附时间（用于 Q 丢弃后不立刻吸回）
@export var attract_delay: float = 0.0

## 落地悬浮的基础高度
@export var hover_height: float = 0.22
## 悬浮抖动幅度
@export var hover_amplitude: float = 0.05
## 悬浮抖动速度
@export var hover_speed: float = 4.0
## 旋转速度（度/秒）
@export var spin_speed_deg: float = 90.0
## 掉落物显示缩放（1.0 为完整方块）
@export var item_scale: float = 0.45

var _time: float = 0.0
var _target: Node
var _base_mesh_y: float = 0.0
var _attract_delay_left: float = 0.0
var _material: ShaderMaterial


func _ready() -> void:
	# 说明：
	# - 掉落物有重力，会落到地面。
	# - 渲染为“缩小的立方体”，与快捷栏 3D 预览一致的贴图/UV 规则。
	# - 落地后做轻微上下悬浮抖动，并持续旋转（接近 MC 方块掉落表现）。
	# - 玩家进入吸附范围后，掉落物会从原地飞向玩家，接近后触发拾取。
	_refresh_visual()
	if _mesh != null:
		_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_base_mesh_y = _mesh.position.y if _mesh != null else 0.0
	_attract_delay_left = max(0.0, attract_delay)
	velocity = Vector3(randf() - 0.5, 1.8, randf() - 0.5) * 1.2


func _physics_process(delta: float) -> void:
	_time += delta
	if _attract_delay_left > 0.0:
		_attract_delay_left = max(0.0, _attract_delay_left - delta)

	if _target != null and is_instance_valid(_target) and _attract_delay_left <= 0.0:
		var target_pos: Vector3 = (_target as Node3D).global_position + Vector3.UP * attract_target_height if _target is Node3D else global_position
		var to_target: Vector3 = target_pos - global_position
		var d: float = to_target.length()
		if d <= pickup_distance:
			_try_pickup(_target)
			return

		var dir: Vector3 = to_target / max(0.0001, d)
		var desired_vel: Vector3 = dir * min(attract_speed, d * 10.0)
		velocity = velocity.move_toward(desired_vel, attract_accel * delta)
		move_and_slide()
	else:
		velocity.y -= gravity * delta
		if is_on_floor():
			velocity.y = 0.0
			velocity.x = move_toward(velocity.x, 0.0, ground_friction * delta)
			velocity.z = move_toward(velocity.z, 0.0, ground_friction * delta)
		move_and_slide()

	if _mesh != null:
		_mesh.rotation.y += deg_to_rad(spin_speed_deg) * delta
		var hovering: bool = is_on_floor() and (_target == null or not is_instance_valid(_target))
		var y: float = _base_mesh_y
		if hovering:
			y += hover_height + hover_amplitude * sin(_time * hover_speed)
		_mesh.position.y = y


func _refresh_visual() -> void:
	if _mesh == null:
		return
	var block: Resource = BlockRegistryScript.get_block(item_id)
	if block == null:
		return

	_mesh.scale = Vector3.ONE * item_scale
	_mesh.mesh = _build_block_cube_mesh(item_id, block)
	_mesh.material_override = _build_material_from_world()

func set_attract_delay(seconds: float) -> void:
	_attract_delay_left = max(0.0, seconds)


func start_attract(target: Node) -> void:
	# 由玩家的“吸附范围”触发，掉落物开始飞向玩家。
	if target == null:
		return
	if not target.has_method("pickup_item"):
		return
	_target = target


func _try_pickup(body: Node) -> void:
	# 规则：拾取逻辑归玩家管理（是否满背包、剩余多少），掉落物只负责“飞向玩家并请求拾取”。
	if body == null or not is_instance_valid(body):
		_target = null
		return
	if not body.has_method("pickup_item"):
		_target = null
		return
	var remain: int = body.call("pickup_item", item_id, count)
	if remain <= 0:
		queue_free()
		return
	count = remain
	_target = null


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

	# 掉落物属于“世界表现”，保留群系变化（与地形一致）
	_material.set_shader_parameter("biome_variation_strength", 0.15)
	_material.set_shader_parameter("leaves_tint", Vector3(0.25, 0.70, 0.25))
	return _material


func _find_voxel_world() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	var w: Node = scene.find_child("VoxelWorld", true, false)
	return w


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
		colors.push_back(Color(grass_top_mask, grass_side_mask, 1.0, 0.0))

	indices.push_back(base + 0)
	indices.push_back(base + 1)
	indices.push_back(base + 2)
	indices.push_back(base + 0)
	indices.push_back(base + 2)
	indices.push_back(base + 3)

	return base + 4


func _face_uv_local(face: int, corner: Vector3) -> Vector2:
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
