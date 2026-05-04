extends MeshInstance3D
class_name VoxelChunk

const BlockRegistryScript := preload("res://src/voxel/block_registry.gd")

@export var chunk_size: int = 16
@export var atlas_columns: int = 4
@export var atlas_rows: int = 2
@export var tile_pixels: int = 16
@export var uv_padding_pixels: float = 0.0
@export var voxel_scale: float = 1.0
@export var collision_enabled: bool = true
## 群系随机种子（用于草色/叶色与树生成的一致性）
@export var biome_seed: int = 1337
## 群系分布尺度（越大群系边界越碎，越小群系块越大）
@export_range(0.0001, 0.2, 0.0001) var biome_map_scale: float = 0.02

const FACE_CORNERS: Array = [
	# 每个面的 4 个角点（单位立方体局部坐标）。三角形绕序由后续索引生成逻辑决定。
	[Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)], # POS_X (+X)
	[Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(0, 0, 1)], # NEG_X (-X)
	[Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)], # POS_Y (+Y)
	[Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 0)], # NEG_Y (-Y)
	[Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 0, 1)], # POS_Z (+Z)
	[Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)], # NEG_Z (-Z)
]

var chunk_coord: Vector3i = Vector3i.ZERO

var _voxels: PackedByteArray = PackedByteArray()
var _static_body: StaticBody3D
var _collision_shape: CollisionShape3D

func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_ensure_voxel_buffer()
	_ensure_collision_nodes()

func setup(new_chunk_coord: Vector3i) -> void:
	chunk_coord = new_chunk_coord
	position = Vector3(chunk_coord) * (chunk_size * 1.0) * voxel_scale
	_ensure_voxel_buffer()

func _ensure_voxel_buffer() -> void:
	# VoxelWorld 可能会在节点进入场景树（_ready）之前调用 fill_test_terrain()。
	# 因此，Chunk 必须在任何体素读写之前确保 _voxels 已正确分配长度，避免 PackedByteArray 越界。
	if _voxels.size() != chunk_size * chunk_size * chunk_size:
		_initialize_voxels()

func _initialize_voxels() -> void:
	_voxels.resize(chunk_size * chunk_size * chunk_size)
	_voxels.fill(0)

func _to_index(x: int, y: int, z: int) -> int:
	return x + y * chunk_size + z * chunk_size * chunk_size

func is_in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and x < chunk_size and y >= 0 and y < chunk_size and z >= 0 and z < chunk_size

func get_voxel_local(x: int, y: int, z: int) -> int:
	_ensure_voxel_buffer()
	if not is_in_bounds(x, y, z):
		return VoxelTypes.VoxelType.AIR
	return _voxels[_to_index(x, y, z)]

func set_voxel_local(x: int, y: int, z: int, voxel_type: int) -> void:
	_ensure_voxel_buffer()
	if not is_in_bounds(x, y, z):
		return
	_voxels[_to_index(x, y, z)] = voxel_type

func fill_test_terrain() -> void:
	# 生成一个简单的测试地形：下半部分为泥土/石头，上面一层草
	_ensure_voxel_buffer()
	var half: int = chunk_size >> 1
	for z in range(chunk_size):
		for x in range(chunk_size):
			for y in range(chunk_size):
				if y < half - 2:
					set_voxel_local(x, y, z, VoxelTypes.VoxelType.STONE)
				elif y < half - 1:
					set_voxel_local(x, y, z, VoxelTypes.VoxelType.DIRT)
				elif y < half:
					set_voxel_local(x, y, z, VoxelTypes.VoxelType.GRASS)
				else:
					set_voxel_local(x, y, z, VoxelTypes.VoxelType.AIR)

