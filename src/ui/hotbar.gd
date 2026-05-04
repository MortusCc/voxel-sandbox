extends Control

const BlockRegistryScript := preload("res://src/voxel/block_registry.gd")

@onready var _slots: HBoxContainer = $Slots

var _selected_style: StyleBoxFlat
var _unselected_style: StyleBoxFlat


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
			icon.texture = BlockRegistryScript.icon_for(items[i])

		var selected: bool = i == selected_index
		slot.color = Color(0.12, 0.12, 0.12, 0.65) if selected else Color(0.05, 0.05, 0.05, 0.5)

		var border: Panel = slot.get_node_or_null("Border") as Panel
		if border != null:
			border.add_theme_stylebox_override("panel", _selected_style if selected else _unselected_style)

		_set_slot_count_text(slot, count)


func set_stacks(stacks: Array, selected_index: int) -> void:
	# stacks[i] 期望包含：{ "item_id": int, "count": int }
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
			icon.texture = BlockRegistryScript.icon_for(item_id)

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
