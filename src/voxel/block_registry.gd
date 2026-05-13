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

## 确保方块注册表已加载 — 延迟初始化（首次调用时触发）
## 加载策略：优先扫描目录，失败/结果异常时回退到固定清单
static func _ensure_loaded() -> void:
	if not _blocks.is_empty():
		return  # 已加载，跳过
	# AIR(id=0)始终存在，对应null资源（方便get_block(0)返回null）
	_blocks[VoxelTypes.VoxelType.AIR] = null

	# 尝试扫描 blocks/ 目录，动态发现所有 .tres 方块资源
	var dir: DirAccess = DirAccess.open("res://resources/blocks")
	if dir == null:
		_load_known_blocks()  # 目录不可访问 → 回退固定清单
		return

	dir.list_dir_begin()
	while true:
		var name: String = dir.get_next()
		if name == "":  # 目录遍历结束
			break
		if dir.current_is_dir():
			continue    # 跳过子目录
		if not name.ends_with(".tres"):
			continue    # 只加载 .tres 资源文件

		var path: String = "res://resources/blocks/" + name
		var res: Resource = load(path)  # Godot资源加载（支持 .tres/.res）
		if res == null:
			continue
		var id_value: int = str(res.get("id")).to_int()  # 读取BlockData的id字段
		if id_value <= 0:
			continue  # 无效id
		_blocks[id_value] = res  # 存入字典：id → BlockData资源
	dir.list_dir_end()

	# 导出后 res:// 下的目录枚举可能只返回 *.gd / *.import 等文件，
	# 导致扫描不到任何 .tres，注册表为空 → 所有方块回退到tile(0,0)
	# 若扫描结果异常（只有AIR），回退到固定清单加载
	if _blocks.size() <= 1:
		_load_known_blocks()

	# 若有待应用的图集映射 → 现在应用（atlas_mapping可能在_ensure_loaded之前设置）
	if not _atlas_mapping.is_empty():
		_apply_atlas_mapping_internal(_atlas_mapping)

## 固定清单加载 — 导出版本兜底（不依赖DirAccess目录扫描）
static func _load_known_blocks() -> void:
	for p in _known_block_paths:  # 遍历硬编码的8种方块路径
		var res: Resource = load(p)
		if res == null:
			continue
		var id_value: int = str(res.get("id")).to_int()
		if id_value <= 0:
			continue
		_blocks[id_value] = res
	# 加载完后立即应用已缓存的图集映射
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

## 将图集映射写入BlockData的tile字段 — 关键：建立"纹理路径→图集坐标"的对应关系
## mapping: { "path/to/texture.png": Vector2i(列, 行), ... }
## 为每个BlockData资源推导 top/side/bottom 面对应的纹理路径，再查映射表获取图集坐标
static func _apply_atlas_mapping_internal(mapping: Dictionary) -> void:
	if mapping.is_empty():
		return

	for k in _blocks.keys():
		var b: Resource = _blocks.get(k, null)
		if b == null:
			continue  # AIR(null)

		# 从资源路径提取基础名称，例如 grass_block.tres → "grass_block"
		var res_path: String = b.resource_path
		var base: String = res_path.get_file().get_basename()
		if base == "":
			continue

		# 推导顶/侧/底面的纹理路径（命名约定）
		# grass_block → grass_block_top.png, grass_block_side.png, grass_block_bottom.png
		var top_path: String = "res://resources/textures/block/" + base + "_top.png"
		var side_path: String = "res://resources/textures/block/" + base + "_side.png"
		var bottom_path: String = "res://resources/textures/block/" + base + "_bottom.png"
		# 主纹理（无后缀，兜底用）
		var main_path: String = "res://resources/textures/block/" + base + ".png"

		# 若专用纹理存在 → 使用专用纹理；否则回退到主纹理
		var use_top: String = top_path if mapping.has(top_path) else main_path
		var use_side: String = side_path if mapping.has(side_path) else main_path
		var use_bottom: String = bottom_path if mapping.has(bottom_path) else use_top
		# 特殊规则：草方块底面 = dirt.png（泥土纹理）
		if base == "grass_block":
			var dirt_path: String = "res://resources/textures/block/dirt.png"
			if mapping.has(dirt_path):
				use_bottom = dirt_path

		# 将查到的图集坐标写入BlockData资源的tile字段
		if mapping.has(use_top):
			b.set("tile_top", mapping[use_top])
		if mapping.has(use_side):
			b.set("tile_side", mapping[use_side])
		if mapping.has(use_bottom):
			b.set("tile_bottom", mapping[use_bottom])
