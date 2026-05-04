extends RefCounted
class_name BlockRegistry

static var _blocks: Dictionary = {}
static var _atlas_mapping: Dictionary = {}

static func _ensure_loaded() -> void:
	if not _blocks.is_empty():
		return
	_blocks[VoxelTypes.VoxelType.AIR] = null

	var dir: DirAccess = DirAccess.open("res://resources/blocks")
	if dir == null:
		return

	dir.list_dir_begin()
	while true:
		var name: String = dir.get_next()
		if name == "":
			break
		if dir.current_is_dir():
			continue
		if not name.ends_with(".tres"):
			continue

		var path: String = "res://resources/blocks/" + name
		var res: Resource = load(path)
		if res == null:
			continue
		var id_value: int = str(res.get("id")).to_int()
		if id_value <= 0:
			continue
		_blocks[id_value] = res
	dir.list_dir_end()

	if not _atlas_mapping.is_empty():
		_apply_atlas_mapping_internal(_atlas_mapping)

static func get_block(id: int) -> Resource:
	_ensure_loaded()
	return _blocks.get(id, null)

static func is_solid(id: int) -> bool:
	if id == VoxelTypes.VoxelType.AIR:
		return false
	var data: Resource = get_block(id)
	if data == null:
		return true
	return data.get("solid")

static func occludes_faces(id: int) -> bool:
	if id == VoxelTypes.VoxelType.AIR:
		return false
	var data: Resource = get_block(id)
	if data == null:
		return is_solid(id)
	return data.get("occludes_faces")

static func icon_for(id: int) -> Texture2D:
	var data: Resource = get_block(id)
	if data == null:
		return null
	return data.get("icon_texture")

static func apply_atlas_mapping(mapping: Dictionary) -> void:
	_atlas_mapping = mapping
	_ensure_loaded()
	_apply_atlas_mapping_internal(mapping)

static func _apply_atlas_mapping_internal(mapping: Dictionary) -> void:
	if mapping.is_empty():
		return

	for k in _blocks.keys():
		var b: Resource = _blocks.get(k, null)
		if b == null:
			continue

		var res_path: String = b.resource_path
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
