extends Node3D
class_name VoxelWorld

const BlockRegistryScript := preload("res://src/voxel/block_registry.gd")
const ItemDropScene: PackedScene = preload("res://scenes/item_drop.tscn")

@export var chunk_size: int = 16
@export var atlas_columns: int = 4
@export var atlas_rows: int = 2
@export var voxel_scale: float = 1.0
@export var atlas_texture: Texture2D
@export var max_interact_distance: float = 6.0
@export var highlight_expand: float = 0.0
@export var highlight_thickness: float = 0.02

var _chunks: Dictionary = {}
var _material: ShaderMaterial
var _tile_pixels: int = 16
var _highlight_mesh_instance: MeshInstance3D
var _highlight_mesh: ImmediateMesh
var _highlight_material: StandardMaterial3D
var _highlight_last_voxel: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)

func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = preload("res://shaders/voxel_lit.gdshader")
	if atlas_texture == null:
		atlas_texture = _build_default_atlas_texture()
	_apply_material_settings()

	_create_chunk(Vector3i.ZERO, true)
	_ensure_block_highlight()

func _apply_material_settings() -> void:
	if atlas_texture != null:
		_material.set_shader_parameter("atlas_texture", atlas_texture)
		_material.set_shader_parameter("atlas_rows", atlas_rows * 1.0)

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

func _build_default_atlas_texture() -> Texture2D:
	var top_img: Image = _get_image_from_texture("res://resources/textures/block/grass_block_top.png")
	var side_img: Image = _get_image_from_texture("res://resources/textures/block/grass_block_side.png")
	var side_overlay_img: Image = _get_image_from_texture("res://resources/textures/block/grass_block_side_overlay.png")
	var dirt_img: Image = _get_image_from_texture("res://resources/textures/block/dirt.png")
	var stone_img: Image = _get_image_from_texture("res://resources/textures/block/stone.png")

	if top_img == null or side_img == null or dirt_img == null or stone_img == null:
		return null

	var tile_w: int = top_img.get_width()
	var tile_h: int = top_img.get_height()

	if tile_w <= 0 or tile_h <= 0:
		return null

	_tile_pixels = tile_w

	top_img = _normalize_tile_image(top_img, tile_w, tile_h)
	side_img = _normalize_tile_image(side_img, tile_w, tile_h)
	dirt_img = _normalize_tile_image(dirt_img, tile_w, tile_h)
	stone_img = _normalize_tile_image(stone_img, tile_w, tile_h)
	if side_overlay_img != null:
		side_overlay_img = _normalize_tile_image(side_overlay_img, tile_w, tile_h)

	var atlas: Image = Image.create(tile_w * 4, tile_h * 2, false, Image.FORMAT_RGBA8)

	# 第 0 行：基础纹理（顶/侧/泥土/石头）
	atlas.blit_rect(top_img, Rect2i(0, 0, tile_w, tile_h), Vector2i(tile_w * 0, tile_h * 0))
	atlas.blit_rect(side_img, Rect2i(0, 0, tile_w, tile_h), Vector2i(tile_w * 1, tile_h * 0))
	atlas.blit_rect(dirt_img, Rect2i(0, 0, tile_w, tile_h), Vector2i(tile_w * 2, tile_h * 0))
	atlas.blit_rect(stone_img, Rect2i(0, 0, tile_w, tile_h), Vector2i(tile_w * 3, tile_h * 0))

	# 第 1 行：覆盖层纹理（仅 grass side overlay；其余格子保持透明）
	if side_overlay_img != null:
		atlas.blit_rect(side_overlay_img, Rect2i(0, 0, tile_w, tile_h), Vector2i(tile_w * 1, tile_h * 1))

	return ImageTexture.create_from_image(atlas)

func _get_image_from_texture(path: String) -> Image:
	var tex: Texture2D = load(path)
	if tex == null:
		return null
	var img: Image = tex.get_image()
	if img == null:
		return null
	return img

func _normalize_tile_image(img: Image, tile_w: int, tile_h: int) -> Image:
	var out: Image = img.duplicate()
	if out.get_format() != Image.FORMAT_RGBA8:
		out.convert(Image.FORMAT_RGBA8)
	if out.get_width() != tile_w or out.get_height() != tile_h:
		out.resize(tile_w, tile_h, Image.INTERPOLATE_NEAREST)
	return out

func break_voxel_at_ray(origin: Vector3, direction: Vector3) -> bool:
	var result: Dictionary = raycast_voxel(origin, direction, max_interact_distance)
	if not result.get("hit", false):
		return false
	var vt: int = result.get("type", VoxelTypes.VoxelType.AIR)
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
