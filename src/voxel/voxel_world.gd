extends Node3D
class_name VoxelWorld

@export var chunk_size: int = 16
@export var atlas_columns: int = 4
@export var atlas_rows: int = 4
@export var voxel_scale: float = 1.0
@export var atlas_texture: Texture2D
@export var max_interact_distance: float = 6.0

var _chunks: Dictionary = {}
var _material: ShaderMaterial

func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = preload("res://shaders/voxel_lit.gdshader")
	if atlas_texture != null:
		_material.set_shader_parameter("atlas_texture", atlas_texture)

	_create_chunk(Vector3i.ZERO, true)

func _create_chunk(chunk_coord: Vector3i, fill_terrain: bool) -> VoxelChunk:
	var chunk: VoxelChunk = VoxelChunk.new()
	chunk.chunk_size = chunk_size
	chunk.atlas_columns = atlas_columns
	chunk.atlas_rows = atlas_rows
	chunk.voxel_scale = voxel_scale
	chunk.setup(chunk_coord)
	chunk.material_override = _material

	if fill_terrain:
		chunk.fill_test_terrain()

	add_child(chunk)
	_chunks[chunk_coord] = chunk

	chunk.rebuild_mesh(_sample_voxel_global)
	return chunk

func _sample_voxel_global(global_voxel: Vector3i) -> int:
	var chunk_coord: Vector3i = _voxel_to_chunk_coord(global_voxel)
	var chunk: VoxelChunk = _chunks.get(chunk_coord, null)
	if chunk == null:
		return VoxelTypes.VoxelType.AIR

	var local: Vector3i = global_voxel - chunk_coord * chunk_size
	return chunk.get_voxel_local(local.x, local.y, local.z)

func set_voxel_global(global_voxel: Vector3i, voxel_type: int) -> void:
	var chunk_coord: Vector3i = _voxel_to_chunk_coord(global_voxel)
	var chunk: VoxelChunk = _chunks.get(chunk_coord, null)
	if chunk == null:
		chunk = _create_chunk(chunk_coord, false)

	var local: Vector3i = global_voxel - chunk_coord * chunk_size
	chunk.set_voxel_local(local.x, local.y, local.z, voxel_type)

	_rebuild_chunk_and_neighbors(chunk_coord, local)

func _rebuild_chunk_and_neighbors(chunk_coord: Vector3i, local: Vector3i) -> void:
	var chunk: VoxelChunk = _chunks.get(chunk_coord, null)
	if chunk != null:
		chunk.rebuild_mesh(_sample_voxel_global)

	# 如果修改发生在边界，邻居 Chunk 的可见面也会变化，需要重建
	if local.x == 0:
		_rebuild_chunk(chunk_coord + Vector3i(-1, 0, 0))
	elif local.x == chunk_size - 1:
		_rebuild_chunk(chunk_coord + Vector3i(1, 0, 0))

	if local.y == 0:
		_rebuild_chunk(chunk_coord + Vector3i(0, -1, 0))
	elif local.y == chunk_size - 1:
		_rebuild_chunk(chunk_coord + Vector3i(0, 1, 0))

	if local.z == 0:
		_rebuild_chunk(chunk_coord + Vector3i(0, 0, -1))
	elif local.z == chunk_size - 1:
		_rebuild_chunk(chunk_coord + Vector3i(0, 0, 1))

func _rebuild_chunk(chunk_coord: Vector3i) -> void:
	var chunk: VoxelChunk = _chunks.get(chunk_coord, null)
	if chunk == null:
		return
	chunk.rebuild_mesh(_sample_voxel_global)

func _voxel_to_chunk_coord(global_voxel: Vector3i) -> Vector3i:
	return Vector3i(
		_floor_div(global_voxel.x, chunk_size),
		_floor_div(global_voxel.y, chunk_size),
		_floor_div(global_voxel.z, chunk_size)
	)

func _floor_div(a: int, b: int) -> int:
	# floori(float) 可正确处理负数下取整
	return floori(float(a) / float(b))

