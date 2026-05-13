extends RefCounted
class_name BlockRegistry

## ============================================================
## 方块注册表 (BlockRegistry) — 方块类型→BlockData资源的映射中心
## ============================================================
## 职责：
##   1. 从 res://resources/blocks/ 目录扫描 .tres 文件加载 BlockData
##   2. 维护 id → Resource 的字典映射（_blocks）
##   3. 提供 is_solid() / occludes_faces() / icon_for() 等便捷查询
##   4. 管理纹理图集映射（_atlas_mapping）：纹理路径→图集tile坐标
##   5. 导出兼容：编辑器枚举失败时回退到固定清单 _known_block_paths
##
## 加载流程：
##   _ensure_loaded() → DirAccess扫描目录 → 逐个load() .tres
##   → 若结果异常（只有AIR）→ _load_known_blocks() 兜底
##   → 若有缓存的 _atlas_mapping → _apply_atlas_mapping_internal()
## ============================================================

static var _blocks: Dictionary = {}
static var _atlas_mapping: Dictionary = {}
static var _known_block_paths: PackedStringArray = PackedStringArray([
	"res://resources/blocks/grass_block.tres",
	"res://resources/blocks/dirt.tres",
	"res://resources/blocks/stone.tres",
	"res://resources/blocks/oak_log.tres",
	"res://resources/blocks/oak_leaves.tres",
	"res://resources/blocks/bedrock.tres",
	"res://resources/blocks/glass.tres",
	"res://resources/blocks/sand.tres",
])

static func _ensure_loaded() -> void:
	if not _blocks.is_empty():
		return
	_blocks[VoxelTypes.VoxelType.AIR] = null

	var dir: DirAccess = DirAccess.open("res://resources/blocks")
	if dir == null:
		_load_known_blocks()
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

	# 说明：导出后 res:// 下的目录枚举可能只返回 *.gd / *.import 等文件，
	# 导致扫描不到任何 .tres，从而注册表为空，最终所有方块都回退到 tile(0,0)。
	# 如果扫描结果异常（只有 AIR），则回退到固定清单加载，确保导出版本稳定。
	if _blocks.size() <= 1:
		_load_known_blocks()

	if not _atlas_mapping.is_empty():
		_apply_atlas_mapping_internal(_atlas_mapping)

static func _load_known_blocks() -> void:
	for p in _known_block_paths:
		var res: Resource = load(p)
		if res == null:
			continue
		var id_value: int = str(res.get("id")).to_int()
		if id_value <= 0:
			continue
		_blocks[id_value] = res
	if not _atlas_mapping.is_empty():
		_apply_atlas_mapping_internal(_atlas_mapping)

static func get_known_block_paths() -> PackedStringArray:
	return _known_block_paths

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
