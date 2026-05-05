extends Node3D
class_name VoxelWorld

const BlockRegistryScript := preload("res://src/voxel/block_registry.gd")
const ItemDropScene: PackedScene = preload("res://scenes/item_drop.tscn")
const FallingBlockScene: PackedScene = preload("res://scenes/falling_block.tscn")
const AtlasBuilderScript := preload("res://src/voxel/atlas_builder.gd")
const _MIN_I32: int = -2147483648
const _PREBUILT_ATLAS_PNG_PATH: String = "res://resources/textures/block_atlas.png"

@export var chunk_size: int = 16
@export var atlas_columns: int = 4
@export var atlas_rows: int = 2
@export var voxel_scale: float = 1.0
@export var atlas_texture: Texture2D
@export var max_interact_distance: float = 6.0
@export var highlight_expand: float = 0.0
@export var highlight_thickness: float = 0.02

## 玩家节点路径（用于以玩家为中心加载/卸载区块）
@export var player_path: NodePath = NodePath("../Player")
## 以玩家所在区块为中心的加载半径（单位：区块；半径=2 表示加载 5×5）
@export_range(0, 12, 1) var chunk_load_radius: int = 2
## 卸载半径（单位：区块；必须 >= chunk_load_radius，越大越不容易来回抖动）
@export_range(0, 16, 1) var chunk_unload_radius: int = 3
## 区块流式更新的时间间隔（秒），避免每帧创建/销毁导致卡顿
@export_range(0.05, 2.0, 0.05) var chunk_stream_interval: float = 0.2
## 每次流式更新最多执行的区块创建/卸载次数（越大越容易卡顿）
@export_range(1, 8, 1) var max_chunk_ops_per_tick: int = 2
## 每次流式更新最多重建的区块网格数量（越大越容易卡顿）
@export_range(1, 8, 1) var max_chunk_mesh_rebuilds_per_tick: int = 2
## 是否自动卸载远处区块（关掉可用于调试）
@export var chunk_auto_unload: bool = true

## 地形生成模式
@export_enum("Flat", "Hills") var terrain_mode: int = 1
## 地形随机种子
@export var terrain_seed: int = 1337
## 平均地表高度（体素 Y，范围建议 1~14）
@export_range(1, 14, 1) var terrain_base_height: int = 7
## 地形起伏幅度（体素 Y）
@export_range(0, 12, 1) var terrain_height_amplitude: int = 4
## 地形噪声尺度（越小变化越缓，越大起伏越密）
@export_range(0.001, 0.2, 0.001) var terrain_noise_scale: float = 0.03
## 群系分布尺度（越小群系块越大）
@export_range(0.0001, 0.2, 0.0001) var biome_map_scale: float = 0.03
## 需要开启碰撞的区块半径（单位：区块；用于减少远处区块生成碰撞带来的卡顿）
@export_range(0, 6, 1) var collision_chunk_radius: int = 1

var _chunks: Dictionary = {}
var _material: ShaderMaterial
var _tile_pixels: int = 16
var _highlight_mesh_instance: MeshInstance3D
var _highlight_mesh: ImmediateMesh
var _highlight_material: StandardMaterial3D
var _highlight_last_voxel: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)
var _sky_brightness_current: float = -1.0
var _stream_time_left: float = 0.0
var _player: Node3D
var _height_noise: FastNoiseLite
var _pending_create: Array[Vector3i] = []
var _pending_unload: Array[Vector3i] = []
var _pending_mesh_rebuild: Array[Vector3i] = []
var _last_player_center_chunk: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)
var _suppress_sand_schedule: bool = false

func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = preload("res://shaders/voxel_lit.gdshader")
	_ensure_atlas_ready()
	_apply_material_settings()

	_player = get_node_or_null(player_path) as Node3D
	_height_noise = FastNoiseLite.new()
	_height_noise.seed = terrain_seed
	_height_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_height_noise.frequency = terrain_noise_scale

	_ensure_initial_chunks()
	_ensure_block_highlight()


func _process(delta: float) -> void:
	_stream_time_left -= max(0.0, delta)
	if _stream_time_left > 0.0:
		return
	_stream_time_left = max(0.05, chunk_stream_interval)
	_plan_chunk_streaming()
	_process_chunk_ops()
	_process_mesh_rebuilds()


func _physics_process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var center: Vector3i = _get_player_chunk_center()
	if center != _last_player_center_chunk:
		_last_player_center_chunk = center
		_ensure_chunk_ready_now(center)


func _ensure_initial_chunks() -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_node_or_null(player_path) as Node3D
	if _player == null:
		if _chunks.is_empty():
			var ch0: VoxelChunk = _create_chunk(Vector3i.ZERO, true)
			ch0.collision_enabled = true
			ch0.rebuild_mesh(_sample_voxel_global, Callable(self, "_sample_skylight_global"))
		return

	var p: Vector3 = _player.global_position / max(0.0001, voxel_scale)
	var pv: Vector3i = Vector3i(floori(p.x), floori(p.y), floori(p.z))
	var center: Vector3i = _voxel_to_chunk_coord(pv)

	if not _chunks.has(center):
		var chc: VoxelChunk = _create_chunk(center, true)
		chc.collision_enabled = true
		chc.rebuild_mesh(_sample_voxel_global, Callable(self, "_sample_skylight_global"))
	_last_player_center_chunk = center
	_plan_chunk_streaming()


