extends MeshInstance3D
class_name VoxelChunk

@export var chunk_size: int = 16
@export var atlas_columns: int = 4
@export var atlas_rows: int = 4
@export var uv_padding_pixels: float = 1.0
@export var voxel_scale: float = 1.0

var chunk_coord: Vector3i = Vector3i.ZERO

var _voxels: PackedByteArray = PackedByteArray()

func _ready() -> void:
	_ensure_voxel_buffer()

func setup(new_chunk_coord: Vector3i) -> void:
	chunk_coord = new_chunk_coord
	position = Vector3(chunk_coord) * float(chunk_size) * voxel_scale
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
				if not VoxelTypes.is_solid(voxel_type):
					continue

				var global_voxel: Vector3i = chunk_coord * chunk_size + Vector3i(x, y, z)

				base_vertex_index = _try_add_face(
					VoxelTypes.Face.POS_X,
					voxel_type,
					global_voxel,
					Vector3i(1, 0, 0),
					Vector3(1, 0, 0),
					Vector3(1, 1, 0),
					Vector3(1, 1, 1),
					Vector3(1, 0, 1),
					s,
					sample_neighbor,
					vertices,
					normals,
					uvs,
					indices,
					base_vertex_index
				)
				base_vertex_index = _try_add_face(
					VoxelTypes.Face.NEG_X,
					voxel_type,
					global_voxel,
					Vector3i(-1, 0, 0),
					Vector3(0, 0, 1),
					Vector3(0, 1, 1),
					Vector3(0, 1, 0),
					Vector3(0, 0, 0),
					s,
					sample_neighbor,
					vertices,
					normals,
					uvs,
					indices,
					base_vertex_index
				)
				base_vertex_index = _try_add_face(
					VoxelTypes.Face.POS_Y,
					voxel_type,
					global_voxel,
					Vector3i(0, 1, 0),
					Vector3(0, 1, 1),
					Vector3(1, 1, 1),
					Vector3(1, 1, 0),
					Vector3(0, 1, 0),
					s,
					sample_neighbor,
					vertices,
					normals,
					uvs,
					indices,
					base_vertex_index
				)
				base_vertex_index = _try_add_face(
					VoxelTypes.Face.NEG_Y,
					voxel_type,
					global_voxel,
					Vector3i(0, -1, 0),
					Vector3(0, 0, 0),
					Vector3(1, 0, 0),
					Vector3(1, 0, 1),
					Vector3(0, 0, 1),
					s,
					sample_neighbor,
					vertices,
					normals,
					uvs,
					indices,
					base_vertex_index
				)
				base_vertex_index = _try_add_face(
					VoxelTypes.Face.POS_Z,
					voxel_type,
					global_voxel,
					Vector3i(0, 0, 1),
					Vector3(1, 0, 1),
					Vector3(0, 0, 1),
					Vector3(0, 1, 1),
					Vector3(1, 1, 1),
					s,
					sample_neighbor,
					vertices,
					normals,
					uvs,
					indices,
					base_vertex_index
				)
				base_vertex_index = _try_add_face(
					VoxelTypes.Face.NEG_Z,
					voxel_type,
					global_voxel,
					Vector3i(0, 0, -1),
					Vector3(0, 0, 0),
					Vector3(1, 0, 0),
					Vector3(1, 1, 0),
					Vector3(0, 1, 0),
					s,
					sample_neighbor,
					vertices,
					normals,
					uvs,
					indices,
					base_vertex_index
				)
	# --- INDEPENDENT DESIGN END ---

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh: ArrayMesh = ArrayMesh.new()
	if vertices.size() > 0:
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = arr_mesh

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
	indices: PackedInt32Array,
	base_vertex_index: int
) -> int:
	var neighbor_global: Vector3i = global_voxel + neighbor_offset
	var neighbor_type: int = sample_neighbor.call(neighbor_global)
	if VoxelTypes.is_solid(neighbor_type):
		return base_vertex_index

	var local_origin: Vector3 = Vector3(global_voxel - chunk_coord * chunk_size) * s
	var face_normal: Vector3 = _face_normal(face)

	# --- INDEPENDENT DESIGN START ---
	# UV 分配算法：
	# 1) 根据 voxel_type 与 face，查到其在图集中的 tile 坐标（整格索引）
	# 2) 再把 tile 坐标转换为 [0,1] 的 UV 区间
	# 3) 为该面 4 个顶点填充对应 UV
	var tile: Vector2i = VoxelTypes.get_face_tile(voxel_type, face)
	var face_uvs: Array[Vector2] = _tile_uvs(tile)
	# --- INDEPENDENT DESIGN END ---

	var start: int = base_vertex_index

	vertices.push_back(local_origin + v0 * s)
	vertices.push_back(local_origin + v1 * s)
	vertices.push_back(local_origin + v2 * s)
	vertices.push_back(local_origin + v3 * s)

	for i in range(4):
		normals.push_back(face_normal)

	uvs.push_back(face_uvs[0])
	uvs.push_back(face_uvs[1])
	uvs.push_back(face_uvs[2])
	uvs.push_back(face_uvs[3])

	# Godot 的三角形正面默认使用顺时针顶点绕序
	# 参考：ArrayMesh/MeshDataTool 文档中的说明
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
	var cols: float = max(1.0, float(atlas_columns))
	var rows: float = max(1.0, float(atlas_rows))

	var du: float = 1.0 / cols
	var dv: float = 1.0 / rows

	# 采用“像素级 padding”减少图集采样出血（需要你保证图集格子大小一致）
	var pad_u: float = (uv_padding_pixels / cols) * 0.001
	var pad_v: float = (uv_padding_pixels / rows) * 0.001

	var u0: float = float(tile.x) * du + pad_u
	var v0: float = float(tile.y) * dv + pad_v
	var u1: float = float(tile.x + 1) * du - pad_u
	var v1: float = float(tile.y + 1) * dv - pad_v

	# Godot 纹理 UV 的 (0,0) 在左上角，因此 v 越大越靠下
	# 这里的 4 个 UV 对应 _try_add_face 传入的 4 个顶点顺序
	return [
		Vector2(u0, v1),
		Vector2(u1, v1),
		Vector2(u1, v0),
		Vector2(u0, v0),
	]
