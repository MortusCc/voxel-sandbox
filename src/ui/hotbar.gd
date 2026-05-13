extends Control

## ============================================================
## 快捷栏UI (Hotbar) — 9格物品栏的视觉呈现
## ============================================================
## 职责：
##   1. 显示9格物品槽（ColorRect背景 + TextureRect图标 + Label数量）
##   2. 选中槽高亮（黄色边框 StyleBoxFlat）
##   3. 物品图标获取：优先3D预览纹理（BlockPreviewRenderer），回退静态图标
##   4. 接收 PlayerController 推送的物品数据（set_stacks / set_items）
##   5. 数量显示：>1 时在右下角显示白色数字
##
## 节点结构（期望）：
##   Hotbar (Control)
##   └─ Slots (HBoxContainer)
##       ├─ Slot0 (ColorRect)
##       │   ├─ Icon (TextureRect)
##       │   ├─ Border (Panel)
##       │   └─ Count (Label)
##       ├─ Slot1 ...
##       └─ Slot8 ...
##
## 数据流：PlayerController._refresh_hotbar_ui()
##   → Hotbar.set_stacks([{item_id, count}, ...], selected_index)
##   → 遍历Slots子节点 → 设置图标/边框/数量
## ============================================================

const BlockRegistryScript := preload("res://src/voxel/block_registry.gd")

@onready var _slots: HBoxContainer = $Slots

var _selected_style: StyleBoxFlat
var _unselected_style: StyleBoxFlat
var _preview_renderer: Node
var _preview_connected: bool = false
var _last_stacks: Array = []
var _last_selected_index: int = 0

## 图标内边距占格子尺寸的比例（越大图标越小）
@export var icon_padding_ratio: float = 0.12


func _ready() -> void:
	_ensure_initialized()


func _ensure_initialized() -> void:
	# 说明：PlayerController 的 _ready 可能比 HUD/Hotbar 更早执行，
	# 因此需要支持“Hotbar 尚未 ready 时也能安全 set_items”的延迟初始化。
	if _slots == null:
		_slots = get_node_or_null("Slots") as HBoxContainer

	if _selected_style == null:
		_selected_style = StyleBoxFlat.new()
		_selected_style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		_selected_style.border_width_left = 3
		_selected_style.border_width_right = 3
		_selected_style.border_width_top = 3
		_selected_style.border_width_bottom = 3
		_selected_style.border_color = Color(1.0, 0.92, 0.25, 1.0)

	if _unselected_style == null:
		_unselected_style = StyleBoxFlat.new()
		_unselected_style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		_unselected_style.border_width_left = 3
		_unselected_style.border_width_right = 3
		_unselected_style.border_width_top = 3
		_unselected_style.border_width_bottom = 3
		_unselected_style.border_color = Color(0.0, 0.0, 0.0, 0.0)


func set_items(items: Array[int], selected_index: int) -> void:
	# 作用：由 PlayerController 推送快捷栏内容与选中索引；Hotbar 负责把内容渲染到 UI 上。
	# 好处：UI 更新逻辑集中在一个脚本里，PlayerController 不再依赖 Slot 节点细节，后续扩展“数量/堆叠”也更方便。
	_ensure_initialized()
	if _slots == null:
		return

	var slot_count: int = _slots.get_child_count()
	if slot_count <= 0:
		return

	var max_i: int = min(items.size(), slot_count)
	for i in range(max_i):
		var count: int = 0
		var slot: ColorRect = _slots.get_child(i) as ColorRect
		if slot == null:
			continue

		var icon: TextureRect = slot.get_node_or_null("Icon") as TextureRect
		if icon != null:
			_apply_icon_layout(slot, icon)
			icon.texture = _get_item_icon_texture(items[i])

		var selected: bool = i == selected_index
		slot.color = Color(0.12, 0.12, 0.12, 0.65) if selected else Color(0.05, 0.05, 0.05, 0.5)

		var border: Panel = slot.get_node_or_null("Border") as Panel
		if border != null:
			border.add_theme_stylebox_override("panel", _selected_style if selected else _unselected_style)

		_set_slot_count_text(slot, count)