func _plan_chunk_streaming() -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_node_or_null(player_path) as Node3D
	if _player == null:
		return

	var p: Vector3 = _player.global_position / max(0.0001, voxel_scale)
	var pv: Vector3i = Vector3i(floori(p.x), floori(p.y), floori(p.z))
	var center: Vector3i = _voxel_to_chunk_coord(pv)

	var load_r: int = max(0, chunk_load_radius)
	var unload_r: int = max(load_r, chunk_unload_radius)

	for cz in range(center.z - load_r, center.z + load_r + 1):
		for cx in range(center.x - load_r, center.x + load_r + 1):
			var cc: Vector3i = Vector3i(cx, 0, cz)
			if _chunks.has(cc) or _pending_create.has(cc):
				continue
			_pending_create.push_back(cc)

	if chunk_auto_unload and _chunks.size() > 0:
		for k in _chunks.keys():
			var cc: Vector3i = k
			if abs(cc.x - center.x) > unload_r or abs(cc.z - center.z) > unload_r:
				if not _pending_unload.has(cc):
					_pending_unload.append(cc)


func _process_chunk_ops() -> void:
	var ops: int = clampi(max_chunk_ops_per_tick, 1, 8)
	var did_change: bool = false

	while ops > 0 and not _pending_unload.is_empty():
		var center: Vector3i = _get_player_chunk_center()
		var cc: Vector3i = _pop_nearest_chunk(_pending_unload, center)
		if not _chunks.has(cc):
			continue
		var unload_r: int = max(max(0, chunk_load_radius), chunk_unload_radius)
		if abs(cc.x - center.x) <= unload_r and abs(cc.z - center.z) <= unload_r:
			continue
		var ch: VoxelChunk = _chunks.get(cc, null)
		if ch != null and is_instance_valid(ch):
			ch.queue_free()
		_chunks.erase(cc)
		did_change = true
		_mark_chunk_dirty(cc)
		_mark_chunk_dirty(cc + Vector3i(1, 0, 0))
		_mark_chunk_dirty(cc + Vector3i(-1, 0, 0))
		_mark_chunk_dirty(cc + Vector3i(0, 0, 1))
		_mark_chunk_dirty(cc + Vector3i(0, 0, -1))
		ops -= 1

	while ops > 0 and not _pending_create.is_empty():
		var center: Vector3i = _get_player_chunk_center()
		var cc: Vector3i = _pop_nearest_chunk(_pending_create, center)
		if _chunks.has(cc):
			continue
		_create_chunk(cc, true)
		did_change = true
		_mark_chunk_dirty(cc)
		_mark_chunk_dirty(cc + Vector3i(1, 0, 0))
		_mark_chunk_dirty(cc + Vector3i(-1, 0, 0))
		_mark_chunk_dirty(cc + Vector3i(0, 0, 1))
		_mark_chunk_dirty(cc + Vector3i(0, 0, -1))
		ops -= 1

	if did_change:
		return


func _process_mesh_rebuilds() -> void:
	var count: int = clampi(max_chunk_mesh_rebuilds_per_tick, 1, 8)
	var center: Vector3i = _get_player_chunk_center()
	var cr: int = max(0, collision_chunk_radius)
	while count > 0 and not _pending_mesh_rebuild.is_empty():
		var cc: Vector3i = _pop_nearest_chunk(_pending_mesh_rebuild, center)
		var ch: VoxelChunk = _chunks.get(cc, null)
		if ch == null:
			count -= 1
			continue
		ch.collision_enabled = (abs(cc.x - center.x) <= cr and abs(cc.z - center.z) <= cr)
		ch.rebuild_mesh(_sample_voxel_global, Callable(self, "_sample_skylight_global"))
		count -= 1


func _mark_chunk_dirty(chunk_coord: Vector3i) -> void:
	var cc: Vector3i = chunk_coord
	if not _chunks.has(cc):
		return
	if _pending_mesh_rebuild.has(cc):
		return
	_pending_mesh_rebuild.push_back(cc)


func _pop_nearest_chunk(queue: Array[Vector3i], center: Vector3i) -> Vector3i:
	var best_i: int = -1
	var best_d: int = 2147483647
	for i in range(queue.size()):
		var c: Vector3i = queue[i]
		var d: int = abs(c.x - center.x) + abs(c.z - center.z)
		if d < best_d:
			best_d = d
			best_i = i
	if best_i < 0:
		return Vector3i.ZERO
	var v: Vector3i = queue[best_i]
	queue.remove_at(best_i)
	return v


func _ensure_chunk_ready_now(chunk_coord: Vector3i) -> void:
	var cc: Vector3i = chunk_coord
	var ch: VoxelChunk = _chunks.get(cc, null)
	if ch == null:
		ch = _create_chunk(cc, true)
	ch.collision_enabled = true
	ch.rebuild_mesh(_sample_voxel_global, Callable(self, "_sample_skylight_global"))