func raycast_voxel(origin: Vector3, direction: Vector3, max_distance: float) -> Dictionary:
	# --- INDEPENDENT DESIGN START ---
	# 体素拾取：3D DDA（Digital Differential Analyzer）栅格遍历
	# 思路：
	# - 将射线看作在 3D 单元格网格中前进
	# - 每一步跨过 x/y/z 的一个体素边界，进入下一个体素
	# - 第一个命中的“实体体素”即为拾取目标
	var dir: Vector3 = direction.normalized()
	if dir.length() <= 0.00001:
		return {"hit": false}

	var pos: Vector3 = origin / voxel_scale
	var voxel: Vector3i = Vector3i(floori(pos.x), floori(pos.y), floori(pos.z))

	var step_x: int = _sign_int_from_float(dir.x)
	var step_y: int = _sign_int_from_float(dir.y)
	var step_z: int = _sign_int_from_float(dir.z)

	var t_delta_x: float = INF
	var t_delta_y: float = INF
	var t_delta_z: float = INF

	if absf(dir.x) > 0.000001:
		t_delta_x = absf(1.0 / dir.x)
	if absf(dir.y) > 0.000001:
		t_delta_y = absf(1.0 / dir.y)
	if absf(dir.z) > 0.000001:
		t_delta_z = absf(1.0 / dir.z)

	var next_x: float = float(voxel.x + (1 if step_x > 0 else 0))
	var next_y: float = float(voxel.y + (1 if step_y > 0 else 0))
	var next_z: float = float(voxel.z + (1 if step_z > 0 else 0))

	var t_max_x: float = INF
	var t_max_y: float = INF
	var t_max_z: float = INF

	if absf(dir.x) > 0.000001:
		t_max_x = (next_x - pos.x) / dir.x
	if absf(dir.y) > 0.000001:
		t_max_y = (next_y - pos.y) / dir.y
	if absf(dir.z) > 0.000001:
		t_max_z = (next_z - pos.z) / dir.z

	var last_empty: Vector3i = voxel
	var hit_normal: Vector3i = Vector3i.ZERO

	var max_t: float = max_distance / voxel_scale
	var max_steps: int = max(1, ceili(max_t * 3.0))

	for _i in range(max_steps):
		var vt: int = _sample_voxel_global(voxel)
		if VoxelTypes.is_solid(vt):
			return {
				"hit": true,
				"voxel": voxel,
				"previous": last_empty,
				"normal": hit_normal,
				"type": vt,
			}

		last_empty = voxel

		if t_max_x < t_max_y and t_max_x < t_max_z:
			if t_max_x > max_t:
				break
			voxel.x += step_x
			hit_normal = Vector3i(-step_x, 0, 0)
			t_max_x += t_delta_x
		elif t_max_y < t_max_z:
			if t_max_y > max_t:
				break
			voxel.y += step_y
			hit_normal = Vector3i(0, -step_y, 0)
			t_max_y += t_delta_y
		else:
			if t_max_z > max_t:
				break
			voxel.z += step_z
			hit_normal = Vector3i(0, 0, -step_z)
			t_max_z += t_delta_z

	return {"hit": false}
	# --- INDEPENDENT DESIGN END ---

func _sign_int_from_float(v: float) -> int:
	if v > 0.0:
		return 1
	if v < 0.0:
		return -1
	return 0

func break_voxel_at_ray(origin: Vector3, direction: Vector3) -> bool:
	var result: Dictionary = raycast_voxel(origin, direction, max_interact_distance)
	if not result.get("hit", false):
		return false
	set_voxel_global(result["voxel"], VoxelTypes.VoxelType.AIR)
	return true

func place_voxel_at_ray(origin: Vector3, direction: Vector3, voxel_type: int) -> bool:
	var result: Dictionary = raycast_voxel(origin, direction, max_interact_distance)
	if not result.get("hit", false):
		return false
	var target: Vector3i = result["previous"]
	set_voxel_global(target, voxel_type)
	return true