func rebuild_mesh(sample_neighbor: Callable, sample_skylight: Callable) -> void:
	# sample_neighbor: (global_voxel_pos: Vector3i) -> int，用于跨 Chunk 查询相邻体素
	_ensure_voxel_buffer()
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var uv2s: PackedVector2Array = PackedVector2Array()
	var colors: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()

	var base_vertex_index: int = 0
	var s: float = voxel_scale

	# --- INDEPENDENT DESIGN START ---
	# 程序化网格生成 + 面剔除：
	# 对每个非空气体素，检查 6 个相邻格子。
	# - 如果相邻为空气（或越界外部空气），说明该面暴露，需要生成该面 2 个三角形。
	# - 如果相邻是实体体素，说明该面被遮挡，不生成。
	#
	# 这里“剔除”的核心不是 GPU 的背面剔除，而是“根本不生成内部面”，减少顶点数与三角形数。
	for z in range(chunk_size):
		for y in range(chunk_size):
			for x in range(chunk_size):
				var voxel_type: int = get_voxel_local(x, y, z)
				if not BlockRegistryScript.is_solid(voxel_type):
					continue

				var global_voxel: Vector3i = chunk_coord * chunk_size + Vector3i(x, y, z)

				var cx: Array = FACE_CORNERS[VoxelTypes.Face.POS_X]
				base_vertex_index = _try_add_face(
					VoxelTypes.Face.POS_X,
					voxel_type,
					global_voxel,
					Vector3i(1, 0, 0),
					cx[0],
					cx[1],
					cx[2],
					cx[3],
					s,
					sample_neighbor,
					sample_skylight,
					vertices,
					normals,
					uvs,
					uv2s,
					colors,
					indices,
					base_vertex_index
				)
				var cnx: Array = FACE_CORNERS[VoxelTypes.Face.NEG_X]
				base_vertex_index = _try_add_face(
					VoxelTypes.Face.NEG_X,
					voxel_type,
					global_voxel,
					Vector3i(-1, 0, 0),
					cnx[0],
					cnx[1],
					cnx[2],
					cnx[3],
					s,
					sample_neighbor,
					sample_skylight,
					vertices,
					normals,
					uvs,
					uv2s,
					colors,
					indices,
					base_vertex_index
				)
				var cy: Array = FACE_CORNERS[VoxelTypes.Face.POS_Y]
				base_vertex_index = _try_add_face(
					VoxelTypes.Face.POS_Y,
					voxel_type,
					global_voxel,
					Vector3i(0, 1, 0),
					cy[0],
					cy[1],
					cy[2],
					cy[3],
					s,
					sample_neighbor,
					sample_skylight,
					vertices,
					normals,
					uvs,
					uv2s,
					colors,
					indices,
					base_vertex_index
				)
				var cny: Array = FACE_CORNERS[VoxelTypes.Face.NEG_Y]
				base_vertex_index = _try_add_face(
					VoxelTypes.Face.NEG_Y,
					voxel_type,
					global_voxel,
					Vector3i(0, -1, 0),
					cny[0],
					cny[1],
					cny[2],
					cny[3],
					s,
					sample_neighbor,
					sample_skylight,
					vertices,
					normals,
					uvs,
					uv2s,
					colors,
					indices,
					base_vertex_index
				)
				var cz: Array = FACE_CORNERS[VoxelTypes.Face.POS_Z]
				base_vertex_index = _try_add_face(
					VoxelTypes.Face.POS_Z,
					voxel_type,
					global_voxel,
					Vector3i(0, 0, 1),
					cz[0],
					cz[1],
					cz[2],
					cz[3],
					s,
					sample_neighbor,
					sample_skylight,
					vertices,
					normals,
					uvs,
					uv2s,
					colors,
					indices,
					base_vertex_index
				)
				var cnz: Array = FACE_CORNERS[VoxelTypes.Face.NEG_Z]
				base_vertex_index = _try_add_face(
					VoxelTypes.Face.NEG_Z,
					voxel_type,
					global_voxel,
					Vector3i(0, 0, -1),
					cnz[0],
					cnz[1],
					cnz[2],
					cnz[3],
					s,
					sample_neighbor,
					sample_skylight,
					vertices,
					normals,
					uvs,
					uv2s,
					colors,
					indices,
					base_vertex_index
				)
	# --- INDEPENDENT DESIGN END ---

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh: ArrayMesh = ArrayMesh.new()
	if vertices.size() > 0:
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = arr_mesh
	_update_collision_from_mesh()