func _get_player_chunk_center() -> Vector3i:
	if _player == null or not is_instance_valid(_player):
		return Vector3i.ZERO
	var p: Vector3 = _player.global_position / max(0.0001, voxel_scale)
	var pv: Vector3i = Vector3i(floori(p.x), floori(p.y), floori(p.z))
	var center: Vector3i = _voxel_to_chunk_coord(pv)
	return center

func _apply_material_settings() -> void:
	if atlas_texture != null:
		_material.set_shader_parameter("atlas_texture", atlas_texture)
		_material.set_shader_parameter("atlas_rows", atlas_rows * 1.0)
	_material.set_shader_parameter("sky_brightness", 1.0)
	_material.set_shader_parameter("min_light", 0.02)
	_material.set_shader_parameter("light_curve", 1.6)

	var grass_cm: Texture2D = load("res://resources/textures/colormap/grass.png") as Texture2D
	var foliage_cm: Texture2D = load("res://resources/textures/colormap/foliage.png") as Texture2D
	var dry_foliage_cm: Texture2D = load("res://resources/textures/colormap/dry_foliage.png") as Texture2D
	var use_cm: bool = grass_cm != null and foliage_cm != null and dry_foliage_cm != null
	_material.set_shader_parameter("use_colormap", use_cm)
	if use_cm:
		_material.set_shader_parameter("grass_colormap", grass_cm)
		_material.set_shader_parameter("foliage_colormap", foliage_cm)
		_material.set_shader_parameter("dry_foliage_colormap", dry_foliage_cm)

func set_sky_brightness(value: float) -> void:
	if _material == null:
		return
	var v: float = clampf(value, 0.0, 1.0)
	if _sky_brightness_current >= 0.0 and absf(_sky_brightness_current - v) < 0.0005:
		return
	_sky_brightness_current = v
	_material.set_shader_parameter("sky_brightness", v)

func _ensure_block_highlight() -> void:
	if _highlight_mesh_instance != null:
		return

	_highlight_mesh = ImmediateMesh.new()
	_highlight_material = StandardMaterial3D.new()
	_highlight_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_highlight_material.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	_highlight_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_highlight_material.no_depth_test = false

	_rebuild_block_highlight_mesh()

	_highlight_mesh_instance = MeshInstance3D.new()
	_highlight_mesh_instance.name = "BlockHighlight"
	_highlight_mesh_instance.mesh = _highlight_mesh
	_highlight_mesh_instance.material_override = _highlight_material
	_highlight_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_highlight_mesh_instance.visible = false
	add_child(_highlight_mesh_instance)

func _rebuild_block_highlight_mesh() -> void:
	_highlight_mesh.clear_surfaces()
	_highlight_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _highlight_material)

	var e: float = max(0.0, highlight_expand)
	var t: float = clampf(highlight_thickness, 0.001, 0.2)
	var th: float = t * 0.5

	var min_x: float = -e
	var max_x: float = 1.0 + e
	var min_y: float = -e
	var max_y: float = 1.0 + e
	var min_z: float = -e
	var max_z: float = 1.0 + e

	for yv in [min_y, max_y]:
		for zv in [min_z, max_z]:
			_add_aabb(Vector3(min_x, yv - th, zv - th), Vector3(max_x, yv + th, zv + th))

	for xv in [min_x, max_x]:
		for zv in [min_z, max_z]:
			_add_aabb(Vector3(xv - th, min_y, zv - th), Vector3(xv + th, max_y, zv + th))

	for xv in [min_x, max_x]:
		for yv in [min_y, max_y]:
			_add_aabb(Vector3(xv - th, yv - th, min_z), Vector3(xv + th, yv + th, max_z))

	_highlight_mesh.surface_end()

func _add_tri(a: Vector3, b: Vector3, c: Vector3) -> void:
	_highlight_mesh.surface_add_vertex(a)
	_highlight_mesh.surface_add_vertex(b)
	_highlight_mesh.surface_add_vertex(c)

func _add_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_add_tri(a, b, c)
	_add_tri(a, c, d)

func _add_aabb(aabb_min: Vector3, aabb_max: Vector3) -> void:
	var c000: Vector3 = Vector3(aabb_min.x, aabb_min.y, aabb_min.z)
	var c100: Vector3 = Vector3(aabb_max.x, aabb_min.y, aabb_min.z)
	var c110: Vector3 = Vector3(aabb_max.x, aabb_max.y, aabb_min.z)
	var c010: Vector3 = Vector3(aabb_min.x, aabb_max.y, aabb_min.z)
	var c001: Vector3 = Vector3(aabb_min.x, aabb_min.y, aabb_max.z)
	var c101: Vector3 = Vector3(aabb_max.x, aabb_min.y, aabb_max.z)
	var c111: Vector3 = Vector3(aabb_max.x, aabb_max.y, aabb_max.z)
	var c011: Vector3 = Vector3(aabb_min.x, aabb_max.y, aabb_max.z)

	_add_quad(c000, c100, c110, c010)
	_add_quad(c001, c101, c111, c011)
	_add_quad(c000, c001, c011, c010)
	_add_quad(c100, c101, c111, c110)
	_add_quad(c010, c110, c111, c011)
	_add_quad(c000, c100, c101, c001)

