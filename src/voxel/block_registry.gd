extends RefCounted
class_name BlockRegistry

static var _blocks: Dictionary = {}

static func _ensure_loaded() -> void:
	if not _blocks.is_empty():
		return

	_blocks[VoxelTypes.VoxelType.AIR] = null
	_blocks[VoxelTypes.VoxelType.GRASS] = load("res://resources/blocks/grass_block.tres")
	_blocks[VoxelTypes.VoxelType.DIRT] = load("res://resources/blocks/dirt.tres")
	_blocks[VoxelTypes.VoxelType.STONE] = load("res://resources/blocks/stone.tres")

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

static func icon_for(id: int) -> Texture2D:
	var data: Resource = get_block(id)
	if data == null:
		return null
	return data.get("icon_texture")
