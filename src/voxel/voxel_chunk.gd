extends MeshInstance3D
class_name VoxelChunk

## ============================================================
## 体素区块 (VoxelChunk) — 世界的基本渲染单元
## ============================================================
## 职责：
##   1. 存储一个 16×16×N 柱状区域的体素数据（按列字典存储）
##   2. 执行贪心面剔除 + 程序化网格生成（ArrayMesh）
##   3. 执行 BFS 天光传播缓存
##   4. 生成物理碰撞体（Trimesh ConcavePolygonShape3D）
##
## 数据模型：
##   - _columns[chunk_size × chunk_size]: 每个 (x,z) 列存一个 Dictionary[int, int]
##     key=y坐标, value=体素类型(VoxelType枚举)
##   - _col_top_y[] / _col_bottom_y[]: 每列的最高/最低体素Y（加速范围查询）
##   - _col_top_occluder_y[]: 每列最高遮挡体素Y（用于天光直接光照判断）
##   - _skylight_cache[]: BFS天光传播结果（16×16×16, 0~15），仅对缓存有效的Chunk可用
##
## 关键算法：
##   - rebuild_mesh(): 面剔除 + 顶点/UV/颜色/索引构建
##   - _try_add_face(): 单个面的可见性检查 + UV计算 + 顶点推入
##   - _build_skylight_cache(): BFS从列顶向六方向扩散天光衰减
## ============================================================

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

const _MIN_I32: int = -2147483648

# 说明：本项目的区块在 X/Z 方向按 16×16 切分，Y 方向不切分（同一区块内 Y 可任意高度）。
# 体素数据采用“按列存储”：每个 (x,z) 保存一个 y->voxel_type 的字典，避免为无限高度分配大数组。
var _columns: Array[Dictionary] = []
var _col_top_y: PackedInt32Array = PackedInt32Array()
var _col_bottom_y: PackedInt32Array = PackedInt32Array()
var _min_y: int = 0
var _max_y: int = -1
var _static_body: StaticBody3D
var _collision_shape: CollisionShape3D
var _col_top_occluder_y: PackedInt32Array = PackedInt32Array()
var _skylight_cache: PackedByteArray = PackedByteArray()
var _skylight_cache_valid: bool = false
var _skylight_direct: Callable

func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_ensure_voxel_buffer()
	_ensure_collision_nodes()

func setup(new_chunk_coord: Vector3i) -> void:
	chunk_coord = new_chunk_coord
	position = Vector3(chunk_coord) * (chunk_size * 1.0) * voxel_scale
	_ensure_voxel_buffer()

func _ensure_voxel_buffer() -> void:
	# VoxelWorld 可能会在节点进入场景树（_ready）之前调用地形填充/放置方块。
	# 因此，Chunk 必须在任何体素读写之前确保列存储已初始化。
	if _columns.size() != chunk_size * chunk_size:
		_initialize_voxels()

func _initialize_voxels() -> void:
	_columns.clear()
	_columns.resize(chunk_size * chunk_size)
	for i in range(_columns.size()):
		_columns[i] = {}
	_col_top_y.resize(chunk_size * chunk_size)
	_col_bottom_y.resize(chunk_size * chunk_size)
	_col_top_occluder_y.resize(chunk_size * chunk_size)
	for i in range(_col_top_y.size()):
		_col_top_y[i] = _MIN_I32
		_col_bottom_y[i] = _MIN_I32
		_col_top_occluder_y[i] = _MIN_I32
	_min_y = 0
	_max_y = -1

func _col_index(x: int, z: int) -> int:
	return x + z * chunk_size

func is_in_bounds(x: int, _y: int, z: int) -> bool:
	return x >= 0 and x < chunk_size and z >= 0 and z < chunk_size

func get_voxel_local(x: int, y: int, z: int) -> int:
	_ensure_voxel_buffer()
	if not is_in_bounds(x, y, z):
		return VoxelTypes.VoxelType.AIR
	var col: Dictionary = _columns[_col_index(x, z)]
	return int(col.get(y, VoxelTypes.VoxelType.AIR))