func update_block_highlight(origin: Vector3, direction: Vector3) -> void:
	_ensure_block_highlight()
	var result: Dictionary = raycast_voxel(origin, direction, max_interact_distance)
	if not result.get("hit", false):
		_highlight_mesh_instance.visible = false
		_highlight_last_voxel = Vector3i(2147483647, 2147483647, 2147483647)
		return

	var voxel: Vector3i = result["voxel"]
	if voxel == _highlight_last_voxel and _highlight_mesh_instance.visible:
		return
	_highlight_last_voxel = voxel

	_highlight_mesh_instance.visible = true
	_highlight_mesh_instance.position = Vector3(voxel) * voxel_scale
	_highlight_mesh_instance.scale = Vector3.ONE * voxel_scale

func _create_chunk(chunk_coord: Vector3i, fill_terrain: bool) -> VoxelChunk:
	var chunk: VoxelChunk = VoxelChunk.new()
	chunk.chunk_size = chunk_size
	chunk.atlas_columns = atlas_columns
	chunk.atlas_rows = atlas_rows
	chunk.tile_pixels = _tile_pixels
	chunk.voxel_scale = voxel_scale
	chunk.biome_seed = terrain_seed
	chunk.biome_map_scale = biome_map_scale
	chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	chunk.setup(chunk_coord)
	chunk.material_override = _material

	if fill_terrain:
		_fill_chunk_terrain(chunk)

	add_child(chunk)
	_chunks[chunk_coord] = chunk
	return chunk


func _rebuild_chunks_local(center_chunk: Vector3i, radius_chunks: int) -> void:
	var r: int = max(0, radius_chunks)
	for cz in range(center_chunk.z - r, center_chunk.z + r + 1):
		for cx in range(center_chunk.x - r, center_chunk.x + r + 1):
			var cc: Vector3i = Vector3i(cx, 0, cz)
			var ch: VoxelChunk = _chunks.get(cc, null)
			if ch != null:
				ch.rebuild_mesh(_sample_voxel_global, Callable(self, "_sample_skylight_global"))

func _fill_chunk_terrain(chunk: VoxelChunk) -> void:
	if chunk == null:
		return
	var cc: Vector3i = chunk.chunk_coord
	var base: int = clampi(terrain_base_height, 1, chunk_size - 2)
	var amp: int = clampi(terrain_height_amplitude, 0, chunk_size - 2)
	var heightmap: PackedInt32Array = PackedInt32Array()
	heightmap.resize(chunk_size * chunk_size)

	for z in range(chunk_size):
		for x in range(chunk_size):
			var gx: int = cc.x * chunk_size + x
			var gz: int = cc.z * chunk_size + z
			var biome_id: int = _biome_id_at(gx, gz)
			var h: int = base
			if terrain_mode == 1 and _height_noise != null:
				var n: float = _height_noise.get_noise_2d(gx, gz)
				var biome_amp_mul: float = 0.6 if biome_id == 0 else (1.0 if biome_id == 1 else (0.75 if biome_id == 2 else 0.35))
				h = clampi(base + roundi(n * (amp * biome_amp_mul)), 1, chunk_size - 2)
			heightmap[x + z * chunk_size] = h
			for y in range(chunk_size):
				var vt: int = VoxelTypes.VoxelType.AIR
				if y == 0:
					vt = VoxelTypes.VoxelType.BEDROCK
				elif biome_id == 3:
					if y < h - 4:
						vt = VoxelTypes.VoxelType.STONE
					elif y < h:
						vt = VoxelTypes.VoxelType.SAND
				else:
					if y < h - 3:
						vt = VoxelTypes.VoxelType.STONE
					elif y < h - 1:
						vt = VoxelTypes.VoxelType.DIRT
					elif y < h:
						vt = VoxelTypes.VoxelType.GRASS
				chunk.set_voxel_local(x, y, z, vt)

	_place_trees_for_chunk(chunk, heightmap)