func set_stacks(stacks: Array, selected_index: int) -> void:
	# stacks[i] 期望包含：{ "item_id": int, "count": int }
	_last_stacks = stacks
	_last_selected_index = selected_index
	_ensure_initialized()
	if _slots == null:
		return

	var slot_count: int = _slots.get_child_count()
	if slot_count <= 0:
		return

	var max_i: int = min(stacks.size(), slot_count)
	for i in range(max_i):
		var slot: ColorRect = _slots.get_child(i) as ColorRect
		if slot == null:
			continue

		var item_id: int = stacks[i].get("item_id", 0)
		var count: int = stacks[i].get("count", 0)

		var icon: TextureRect = slot.get_node_or_null("Icon") as TextureRect
		if icon != null:
			_apply_icon_layout(slot, icon)
			icon.texture = _get_item_icon_texture(item_id)

		var selected: bool = i == selected_index
		slot.color = Color(0.12, 0.12, 0.12, 0.65) if selected else Color(0.05, 0.05, 0.05, 0.5)

		var border: Panel = slot.get_node_or_null("Border") as Panel
		if border != null:
			border.add_theme_stylebox_override("panel", _selected_style if selected else _unselected_style)

		_set_slot_count_text(slot, count)


func _set_slot_count_text(slot: Control, count: int) -> void:
	var label: Label = slot.get_node_or_null("Count") as Label
	if label == null:
		label = Label.new()
		label.name = "Count"
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		label.anchor_left = 0.0
		label.anchor_top = 0.0
		label.anchor_right = 1.0
		label.anchor_bottom = 1.0
		label.offset_left = 2.0
		label.offset_top = 2.0
		label.offset_right = -2.0
		label.offset_bottom = -2.0
		label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
		label.add_theme_font_size_override("font_size", 12)
		slot.add_child(label)

	if count > 1:
		label.text = str(count)
	else:
		label.text = ""


func _get_item_icon_texture(item_id: int) -> Texture2D:
	# 说明：优先使用“实时 3D 渲染的方块预览图”；若尚未渲染完成，则回退到原有 icon_texture，保证 UI 不空白。
	var r: Node = _get_preview_renderer()
	if r != null and r.has_method("request_preview"):
		var t: Texture2D = r.call("request_preview", item_id)
		if t != null:
			return t
	return BlockRegistryScript.icon_for(item_id)


func _apply_icon_layout(slot: Control, icon: TextureRect) -> void:
	var s: Vector2 = slot.size
	var pad: float = floorf(min(s.x, s.y) * clampf(icon_padding_ratio, 0.0, 0.45))
	icon.offset_left = pad
	icon.offset_top = pad
	icon.offset_right = -pad
	icon.offset_bottom = -pad


func _get_preview_renderer() -> Node:
	if _preview_renderer != null and is_instance_valid(_preview_renderer):
		return _preview_renderer
	var root: Node = get_tree().current_scene
	if root != null:
		_preview_renderer = root.get_node_or_null("HUD/BlockPreviewRenderer")
	if _preview_renderer != null and not _preview_connected:
		if _preview_renderer.has_signal("preview_ready"):
			_preview_renderer.connect("preview_ready", Callable(self, "_on_preview_ready"))
			_preview_connected = true
		if _preview_renderer.has_method("clear_cache"):
			_preview_renderer.call("clear_cache")
	return _preview_renderer


func _on_preview_ready(_block_id: int, _texture: Texture2D) -> void:
	# 说明：某个方块预览生成后，重新刷新一次 UI，让已缓存的 Texture 立刻替换掉回退图标。
	if _last_stacks.is_empty():
		return
	set_stacks(_last_stacks, _last_selected_index)