func _try_add_face(
	face: int,
	voxel_type: int,
	global_voxel: Vector3i,
	neighbor_offset: Vector3i,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	s: float,
	sample_neighbor: Callable,
	sample_skylight: Callable,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	base_vertex_index: int
) -> int:
	var neighbor_global: Vector3i = global_voxel + neighbor_offset
	var neighbor_type: int = sample_neighbor.call(neighbor_global)
	if BlockRegistryScript.occludes_faces(neighbor_type):
		return base_vertex_index

	var light_level: int = 15
	if not sample_skylight.is_null():
		light_level = int(sample_skylight.call(neighbor_global))
	var sky_light01: float = clampf(light_level * (1.0 / 15.0), 0.0, 1.0)
	var block_light01: float = 0.0

	var local_origin: Vector3 = Vector3(global_voxel - chunk_coord * chunk_size) * s
	var face_normal: Vector3 = _face_normal(face)

	# --- INDEPENDENT DESIGN START ---
	# UV 分配算法：
	# 1) 根据 voxel_type 与 face，查到其在图集中的 tile 坐标（整格索引）
	# 2) 再把 tile 坐标转换为 [0,1] 的 UV 区间
	# 3) 为该面 4 个顶点填充对应 UV
	var block: Resource = BlockRegistryScript.get_block(voxel_type)
	var tile: Vector2i = Vector2i.ZERO
	if block != null:
		tile = block.call("tile_for_face", face)
	var tile_uv_rect: Rect2 = _tile_uv_rect(tile)
	# --- INDEPENDENT DESIGN END ---

	var start: int = base_vertex_index

	var corners: Array[Vector3] = [v0, v1, v2, v3]
	var positions: Array[Vector3] = []
	var face_uvs: Array[Vector2] = []
	positions.resize(4)
	face_uvs.resize(4)

	for i in range(4):
		positions[i] = local_origin + corners[i] * s
		var uv_local: Vector2 = _face_uv_local(face, corners[i])
		face_uvs[i] = tile_uv_rect.position + Vector2(tile_uv_rect.size.x * uv_local.x, tile_uv_rect.size.y * uv_local.y)

	vertices.push_back(positions[0])
	vertices.push_back(positions[1])
	vertices.push_back(positions[2])
	vertices.push_back(positions[3])

	for i in range(4):
		normals.push_back(face_normal)

	for i in range(4):
		uvs.push_back(face_uvs[i])

	var tint_mode: int = 0
	var use_side_overlay: bool = false
	var alpha_cutoff: float = 0.0
	if block != null:
		tint_mode = str(block.get("tint_mode")).to_int()
		use_side_overlay = bool(block.get("use_side_overlay"))
		alpha_cutoff = str(block.get("alpha_cutoff")).to_float()

	var leaf_flag: float = 1.0 if tint_mode == 2 else 0.0
	# 说明：把“是否树叶(0/1)”与“群系ID(0/1/2)”打包到 UV2.x，确保同一个方块 6 个面颜色一致。
	# 解码规则在 voxel_lit.gdshader 中：
	# - leaf_mask = step(0.5, UV2.x)
	# - biome_id = floor((UV2.x - leaf_mask*0.5) * 8.0)
	var biome_id: int = _biome_id_at(global_voxel.x, global_voxel.z)
	var uv2_x: float = leaf_flag * 0.5 + (float(biome_id) + 0.5) * (1.0 / 8.0)
	for i in range(4):
		uv2s.push_back(Vector2(uv2_x, alpha_cutoff))

	var grass_top_mask: float = 0.0
	if tint_mode == 1 and face == VoxelTypes.Face.POS_Y:
		grass_top_mask = 1.0
	elif tint_mode == 2:
		grass_top_mask = 1.0

	var grass_side_mask: float = 0.0
	if use_side_overlay and (face == VoxelTypes.Face.POS_X or face == VoxelTypes.Face.NEG_X or face == VoxelTypes.Face.POS_Z or face == VoxelTypes.Face.NEG_Z):
		grass_side_mask = 1.0
	for i in range(4):
		colors.push_back(Color(grass_top_mask, grass_side_mask, sky_light01, block_light01))

	indices.push_back(start + 0)
	indices.push_back(start + 1)
	indices.push_back(start + 2)
	indices.push_back(start + 0)
	indices.push_back(start + 2)
	indices.push_back(start + 3)

	return base_vertex_index + 4


func _fract(v: float) -> float:
	return v - floor(v)


func _hash12(p: Vector2) -> float:
	return _fract(sin(p.dot(Vector2(127.1, 311.7))) * 43758.5453)


func _noise2(p: Vector2) -> float:
	var i: Vector2 = Vector2(floor(p.x), floor(p.y))
	var f: Vector2 = Vector2(p.x - i.x, p.y - i.y)
	var a: float = _hash12(i)
	var b: float = _hash12(i + Vector2(1.0, 0.0))
	var c: float = _hash12(i + Vector2(0.0, 1.0))
	var d: float = _hash12(i + Vector2(1.0, 1.0))
	var u: Vector2 = f * f * (Vector2.ONE * 3.0 - 2.0 * f)
	return lerpf(lerpf(a, b, u.x), lerpf(c, d, u.x), u.y)


func _biome_id_at(gx: int, gz: int) -> int:
	# 说明：用连续噪声生成群系，得到 0/1/2（平原/森林/干旱）。
	# 这里以“世界坐标（米）”采样，确保 voxel_scale 改变时群系视觉尺度仍然符合预期。
	var wx: float = gx * voxel_scale
	var wz: float = gz * voxel_scale
	var n: float = _noise2(Vector2(wx, wz) * biome_map_scale + Vector2(float(biome_seed) * 0.13, float(biome_seed) * -0.37))
	return floori(clampf(n, 0.0, 0.999) * 3.0)

