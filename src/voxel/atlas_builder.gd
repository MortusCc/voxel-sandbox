extends RefCounted
class_name AtlasBuilder

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


static func _get_image(path: String) -> Image:
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