func set_voxel_local(x: int, y: int, z: int, voxel_type: int) -> void:
	_ensure_voxel_buffer()
	if not is_in_bounds(x, y, z):
		return
	var idx: int = _col_index(x, z)
	var col: Dictionary = _columns[idx]
	if voxel_type == VoxelTypes.VoxelType.AIR:
		if col.has(y):
			var old_type: int = int(col.get(y, VoxelTypes.VoxelType.AIR))
			col.erase(y)
			if _col_top_y[idx] == y or _col_bottom_y[idx] == y:
				_recompute_column_minmax(idx, col)
			if BlockRegistryScript.occludes_faces(old_type) and _col_top_occluder_y[idx] == y:
				_recompute_column_occluder_top(idx, col)
			if _max_y == y or _min_y == y:
				_recompute_chunk_minmax()
	else:
		col[y] = voxel_type
		if _col_top_y[idx] == _MIN_I32 or y > _col_top_y[idx]:
			_col_top_y[idx] = y
		if _col_bottom_y[idx] == _MIN_I32 or y < _col_bottom_y[idx]:
			_col_bottom_y[idx] = y
		if BlockRegistryScript.occludes_faces(voxel_type):
			if _col_top_occluder_y[idx] == _MIN_I32 or y > _col_top_occluder_y[idx]:
				_col_top_occluder_y[idx] = y
		if _max_y < 0 or y > _max_y:
			_max_y = y
		if _max_y < 0 or y < _min_y:
			_min_y = y
	_columns[idx] = col


func get_column_top_y(x: int, z: int) -> int:
	_ensure_voxel_buffer()
	if not is_in_bounds(x, 0, z):
		return _MIN_I32
	return int(_col_top_y[_col_index(x, z)])

func get_column_top_occluder_y(x: int, z: int) -> int:
	_ensure_voxel_buffer()
	if not is_in_bounds(x, 0, z):
		return _MIN_I32
	return int(_col_top_occluder_y[_col_index(x, z)])

func _recompute_column_occluder_top(idx: int, col: Dictionary) -> void:
	var top: int = _MIN_I32
	for k in col.keys():
		var yy: int = int(k)
		var vt: int = int(col[k])
		if not BlockRegistryScript.occludes_faces(vt):
			continue
		if top == _MIN_I32 or yy > top:
			top = yy
	_col_top_occluder_y[idx] = top


func _recompute_column_minmax(idx: int, col: Dictionary) -> void:
	var top: int = _MIN_I32
	var bottom: int = _MIN_I32
	for k in col.keys():
		var yy: int = int(k)
		if top == _MIN_I32 or yy > top:
			top = yy
		if bottom == _MIN_I32 or yy < bottom:
			bottom = yy
	_col_top_y[idx] = top
	_col_bottom_y[idx] = bottom


