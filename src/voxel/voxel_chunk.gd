extends MeshInstance3D
class_name VoxelChunk

const BlockRegistryScript := preload("res://src/voxel/block_registry.gd")

@export var chunk_size: int = 16
@export var atlas_columns: int = 4
@export var atlas_rows: int = 2
@export var tile_pixels: int = 16
@export var uv_padding_pixels: float = 0.0
@export var voxel_scale: float = 1.0

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

func rebuild_mesh(sample_neighbor: Callable) -> void:
	# sample_neighbor: (global_voxel_pos: Vector3i) -> int，用于跨 Chunk 查询相邻体素
	_ensure_voxel_buffer()
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
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
					vertices,
					normals,
					uvs,
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
					vertices,
					normals,
					uvs,
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
					vertices,
					normals,
					uvs,
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
					vertices,
					normals,
					uvs,
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
					vertices,
					normals,
					uvs,
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
					vertices,
					normals,
					uvs,
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
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	base_vertex_index: int
) -> int:
	var neighbor_global: Vector3i = global_voxel + neighbor_offset
	var neighbor_type: int = sample_neighbor.call(neighbor_global)
	if BlockRegistryScript.is_solid(neighbor_type):
		return base_vertex_index

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

	var grass_top_mask: float = 1.0 if (voxel_type == VoxelTypes.VoxelType.GRASS and face == VoxelTypes.Face.POS_Y) else 0.0
	var grass_side_mask: float = 1.0 if (voxel_type == VoxelTypes.VoxelType.GRASS and (face == VoxelTypes.Face.POS_X or face == VoxelTypes.Face.NEG_X or face == VoxelTypes.Face.POS_Z or face == VoxelTypes.Face.NEG_Z)) else 0.0
	var material_params: Vector2 = Vector2(0.95, 0.08)
	if block != null:
		material_params = block.call("material_params_for_face", face)
	var roughness: float = material_params.x
	var specular: float = material_params.y
	for i in range(4):
		# 顶点色在本项目中仅作为“掩码数据”使用，不参与传统意义的顶点颜色渲染：
		# - COLOR.r：草顶面染色掩码（1 表示该面需要乘以 grass_tint）
		# - COLOR.g：草侧面覆盖层掩码（1 表示该面需要额外叠加 grass_block_side_overlay 的染色）
		# - COLOR.b：粗糙度 roughness（0 光滑 - 1 粗糙）
		# - COLOR.a：镜面强度 specular（0 无高光 - 1 高光强）
		colors.push_back(Color(grass_top_mask, grass_side_mask, roughness, specular))

	indices.push_back(start + 0)
	indices.push_back(start + 1)
	indices.push_back(start + 2)
	indices.push_back(start + 0)
	indices.push_back(start + 2)
	indices.push_back(start + 3)

	return base_vertex_index + 4

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