func _place_trees_for_chunk(chunk: VoxelChunk, heightmap: PackedInt32Array) -> void:
	if chunk == null:
		return
	# 说明：按“权重（概率）”生成树，并保留最小间距约束。
	# - 森林：更高概率
	# - 干旱：较低概率
	# - 平原：不生成树
	#
	# 为了保证最小间距，并且跨区块也尽量稳定，使用“格子候选点 + 概率筛选”的方式：
	# - 把世界 XZ 划分为固定大小的 cell，每个 cell 只产生一个候选树点（随机偏移）
	# - 候选点再按群系权重进行概率筛选
	# - 通过本区块内的 chosen 列表做最小间距剔除
	var cc: Vector3i = chunk.chunk_coord
	var origin_gx: int = cc.x * chunk_size
	var origin_gz: int = cc.z * chunk_size

	var cell_size: int = 8
	var min_dist: int = 6
	var margin: int = 2

	var cell_min_x: int = floori(float(origin_gx) / float(cell_size))
	var cell_min_z: int = floori(float(origin_gz) / float(cell_size))
	var cell_max_x: int = floori(float(origin_gx + chunk_size - 1) / float(cell_size))
	var cell_max_z: int = floori(float(origin_gz + chunk_size - 1) / float(cell_size))

	var chosen_global: Array[Vector2i] = []

	for cz in range(cell_min_z, cell_max_z + 1):
		for cx in range(cell_min_x, cell_max_x + 1):
			var hx: float = _hash01(Vector2(cx * 31 + terrain_seed * 11, cz * 37 - terrain_seed * 13))
			var hz: float = _hash01(Vector2(cx * 41 - terrain_seed * 17, cz * 29 + terrain_seed * 19))
			var ox: int = margin + floori(hx * float(max(1, cell_size - margin * 2)))
			var oz: int = margin + floori(hz * float(max(1, cell_size - margin * 2)))
			var gx: int = cx * cell_size + ox
			var gz: int = cz * cell_size + oz

			if gx < origin_gx + 2 or gx >= origin_gx + chunk_size - 2:
				continue
			if gz < origin_gz + 2 or gz >= origin_gz + chunk_size - 2:
				continue

			var biome_id: int = _biome_id_at(gx, gz)
			var chance: float = 0.0
			if biome_id == 1:
				chance = 0.55
			elif biome_id == 2:
				chance = 0.22
			else:
				continue

			var hr: float = _hash01(Vector2(gx + terrain_seed * 7, gz - terrain_seed * 11))
			if hr > chance:
				continue

			var ok: bool = true
			for c in chosen_global:
				if abs(c.x - gx) + abs(c.y - gz) < min_dist:
					ok = false
					break
			if not ok:
				continue

			var lx: int = gx - origin_gx
			var lz: int = gz - origin_gz
			var idx: int = lx + lz * chunk_size
			if idx < 0 or idx >= heightmap.size():
				continue
			_build_tree_template(chunk, lx, lz, int(heightmap[idx]))
			chosen_global.append(Vector2i(gx, gz))