func _recompute_chunk_minmax() -> void:
	var top: int = _MIN_I32
	var bottom: int = _MIN_I32
	for i in range(_col_top_y.size()):
		var ct: int = int(_col_top_y[i])
		if ct != _MIN_I32 and (top == _MIN_I32 or ct > top):
			top = ct
		var cb: int = int(_col_bottom_y[i])
		if cb != _MIN_I32 and (bottom == _MIN_I32 or cb < bottom):
			bottom = cb
	if top == _MIN_I32:
		_min_y = 0
		_max_y = -1
	else:
		_min_y = bottom
		_max_y = top

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
	_skylight_cache_valid = false
	_skylight_direct = sample_skylight
	_build_skylight_cache(sample_neighbor, sample_skylight)
	var skylight_callable: Callable = Callable(self, "_sample_skylight_cached")
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var uv2s: PackedVector2Array = PackedVector2Array()
	var colors: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()
	var base_vertex_index: int = 0
	var s: float = voxel_scale

	# 说明：为减少重复查询与重复计算，这里对“按方块类型不变”的数据做缓存：
	# - BlockData 资源引用
	# - 每个面的 tile_uv_rect
	# - tint_mode/use_side_overlay/alpha_cutoff
	var block_cache: Dictionary = {}
	var tile_uv_cache: Dictionary = {}
	var tint_mode_cache: Dictionary = {}
	var side_overlay_cache: Dictionary = {}
	var alpha_cutoff_cache: Dictionary = {}
	var leaf_flag_cache: Dictionary = {}

	# --- INDEPENDENT DESIGN START ---
	# 程序化网格生成 + 面剔除：
	# 对每个非空气体素，检查 6 个相邻格子。
	# - 如果相邻为空气（或越界外部空气），说明该面暴露，需要生成该面 2 个三角形。
	# - 如果相邻是实体体素，说明该面被遮挡，不生成。
	#
	# 这里“剔除”的核心不是 GPU 的背面剔除，而是“根本不生成内部面”，减少顶点数与三角形数。
	if _max_y < _min_y:
		mesh = null
		_update_collision_from_mesh()
		return

	for z in range(chunk_size):
		for x in range(chunk_size):
			var col: Dictionary = _columns[_col_index(x, z)]
			if col.is_empty():
				continue
			for k in col.keys():
				var y: int = int(k)
				var voxel_type: int = int(col[k])
				if not BlockRegistryScript.is_solid(voxel_type):
					continue

				var global_voxel: Vector3i = chunk_coord * chunk_size + Vector3i(x, y, z)
				var local_voxel: Vector3i = Vector3i(x, y, z)
				var biome_id: int = _biome_id_at(global_voxel.x, global_voxel.z)

				var block: Resource = block_cache.get(voxel_type, null)
				if block == null:
					block = BlockRegistryScript.get_block(voxel_type)
					block_cache[voxel_type] = block

				var tint_mode: int = 0
				var use_side_overlay: bool = false
				var alpha_cutoff: float = 0.0
				var leaf_flag: float = 0.0
				if tint_mode_cache.has(voxel_type):
					tint_mode = int(tint_mode_cache[voxel_type])
					use_side_overlay = bool(side_overlay_cache[voxel_type])
					alpha_cutoff = float(alpha_cutoff_cache[voxel_type])
					leaf_flag = float(leaf_flag_cache[voxel_type])
				else:
					if block != null:
						tint_mode = str(block.get("tint_mode")).to_int()
						use_side_overlay = bool(block.get("use_side_overlay"))
						alpha_cutoff = str(block.get("alpha_cutoff")).to_float()
					leaf_flag = 1.0 if tint_mode == 2 else 0.0
					tint_mode_cache[voxel_type] = tint_mode
					side_overlay_cache[voxel_type] = use_side_overlay
					alpha_cutoff_cache[voxel_type] = alpha_cutoff
					leaf_flag_cache[voxel_type] = leaf_flag

				var cx: Array = FACE_CORNERS[VoxelTypes.Face.POS_X]
				base_vertex_index = _try_add_face(
					VoxelTypes.Face.POS_X,
					voxel_type,
					global_voxel,
					local_voxel,
					Vector3i(1, 0, 0),
					cx[0],
					cx[1],
					cx[2],
					cx[3],
					s,
					sample_neighbor,
					skylight_callable,
					block,
					tint_mode,
					use_side_overlay,
					alpha_cutoff,
					leaf_flag,
					biome_id,
					tile_uv_cache,
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
					local_voxel,
					Vector3i(-1, 0, 0),
					cnx[0],
					cnx[1],
					cnx[2],
					cnx[3],
					s,
					sample_neighbor,
					skylight_callable,
					block,
					tint_mode,
					use_side_overlay,
					alpha_cutoff,
					leaf_flag,
					biome_id,
					tile_uv_cache,
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
					local_voxel,
					Vector3i(0, 1, 0),
					cy[0],
					cy[1],
					cy[2],
					cy[3],
					s,
					sample_neighbor,
					skylight_callable,
					block,
					tint_mode,
					use_side_overlay,
					alpha_cutoff,
					leaf_flag,
					biome_id,
					tile_uv_cache,
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
					local_voxel,
					Vector3i(0, -1, 0),
					cny[0],
					cny[1],
					cny[2],
					cny[3],
					s,
					sample_neighbor,
					skylight_callable,
					block,
					tint_mode,
					use_side_overlay,
					alpha_cutoff,
					leaf_flag,
					biome_id,
					tile_uv_cache,
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
					local_voxel,
					Vector3i(0, 0, 1),
					cz[0],
					cz[1],
					cz[2],
					cz[3],
					s,
					sample_neighbor,
					skylight_callable,
					block,
					tint_mode,
					use_side_overlay,
					alpha_cutoff,
					leaf_flag,
					biome_id,
					tile_uv_cache,
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
					local_voxel,
					Vector3i(0, 0, -1),
					cnz[0],
					cnz[1],
					cnz[2],
					cnz[3],
					s,
					sample_neighbor,
					skylight_callable,
					block,
					tint_mode,
					use_side_overlay,
					alpha_cutoff,
					leaf_flag,
					biome_id,
					tile_uv_cache,
					vertices,
					normals,
					uvs,
					uv2s,
					colors,
					indices,
					base_vertex_index
				)
	# --- INDEPENDENT DESIGN END ---

	var arr_mesh: ArrayMesh = ArrayMesh.new()
	if vertices.size() <= 0:
		mesh = null
		_update_collision_from_mesh()
		return

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = arr_mesh
	_update_collision_from_mesh()

