extends RefCounted
class_name AtlasBuilder

## ============================================================
## 纹理图集构建器 (AtlasBuilder) — 运行时拼接多张方块纹理为一张大图
## ============================================================
## 职责：
##   1. 扫描纹理目录，收集所有基础贴图
##   2. 逐张读取 Image → 统一格式(RGBA8) → 统一尺寸 → blit_rect 拼接到图集
##   3. 同时检测并拼接覆盖层贴图（_overlay.png）到第二行
##   4. 生成 ImageTexture 供 Shader 采样
##   5. 返回 tile→图集坐标的映射表（mapping）
##
## 图集布局：
##   第0行：基础纹理（grass_block_top, grass_block_side, dirt, stone, ...）
##   第1行：覆盖层纹理（grass_block_side_overlay, ...）
##   列数 = 基础贴图数量, 行数 = 2
##
## 三个变体函数：
##   - build_block_atlas(dir): 编辑器目录扫描 + 导出后生成的完整流程
##   - build_block_atlas_from_paths(paths): 按指定路径列表构建
##   - build_block_atlas_image_from_paths(paths): 同上但只返回 Image（用于保存PNG）
## ============================================================

static func build_block_atlas(block_textures_dir: String) -> Dictionary:
	var base_paths: Array[String] = []

	var dir: DirAccess = DirAccess.open(block_textures_dir)
	if dir == null:
		return {}

	dir.list_dir_begin()
	while true:
		var name: String = dir.get_next()
		if name == "":
			break
		if dir.current_is_dir():
			continue
		if not name.ends_with(".png"):
			continue
		if name.ends_with(".import"):
			continue
		if name.ends_with("_overlay.png"):
			continue
		base_paths.push_back(block_textures_dir.path_join(name))
	dir.list_dir_end()

	base_paths.sort()
	if base_paths.is_empty():
		return {}

	var first_img: Image = _get_image(base_paths[0])
	if first_img == null:
		return {}

	var tile_px: int = first_img.get_width()
	if tile_px <= 0:
		return {}

	var cols: int = base_paths.size()
	var rows: int = 2

	var atlas: Image = Image.create(tile_px * cols, tile_px * rows, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0.0, 0.0, 0.0, 0.0))

	var mapping: Dictionary = {}

	for i in range(cols):
		var base_path: String = base_paths[i]
		var img: Image = _get_image(base_path)
		if img == null:
			continue
		img = _normalize(img, tile_px, tile_px)
		atlas.blit_rect(img, Rect2i(0, 0, tile_px, tile_px), Vector2i(i * tile_px, 0))
		mapping[base_path] = Vector2i(i, 0)

		var base_name: String = base_path.get_file().get_basename()
		var overlay_path: String = block_textures_dir.path_join(base_name + "_overlay.png")
		var overlay_img: Image = _get_image(overlay_path)
		if overlay_img != null:
			overlay_img = _normalize(overlay_img, tile_px, tile_px)
			atlas.blit_rect(overlay_img, Rect2i(0, 0, tile_px, tile_px), Vector2i(i * tile_px, tile_px))
			mapping[overlay_path] = Vector2i(i, 1)

	return {
		"texture": ImageTexture.create_from_image(atlas),
		"columns": cols,
		"rows": rows,
		"tile_pixels": tile_px,
		"mapping": mapping,
	}

static func build_block_atlas_from_paths(base_paths: Array[String]) -> Dictionary:
	var paths: Array[String] = base_paths.duplicate()
	paths.sort()
	if paths.is_empty():
		return {}

	var first_img: Image = _get_image(paths[0])
	if first_img == null:
		return {}

	var tile_px: int = first_img.get_width()
	if tile_px <= 0:
		return {}

	var cols: int = paths.size()
	var rows: int = 2

	var atlas: Image = Image.create(tile_px * cols, tile_px * rows, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0.0, 0.0, 0.0, 0.0))

	var mapping: Dictionary = {}

	for i in range(cols):
		var base_path: String = paths[i]
		var img: Image = _get_image(base_path)
		if img == null:
			continue
		img = _normalize(img, tile_px, tile_px)
		atlas.blit_rect(img, Rect2i(0, 0, tile_px, tile_px), Vector2i(i * tile_px, 0))
		mapping[base_path] = Vector2i(i, 0)

		var overlay_path: String = base_path.get_basename() + "_overlay.png"
		var overlay_img: Image = _get_image(overlay_path)
		if overlay_img != null:
			overlay_img = _normalize(overlay_img, tile_px, tile_px)
			atlas.blit_rect(overlay_img, Rect2i(0, 0, tile_px, tile_px), Vector2i(i * tile_px, tile_px))
			mapping[overlay_path] = Vector2i(i, 1)

	return {
		"texture": ImageTexture.create_from_image(atlas),
		"columns": cols,
		"rows": rows,
		"tile_pixels": tile_px,
		"mapping": mapping,
	}

static func build_block_atlas_image_from_paths(base_paths: Array[String]) -> Dictionary:
	var paths: Array[String] = base_paths.duplicate()
	paths.sort()
	if paths.is_empty():
		return {}

	var first_img: Image = _get_image(paths[0])
	if first_img == null:
		return {}

	var tile_px: int = first_img.get_width()
	if tile_px <= 0:
		return {}

	var cols: int = paths.size()
	var rows: int = 2

	var atlas: Image = Image.create(tile_px * cols, tile_px * rows, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0.0, 0.0, 0.0, 0.0))

	for i in range(cols):
		var base_path: String = paths[i]
		var img: Image = _get_image(base_path)
		if img == null:
			continue
		img = _normalize(img, tile_px, tile_px)
		atlas.blit_rect(img, Rect2i(0, 0, tile_px, tile_px), Vector2i(i * tile_px, 0))

		var overlay_path: String = base_path.get_basename() + "_overlay.png"
		var overlay_img: Image = _get_image(overlay_path)
		if overlay_img != null:
			overlay_img = _normalize(overlay_img, tile_px, tile_px)
			atlas.blit_rect(overlay_img, Rect2i(0, 0, tile_px, tile_px), Vector2i(i * tile_px, tile_px))

	return {
		"image": atlas,
		"columns": cols,
		"rows": rows,
		"tile_pixels": tile_px,
	}


static func _get_image(path: String) -> Image:
	if not ResourceLoader.exists(path):
		return null
	var tex: Texture2D = load(path)
	if tex == null:
		return null
	return tex.get_image()


static func _normalize(img: Image, w: int, h: int) -> Image:
	var out: Image = img.duplicate()
	if out.get_format() != Image.FORMAT_RGBA8:
		out.convert(Image.FORMAT_RGBA8)
	if out.get_width() != w or out.get_height() != h:
		out.resize(w, h, Image.INTERPOLATE_NEAREST)
	return out