func _build_tree_template(chunk: VoxelChunk, lx: int, lz: int, ground_h: int) -> void:
	if lx < 2 or lx > chunk_size - 3 or lz < 2 or lz > chunk_size - 3:
		return
	if ground_h <= 0 or ground_h >= chunk_size - 2:
		return

	var y0: int = ground_h
	if y0 + 5 >= chunk_size:
		return

	# 生成规则（按你提供的层结构）：
	# 以 ground_h 作为“地表上方第一格空气”的 y（地表草方块位于 y=ground_h-1）。
	# 1、2、3、4、5 层：中心为原木（总共 5 格高树干）。
	# 3、4 层：5×5，除中心外全填树叶。
	# 5 层：3×3，除中心外全填树叶。
	# 6 层：宽度为 3 的十字全填树叶。
	for y in range(y0, y0 + 5):
		chunk.set_voxel_local(lx, y, lz, VoxelTypes.VoxelType.OAK_LOG)

	for y in [y0 + 2, y0 + 3]:
		for oz in range(-2, 3):
			for ox in range(-2, 3):
				if ox == 0 and oz == 0:
					continue
				var ax: int = lx + ox
				var az: int = lz + oz
				if chunk.get_voxel_local(ax, y, az) == VoxelTypes.VoxelType.AIR:
					chunk.set_voxel_local(ax, y, az, VoxelTypes.VoxelType.OAK_LEAVES)

	var y5: int = y0 + 4
	for oz in range(-1, 2):
		for ox in range(-1, 2):
			if ox == 0 and oz == 0:
				continue
			var ax: int = lx + ox
			var az: int = lz + oz
			if chunk.get_voxel_local(ax, y5, az) == VoxelTypes.VoxelType.AIR:
				chunk.set_voxel_local(ax, y5, az, VoxelTypes.VoxelType.OAK_LEAVES)

	var y6: int = y0 + 5
	for off in [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var ax: int = lx + off.x
		var az: int = lz + off.z
		if chunk.get_voxel_local(ax, y6, az) == VoxelTypes.VoxelType.AIR:
			chunk.set_voxel_local(ax, y6, az, VoxelTypes.VoxelType.OAK_LEAVES)


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


func _hash01(p: Vector2) -> float:
	return _hash12(p)


func _biome_id_at(gx: int, gz: int) -> int:
	var wx: float = gx * voxel_scale
	var wz: float = gz * voxel_scale
	var n: float = _noise2(Vector2(wx, wz) * biome_map_scale + Vector2(float(terrain_seed) * 0.13, float(terrain_seed) * -0.37))
	return floori(clampf(n, 0.0, 0.999) * 4.0)

func _sample_voxel_global(global_voxel: Vector3i) -> int:
	var chunk_coord: Vector3i = _voxel_to_chunk_coord(global_voxel)
	var chunk: VoxelChunk = _chunks.get(chunk_coord, null)
	if chunk == null:
		return VoxelTypes.VoxelType.AIR

	var local: Vector3i = global_voxel - chunk_coord * chunk_size
	return chunk.get_voxel_local(local.x, local.y, local.z)

func get_voxel_global(global_voxel: Vector3i) -> int:
	# 说明：对外提供的体素查询接口（用于天空系统判断“是否能看到天空”等逻辑）。
	return _sample_voxel_global(global_voxel)

func _sample_skylight_direct_global(global_voxel: Vector3i) -> int:
	var chunk_coord: Vector3i = _voxel_to_chunk_coord(global_voxel)
	var chunk: VoxelChunk = _chunks.get(chunk_coord, null)
	if chunk == null:
		return 15
	var local: Vector3i = global_voxel - chunk_coord * chunk_size
	if local.x < 0 or local.x >= chunk_size or local.z < 0 or local.z >= chunk_size:
		return 15
	var top_y: int = chunk.get_column_top_occluder_y(local.x, local.z)
	if top_y == _MIN_I32:
		return 15
	return 15 if global_voxel.y > top_y else 0

func _sample_skylight_global(global_voxel: Vector3i) -> int:
	var chunk_coord: Vector3i = _voxel_to_chunk_coord(global_voxel)
	var chunk: VoxelChunk = _chunks.get(chunk_coord, null)
	if chunk == null:
		return 15
	if not chunk.has_method("is_skylight_cache_valid") or not bool(chunk.call("is_skylight_cache_valid")):
		return _sample_skylight_direct_global(global_voxel)
	var local: Vector3i = global_voxel - chunk_coord * chunk_size
	if local.x < 0 or local.x >= chunk_size or local.z < 0 or local.z >= chunk_size:
		return 15
	if local.y < 0 or local.y >= chunk_size:
		return _sample_skylight_direct_global(global_voxel)
	return int(chunk.call("get_skylight_local", local.x, local.y, local.z))

func set_voxel_global(global_voxel: Vector3i, voxel_type: int) -> void:
	_set_voxel_global_internal(global_voxel, voxel_type, true)

func _set_voxel_global_internal(global_voxel: Vector3i, voxel_type: int, schedule_sand: bool) -> void:
	var chunk_coord: Vector3i = _voxel_to_chunk_coord(global_voxel)
	var chunk: VoxelChunk = _chunks.get(chunk_coord, null)
	if chunk == null:
		chunk = _create_chunk(chunk_coord, false)

	var local: Vector3i = global_voxel - chunk_coord * chunk_size
	chunk.set_voxel_local(local.x, local.y, local.z, voxel_type)

	# 只重建“必需的”区块网格：自身 + 边界邻居（如果修改发生在边界）
	_mark_chunk_dirty(chunk_coord)
	if local.x == 0:
		_mark_chunk_dirty(chunk_coord + Vector3i(-1, 0, 0))
	elif local.x == chunk_size - 1:
		_mark_chunk_dirty(chunk_coord + Vector3i(1, 0, 0))
	if local.z == 0:
		_mark_chunk_dirty(chunk_coord + Vector3i(0, 0, -1))
	elif local.z == chunk_size - 1:
		_mark_chunk_dirty(chunk_coord + Vector3i(0, 0, 1))

	if schedule_sand and not _suppress_sand_schedule:
		_try_start_falling_sand_at(global_voxel)
		_try_start_falling_sand_at(global_voxel + Vector3i(0, 1, 0))

func _try_start_falling_sand_at(global_voxel: Vector3i) -> void:
	if global_voxel.y <= 0:
		return
	if _sample_voxel_global(global_voxel) != VoxelTypes.VoxelType.SAND:
		return
	var below: Vector3i = global_voxel + Vector3i(0, -1, 0)
	if _sample_voxel_global(below) != VoxelTypes.VoxelType.AIR:
		return

	var max_h: int = 256
	var h: int = 1
	while h < max_h:
		var p: Vector3i = global_voxel + Vector3i(0, h, 0)
		if _sample_voxel_global(p) != VoxelTypes.VoxelType.SAND:
			break
		h += 1

	_suppress_sand_schedule = true
	var yi: int = 0
	while yi < h:
		_set_voxel_global_internal(global_voxel + Vector3i(0, yi, 0), VoxelTypes.VoxelType.AIR, false)
		yi += 1
	_suppress_sand_schedule = false

	_spawn_falling_block(global_voxel, VoxelTypes.VoxelType.SAND, h)

func _spawn_falling_block(global_voxel: Vector3i, block_id: int, height_blocks: int = 1) -> void:
	if FallingBlockScene == null:
		return
	var n: Node = FallingBlockScene.instantiate()
	if n == null:
		return
	if n.has_method("set"):
		n.set("block_id", block_id)
		n.set("voxel_scale", voxel_scale)
		n.set("height_blocks", max(1, height_blocks))
	add_child(n)
	if n is Node3D:
		var h: int = max(1, height_blocks)
		var cy: float = (global_voxel.y + 0.5) + (h - 1) * 0.5
		(n as Node3D).global_position = Vector3(global_voxel.x + 0.5, cy, global_voxel.z + 0.5) * voxel_scale

func _rebuild_chunk_and_neighbors(chunk_coord: Vector3i, local: Vector3i) -> void:
	var chunk: VoxelChunk = _chunks.get(chunk_coord, null)
	if chunk != null:
		chunk.rebuild_mesh(_sample_voxel_global, Callable(self, "_sample_skylight_global"))

	# 如果修改发生在边界，邻居 Chunk 的可见面也会变化，需要重建
	if local.x == 0:
		_rebuild_chunk(chunk_coord + Vector3i(-1, 0, 0))
	elif local.x == chunk_size - 1:
		_rebuild_chunk(chunk_coord + Vector3i(1, 0, 0))

	if local.z == 0:
		_rebuild_chunk(chunk_coord + Vector3i(0, 0, -1))
	elif local.z == chunk_size - 1:
		_rebuild_chunk(chunk_coord + Vector3i(0, 0, 1))

func _rebuild_chunk(chunk_coord: Vector3i) -> void:
	var chunk: VoxelChunk = _chunks.get(chunk_coord, null)
	if chunk == null:
		return
	chunk.rebuild_mesh(_sample_voxel_global, Callable(self, "_sample_skylight_global"))

func _rebuild_all_chunks_mesh() -> void:
	for c in _chunks.values():
		var chunk: VoxelChunk = c as VoxelChunk
		if chunk != null:
			chunk.rebuild_mesh(_sample_voxel_global, Callable(self, "_sample_skylight_global"))

func _voxel_to_chunk_coord(global_voxel: Vector3i) -> Vector3i:
	return Vector3i(
		_floor_div(global_voxel.x, chunk_size),
		0,
		_floor_div(global_voxel.z, chunk_size)
	)

func _floor_div(a: int, b: int) -> int:
	# floori 可正确处理负数下取整；这里用 / 保持浮点除法，避免使用 float(...) 转换
	return floori(a / (b * 1.0))

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

	# 关键修复：当射线起点恰好落在体素边界（例如 pos.z 是整数）时，
	# 不同方向（step 正负）会导致 floor() 归属的体素不同，从而出现“转头后放置/命中错一格”的方向性 bug。
	# 处理规则：如果正好在边界且沿负方向行进，则把起点归属到“边界后方”的体素。
	var eps: float = 0.000001
	if absf(pos.x - floorf(pos.x)) < eps and step_x < 0:
		voxel.x -= 1
	if absf(pos.y - floorf(pos.y)) < eps and step_y < 0:
		voxel.y -= 1
	if absf(pos.z - floorf(pos.z)) < eps and step_z < 0:
		voxel.z -= 1

	var t_delta_x: float = INF
	var t_delta_y: float = INF
	var t_delta_z: float = INF
	if absf(dir.x) > 0.000001:
		t_delta_x = absf(1.0 / dir.x)
	if absf(dir.y) > 0.000001:
		t_delta_y = absf(1.0 / dir.y)
	if absf(dir.z) > 0.000001:
		t_delta_z = absf(1.0 / dir.z)

	var next_x: float = (voxel.x + (1 if step_x > 0 else 0)) * 1.0
	var next_y: float = (voxel.y + (1 if step_y > 0 else 0)) * 1.0
	var next_z: float = (voxel.z + (1 if step_z > 0 else 0)) * 1.0

	var t_max_x: float = INF
	var t_max_y: float = INF
	var t_max_z: float = INF
	if absf(dir.x) > 0.000001:
		t_max_x = (next_x - pos.x) / dir.x
	if absf(dir.y) > 0.000001:
		t_max_y = (next_y - pos.y) / dir.y
	if absf(dir.z) > 0.000001:
		t_max_z = (next_z - pos.z) / dir.z

	var max_t: float = max_distance / voxel_scale
	var max_steps: int = max(1, ceili(max_t * 3.0))

	# 起点就位于实体体素内部（极少见，但要兼容）
	var initial_type: int = _sample_voxel_global(voxel)
	if BlockRegistryScript.is_solid(initial_type):
		return {
			"hit": true,
			"voxel": voxel,
			"previous": voxel,
			"normal": Vector3i.ZERO,
			"type": initial_type,
		}

	for _i in range(max_steps):
		var hit_normal: Vector3i = Vector3i.ZERO

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

		var vt: int = _sample_voxel_global(voxel)
		if BlockRegistryScript.is_solid(vt):
			# 放置方块的目标格子应当是“命中体素沿命中法线方向相邻的格子”（也就是射线进入该体素前所在的空气格子）
			return {
				"hit": true,
				"voxel": voxel,
				"previous": voxel + hit_normal,
				"normal": hit_normal,
				"type": vt,
			}

	return {"hit": false}
	# --- INDEPENDENT DESIGN END ---

func _sign_int_from_float(v: float) -> int:
	if v > 0.0:
		return 1
	if v < 0.0:
		return -1
	return 0

func _ensure_atlas_ready() -> void:
	var base_paths: Array[String] = _collect_atlas_base_paths()
	var mapping: Dictionary = _compute_atlas_mapping(base_paths)
	BlockRegistryScript.apply_atlas_mapping(mapping)

	if atlas_texture == null:
		if ResourceLoader.exists(_PREBUILT_ATLAS_PNG_PATH):
			atlas_texture = load(_PREBUILT_ATLAS_PNG_PATH)
		elif OS.has_feature("editor"):
			atlas_texture = _build_and_save_prebuilt_atlas_png(base_paths)
			_apply_mapping_and_save_blocks(mapping)
		else:
			push_error("缺少预构建方块图集（%s）。请在编辑器里运行一次项目以生成图集 PNG，然后再导出。" % _PREBUILT_ATLAS_PNG_PATH)

	_tile_pixels = max(1, _tile_pixels)
	if atlas_texture != null:
		var w: int = atlas_texture.get_width()
		var h: int = atlas_texture.get_height()
		atlas_columns = max(1, floori(w / (_tile_pixels * 1.0)))
		atlas_rows = max(1, floori(h / (_tile_pixels * 1.0)))

func _apply_mapping_and_save_blocks(mapping: Dictionary) -> void:
	if not OS.has_feature("editor"):
		return
	if mapping.is_empty():
		return
	var paths: PackedStringArray = BlockRegistryScript.get_known_block_paths()
	for res_path in paths:
		var b: Resource = load(res_path)
		if b == null:
			continue
		var base: String = res_path.get_file().get_basename()
		if base == "":
			continue
		var top_path: String = "res://resources/textures/block/" + base + "_top.png"
		var side_path: String = "res://resources/textures/block/" + base + "_side.png"
		var bottom_path: String = "res://resources/textures/block/" + base + "_bottom.png"
		var main_path: String = "res://resources/textures/block/" + base + ".png"

		var use_top: String = top_path if mapping.has(top_path) else main_path
		var use_side: String = side_path if mapping.has(side_path) else main_path
		var use_bottom: String = bottom_path if mapping.has(bottom_path) else use_top
		if base == "grass_block":
			var dirt_path: String = "res://resources/textures/block/dirt.png"
			if mapping.has(dirt_path):
				use_bottom = dirt_path

		if mapping.has(use_top):
			b.set("tile_top", mapping[use_top])
		if mapping.has(use_side):
			b.set("tile_side", mapping[use_side])
		if mapping.has(use_bottom):
			b.set("tile_bottom", mapping[use_bottom])
		ResourceSaver.save(b, res_path)

func _build_and_save_prebuilt_atlas_png(base_paths: Array[String]) -> Texture2D:
	var result: Dictionary = AtlasBuilderScript.build_block_atlas_image_from_paths(base_paths)
	if result.is_empty():
		return null
	var img: Image = result.get("image", null)
	if img == null:
		return null
	var abs_path: String = ProjectSettings.globalize_path(_PREBUILT_ATLAS_PNG_PATH)
	var err: Error = img.save_png(abs_path)
	if err != OK:
		push_error("保存方块图集 PNG 失败：%s（err=%s）" % [_PREBUILT_ATLAS_PNG_PATH, str(err)])
		return null
	return ImageTexture.create_from_image(img)

func _compute_atlas_mapping(base_paths: Array[String]) -> Dictionary:
	var mapping: Dictionary = {}
	var cols: int = base_paths.size()
	var i: int = 0
	while i < cols:
		var p: String = base_paths[i]
		mapping[p] = Vector2i(i, 0)
		var overlay_path: String = p.get_basename() + "_overlay.png"
		if ResourceLoader.exists(overlay_path):
			mapping[overlay_path] = Vector2i(i, 1)
		i += 1
	return mapping

func _collect_atlas_base_paths() -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	var paths: PackedStringArray = BlockRegistryScript.get_known_block_paths()
	for res_path in paths:
		var base: String = res_path.get_file().get_basename()
		if base == "":
			continue
		var candidates: Array[String] = [
			"res://resources/textures/block/" + base + ".png",
			"res://resources/textures/block/" + base + "_top.png",
			"res://resources/textures/block/" + base + "_side.png",
			"res://resources/textures/block/" + base + "_bottom.png",
		]
		for p in candidates:
			if seen.has(p):
				continue
			if not ResourceLoader.exists(p):
				continue
			seen[p] = true
			out.push_back(p)
	out.sort()
	return out

func break_voxel_at_ray(origin: Vector3, direction: Vector3) -> bool:
	var result: Dictionary = raycast_voxel(origin, direction, max_interact_distance)
	if not result.get("hit", false):
		return false
	var vt: int = result.get("type", VoxelTypes.VoxelType.AIR)
	if vt == VoxelTypes.VoxelType.BEDROCK:
		return false
	set_voxel_global(result["voxel"], VoxelTypes.VoxelType.AIR)
	_spawn_item_drop(vt, 1, (Vector3(result["voxel"]) + Vector3(0.5, 0.5, 0.5)) * voxel_scale)
	return true

func place_voxel_at_ray(origin: Vector3, direction: Vector3, voxel_type: int) -> bool:
	var result: Dictionary = raycast_voxel(origin, direction, max_interact_distance)
	if not result.get("hit", false):
		return false
	var target: Vector3i = result["previous"]
	# 防止射线边界误差导致 previous 仍然是实体体素：只允许放在空气中
	if BlockRegistryScript.is_solid(_sample_voxel_global(target)):
		return false
	set_voxel_global(target, voxel_type)
	return true

func spawn_item_drop(item_id: int, count: int, world_pos: Vector3) -> Node:
	return _spawn_item_drop(item_id, count, world_pos)

func _spawn_item_drop(item_id: int, count: int, world_pos: Vector3) -> Node:
	# 说明：只对“实体方块”生成掉落（空气不掉落）。透明/液体等后续可在 BlockData 扩展规则。
	if not BlockRegistryScript.is_solid(item_id):
		return null
	if ItemDropScene == null:
		return null
	var drop: Node = ItemDropScene.instantiate()
	if drop == null:
		return null
	drop.set("item_id", item_id)
	drop.set("count", count)
	add_child(drop)
	if drop is Node3D:
		(drop as Node3D).global_position = world_pos
	return drop