func _sample_skylight_cached(global_voxel: Vector3i) -> int:
	if not _skylight_cache_valid:
		if _skylight_direct.is_null():
			return 15
		return int(_skylight_direct.call(global_voxel))
	var local: Vector3i = global_voxel - chunk_coord * chunk_size
	if local.x < 0 or local.x >= chunk_size or local.z < 0 or local.z >= chunk_size:
		if _skylight_direct.is_null():
			return 15
		return int(_skylight_direct.call(global_voxel))
	if local.y < 0 or local.y >= chunk_size:
		if _skylight_direct.is_null():
			return 15
		return int(_skylight_direct.call(global_voxel))
	var idx: int = local.x + chunk_size * (local.z + chunk_size * local.y)
	if idx < 0 or idx >= _skylight_cache.size():
		return 0
	return int(_skylight_cache[idx])

func is_skylight_cache_valid() -> bool:
	return _skylight_cache_valid

func get_skylight_local(x: int, y: int, z: int) -> int:
	if not _skylight_cache_valid:
		return 0
	if x < 0 or x >= chunk_size or y < 0 or y >= chunk_size or z < 0 or z >= chunk_size:
		return 0
	var idx: int = x + chunk_size * (z + chunk_size * y)
	if idx < 0 or idx >= _skylight_cache.size():
		return 0
	return int(_skylight_cache[idx])

func _is_light_passable(voxel_type: int) -> bool:
	if voxel_type == VoxelTypes.VoxelType.AIR:
		return true
	return not BlockRegistryScript.occludes_faces(voxel_type)

## BFS天光传播算法（3阶段）：
## 阶段1 — 从列顶(y=15)向下扫描，透光方块设光值15，入队。
## 阶段2 — 边界格子查询邻居Chunk光值，减2衰减后注入本Chunk（保证跨区块连续渐变）。
## 阶段3 — BFS出队扩散，向六方向传播：next_lv=lv-2。衰减到0或遇遮挡方块停止。
func _build_skylight_cache(sample_neighbor: Callable, sample_skylight: Callable) -> void:
	_skylight_cache.clear()
	_skylight_cache.resize(chunk_size * chunk_size * chunk_size)
	_skylight_cache.fill(0)
	var q: Array[Vector3i] = []

	for z in range(chunk_size):
		for x in range(chunk_size):
			for y in range(chunk_size - 1, -1, -1):
				var vt: int = get_voxel_local(x, y, z)
				if not _is_light_passable(vt):
					break
				var idx0: int = x + chunk_size * (z + chunk_size * y)
				_skylight_cache[idx0] = 15
				q.push_back(Vector3i(x, y, z))

	var dirs: Array[Vector3i] = [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
	]

	if not sample_skylight.is_null():
		for z2 in range(chunk_size):
			for x2 in range(chunk_size):
				for y2 in range(chunk_size):
					if x2 != 0 and x2 != chunk_size - 1 and z2 != 0 and z2 != chunk_size - 1:
						continue
					var vt2: int = get_voxel_local(x2, y2, z2)
					if not _is_light_passable(vt2):
						continue
					var g: Vector3i = chunk_coord * chunk_size + Vector3i(x2, y2, z2)
					for d in dirs:
						var nl: Vector3i = Vector3i(x2, y2, z2) + d
						if nl.x >= 0 and nl.x < chunk_size and nl.y >= 0 and nl.y < chunk_size and nl.z >= 0 and nl.z < chunk_size:
							continue
						var out_light: int = int(sample_skylight.call(g + d))
						if out_light <= 0:
							continue
						var idx1: int = x2 + chunk_size * (z2 + chunk_size * y2)
						var cur: int = int(_skylight_cache[idx1])
						var cand: int = max(0, out_light - 2)
						if cand > cur:
							_skylight_cache[idx1] = cand
							q.push_back(Vector3i(x2, y2, z2))

	while not q.is_empty():
		var p: Vector3i = q.pop_back()
		var idxp: int = p.x + chunk_size * (p.z + chunk_size * p.y)
		var lv: int = int(_skylight_cache[idxp])
		if lv <= 1:
			continue
		var next_lv: int = lv - 2
		if next_lv <= 0:
			continue
		for d2 in dirs:
			var np: Vector3i = p + d2
			if np.x < 0 or np.x >= chunk_size or np.y < 0 or np.y >= chunk_size or np.z < 0 or np.z >= chunk_size:
				continue
			var vt3: int = get_voxel_local(np.x, np.y, np.z)
			if not _is_light_passable(vt3):
				continue
			var idxn: int = np.x + chunk_size * (np.z + chunk_size * np.y)
			if int(_skylight_cache[idxn]) >= next_lv:
				continue
			_skylight_cache[idxn] = next_lv
			q.push_back(np)

	_skylight_cache_valid = true