func _face_normal(face: int) -> Vector3:
	match face:
		VoxelTypes.Face.POS_X:
			return Vector3(1, 0, 0)
		VoxelTypes.Face.NEG_X:
			return Vector3(-1, 0, 0)
		VoxelTypes.Face.POS_Y:
			return Vector3(0, 1, 0)
		VoxelTypes.Face.NEG_Y:
			return Vector3(0, -1, 0)
		VoxelTypes.Face.POS_Z:
			return Vector3(0, 0, 1)
		VoxelTypes.Face.NEG_Z:
			return Vector3(0, 0, -1)
		_:
			return Vector3.UP

func _tile_uvs(tile: Vector2i) -> Array[Vector2]:
	var cols: float = max(1.0, atlas_columns * 1.0)
	var rows: float = max(1.0, atlas_rows * 1.0)

	var du: float = 1.0 / cols
	var dv: float = 1.0 / rows

	# 采用“像素级 padding”减少图集采样出血（需要你保证图集格子大小一致）
	var pad_u: float = (uv_padding_pixels / cols) * 0.001
	var pad_v: float = (uv_padding_pixels / rows) * 0.001

	var u0: float = (tile.x * 1.0) * du + pad_u
	var v0: float = (tile.y * 1.0) * dv + pad_v
	var u1: float = ((tile.x + 1) * 1.0) * du - pad_u
	var v1: float = ((tile.y + 1) * 1.0) * dv - pad_v

	# Godot 纹理 UV 的 (0,0) 在左上角，因此 v 越大越靠下
	# 这里的 4 个 UV 对应 _try_add_face 传入的 4 个顶点顺序
	return [
		Vector2(u0, v1),
		Vector2(u1, v1),
		Vector2(u1, v0),
		Vector2(u0, v0),
	]

func _tile_uv_rect(tile: Vector2i) -> Rect2:
	var cols: int = max(1, atlas_columns)
	var rows: int = max(1, atlas_rows)
	var tp: float = max(1.0, tile_pixels * 1.0)
	var pad_px: float = clampf(uv_padding_pixels, 0.0, tp * 0.49)

	var atlas_w: float = float(cols) * tp
	var atlas_h: float = float(rows) * tp

	var left: float = (float(tile.x) * tp + pad_px) / atlas_w
	var right: float = (float(tile.x + 1) * tp - pad_px) / atlas_w
	var top: float = (float(tile.y) * tp + pad_px) / atlas_h
	var bottom: float = (float(tile.y + 1) * tp - pad_px) / atlas_h

	return Rect2(Vector2(left, top), Vector2(right - left, bottom - top))

func _face_uv_local(face: int, corner: Vector3) -> Vector2:
	# 约定：uv_local 的 (0,0) 为 tile 左上角，(1,1) 为 tile 右下角
	# 侧面：v 与世界 y 对齐，确保 grass_block_side 的“草皮部分”永远朝上
	match face:
		VoxelTypes.Face.POS_X:
			return Vector2(1.0 - corner.z, 1.0 - corner.y)
		VoxelTypes.Face.NEG_X:
			return Vector2(corner.z, 1.0 - corner.y)
		VoxelTypes.Face.POS_Z:
			return Vector2(corner.x, 1.0 - corner.y)
		VoxelTypes.Face.NEG_Z:
			return Vector2(1.0 - corner.x, 1.0 - corner.y)
		VoxelTypes.Face.POS_Y:
			return Vector2(corner.x, corner.z)
		VoxelTypes.Face.NEG_Y:
			return Vector2(corner.x, 1.0 - corner.z)
		_:
			return Vector2.ZERO

func _ensure_collision_nodes() -> void:
	if _static_body == null:
		_static_body = StaticBody3D.new()
		_static_body.name = "StaticBody3D"
		add_child(_static_body)

	if _collision_shape == null:
		_collision_shape = CollisionShape3D.new()
		_collision_shape.name = "CollisionShape3D"
		_static_body.add_child(_collision_shape)

func _update_collision_from_mesh() -> void:
	if not collision_enabled:
		if _collision_shape != null:
			_collision_shape.shape = null
		if _static_body != null:
			_static_body.collision_layer = 0
			_static_body.collision_mask = 0
		return

	_ensure_collision_nodes()

	if mesh == null:
		_collision_shape.shape = null
		_static_body.collision_layer = 0
		_static_body.collision_mask = 0
		return

	var shape: Shape3D = mesh.create_trimesh_shape()
	if shape is ConcavePolygonShape3D:
		(shape as ConcavePolygonShape3D).backface_collision = true
	_collision_shape.shape = shape
	_static_body.collision_layer = 1
	_static_body.collision_mask = 2