func _try_add_face(
	face: int,
	voxel_type: int,
	global_voxel: Vector3i,
	local_voxel: Vector3i,
	neighbor_offset: Vector3i,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	s: float,
	sample_neighbor: Callable,
	sample_skylight: Callable,
	block: Resource,
	tint_mode: int,
	use_side_overlay: bool,
	alpha_cutoff: float,
	leaf_flag: float,
	biome_id: int,
	tile_uv_cache: Dictionary,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	base_vertex_index: int
) -> int:
	var neighbor_global: Vector3i = global_voxel + neighbor_offset
	var neighbor_type: int = VoxelTypes.VoxelType.AIR
	var nl: Vector3i = local_voxel + neighbor_offset
	if is_in_bounds(nl.x, nl.y, nl.z):
		neighbor_type = get_voxel_local(nl.x, nl.y, nl.z)
	else:
		neighbor_type = int(sample_neighbor.call(neighbor_global))
	if voxel_type == VoxelTypes.VoxelType.GLASS and neighbor_type == voxel_type:
		return base_vertex_index
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
	var cache_key: int = voxel_type * 8 + face
	var tile_uv_rect: Rect2 = tile_uv_cache.get(cache_key, Rect2())
	if tile_uv_rect.size == Vector2.ZERO:
		var tile: Vector2i = Vector2i.ZERO
		if block != null:
			tile = block.call("tile_for_face", face)
		tile_uv_rect = _tile_uv_rect(tile)
		tile_uv_cache[cache_key] = tile_uv_rect
	# --- INDEPENDENT DESIGN END ---

	var start: int = base_vertex_index

	# 说明：把“是否树叶(0/1)”与“群系ID(0/1/2)”打包到 UV2.x，确保同一个方块 6 个面颜色一致。
	# 解码规则在 voxel_lit.gdshader 中：
	# - leaf_mask = step(0.5, UV2.x)
	# - biome_id = floor((UV2.x - leaf_mask*0.5) * 8.0)
	var uv2_x: float = leaf_flag * 0.5 + (float(biome_id) + 0.5) * (1.0 / 8.0)

	var grass_top_mask: float = 0.0
	if tint_mode == 1 and face == VoxelTypes.Face.POS_Y:
		grass_top_mask = 1.0
	elif tint_mode == 2:
		grass_top_mask = 1.0

	var grass_side_mask: float = 0.0
	if use_side_overlay and (face == VoxelTypes.Face.POS_X or face == VoxelTypes.Face.NEG_X or face == VoxelTypes.Face.POS_Z or face == VoxelTypes.Face.NEG_Z):
		grass_side_mask = 1.0

	var corners: Array[Vector3] = [v0, v1, v2, v3]
	for i in range(4):
		var pos: Vector3 = local_origin + corners[i] * s
		vertices.push_back(pos)
		normals.push_back(face_normal)
		var uv_local: Vector2 = _face_uv_local(face, corners[i])
		uvs.push_back(tile_uv_rect.position + Vector2(tile_uv_rect.size.x * uv_local.x, tile_uv_rect.size.y * uv_local.y))
		uv2s.push_back(Vector2(uv2_x, alpha_cutoff))
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
