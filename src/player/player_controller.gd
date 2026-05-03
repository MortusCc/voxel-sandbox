extends CharacterBody3D
class_name PlayerController

const BlockRegistryScript := preload("res://src/voxel/block_registry.gd")

@export var move_speed: float = 6.0
@export var sprint_multiplier: float = 1.8
@export var jump_velocity: float = 6.0
@export var gravity: float = 14.0
@export var mouse_sensitivity: float = 0.0025

@export var camera_path: NodePath
@export var voxel_world_path: NodePath
@export var hotbar_path: NodePath

@export var max_interact_distance: float = 6.0
@export var highlight_update_interval: float = 0.05

@export var fly_speed: float = 6.0
@export var fly_vertical_speed: float = 6.0
@export var double_tap_window_seconds: float = 0.25

var _yaw: float = 0.0
var _pitch: float = 0.0
var _mouse_captured: bool = true
var _fly_mode: bool = false
var _last_space_tap_time_sec: float = -1000.0
var _space_press_time_sec: float = -1000.0
var _space_held: bool = false
var _jump_consumed_on_floor: bool = false
var _was_on_floor: bool = false
var _highlight_timer: float = 0.0
var _hotbar_items: Array[int] = []
var _hotbar_selected_index: int = 0
var _cached_camera: Camera3D
var _cached_world: Node

func _ready() -> void:
	_mouse_captured = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_yaw = rotation.y
	_cached_camera = _resolve_camera()
	_cached_world = _resolve_world()
	if _cached_camera != null:
		_pitch = _cached_camera.rotation.x
	else:
		push_error("PlayerController: 找不到 Camera3D，请检查 Player 的 camera_path 或节点结构。")
	if _cached_world == null:
		push_error("PlayerController: 找不到 VoxelWorld，请检查 Player 的 voxel_world_path 或节点结构。")
	_init_hotbar()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_mouse_captured = not _mouse_captured
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE)
		return

	if _mouse_captured and event is InputEventMouseMotion:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
		rotation = Vector3(0.0, _yaw, 0.0)
		var cam: Camera3D = _get_camera()
		if cam != null:
			cam.rotation = Vector3(_pitch, 0.0, 0.0)

	if event is InputEventKey and event.keycode == KEY_SPACE and not event.echo:
		if event.pressed:
			_on_space_pressed()
		else:
			_on_space_released()

	if event is InputEventKey and event.pressed and not event.echo:
		_try_select_hotbar_by_number_key(event.keycode)

	if event is InputEventMouseButton and event.pressed:
		_try_select_hotbar_by_wheel(event.button_index)

func _physics_process(delta: float) -> void:
	_handle_interaction_input()
	var input_dir: Vector3 = Vector3.ZERO
	var xform_basis: Basis = global_transform.basis

	if Input.is_key_pressed(KEY_W):
		input_dir += -xform_basis.z
	if Input.is_key_pressed(KEY_S):
		input_dir += xform_basis.z
	if Input.is_key_pressed(KEY_A):
		input_dir += -xform_basis.x
	if Input.is_key_pressed(KEY_D):
		input_dir += xform_basis.x

	input_dir.y = 0.0
	if input_dir.length() > 0.0001:
		input_dir = input_dir.normalized()

	if _fly_mode:
		var fly_h_speed: float = fly_speed
		if Input.is_key_pressed(KEY_SHIFT):
			fly_h_speed *= sprint_multiplier

		velocity.x = input_dir.x * fly_h_speed
		velocity.z = input_dir.z * fly_h_speed

		var v: float = 0.0
		if Input.is_key_pressed(KEY_SPACE):
			v += fly_vertical_speed
		if Input.is_key_pressed(KEY_CTRL):
			v -= fly_vertical_speed
		velocity.y = v

		move_and_slide()
		_update_block_highlight(delta)
		return

	var on_floor_before: bool = is_on_floor()
	if on_floor_before and not _was_on_floor:
		_jump_consumed_on_floor = false
	_was_on_floor = on_floor_before

	var speed: float = move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= sprint_multiplier

	velocity.x = input_dir.x * speed
	velocity.z = input_dir.z * speed

	if not on_floor_before:
		velocity.y -= gravity * delta
	else:
		if (not _jump_consumed_on_floor) and _space_held:
			velocity.y = jump_velocity
			_jump_consumed_on_floor = true

	move_and_slide()
	_update_block_highlight(delta)

func _handle_interaction_input() -> void:
	if Input.is_action_just_pressed("break_block"):
		_try_break_block()
	if Input.is_action_just_pressed("place_block"):
		_try_place_block()

func _update_block_highlight(delta: float) -> void:
	_highlight_timer += delta
	if _highlight_timer < highlight_update_interval:
		return
	_highlight_timer = 0.0

	var world: Node = _get_world()
	var cam: Camera3D = _get_camera()
	if world == null or cam == null:
		return
	if not world.has_method("update_block_highlight"):
		return

	var origin: Vector3 = cam.global_position
	var dir: Vector3 = -cam.global_transform.basis.z
	world.call("update_block_highlight", origin, dir)

func _get_camera() -> Camera3D:
	if _cached_camera != null and is_instance_valid(_cached_camera):
		return _cached_camera
	_cached_camera = _resolve_camera()
	return _cached_camera

func _get_world() -> Node:
	if _cached_world != null and is_instance_valid(_cached_world):
		return _cached_world
	_cached_world = _resolve_world()
	return _cached_world

func _resolve_camera() -> Camera3D:
	# 优先使用导出的 NodePath；如果路径失效，则回退为按名称/类型查找，避免场景改动后交互整体失效。
	var cam: Camera3D = null
	if camera_path != NodePath():
		cam = get_node_or_null(camera_path) as Camera3D
	if cam != null:
		return cam
	cam = get_node_or_null("Camera") as Camera3D
	if cam != null:
		return cam
	return _find_first_camera(self)

func _find_first_camera(node: Node) -> Camera3D:
	for child in node.get_children():
		if child is Camera3D:
			return child as Camera3D
		var found: Camera3D = _find_first_camera(child)
		if found != null:
			return found
	return null

func _resolve_world() -> Node:
	# 优先使用导出的 NodePath；如果路径失效，则尝试从父节点/当前场景根节点按名称查找。
	var world: Node = null
	if voxel_world_path != NodePath():
		world = get_node_or_null(voxel_world_path)
	if world != null:
		return world
	if get_parent() != null:
		world = get_parent().get_node_or_null("VoxelWorld")
		if world != null:
			return world
	var root: Node = get_tree().current_scene
	if root != null:
		world = root.get_node_or_null("VoxelWorld")
		if world != null:
			return world
	return null

func _get_hotbar() -> Control:
	if hotbar_path == NodePath():
		return null
	return get_node_or_null(hotbar_path) as Control

func _try_break_block() -> void:
	var world: Node = _get_world()
	var cam: Camera3D = _get_camera()
	if world == null or cam == null:
		return

	var origin: Vector3 = cam.global_position
	var dir: Vector3 = -cam.global_transform.basis.z
	if world.has_method("break_voxel_at_ray"):
		world.call("break_voxel_at_ray", origin, dir)

func _try_place_block() -> void:
	var world: Node = _get_world()
	var cam: Camera3D = _get_camera()
	if world == null or cam == null:
		return

	var origin: Vector3 = cam.global_position
	var dir: Vector3 = -cam.global_transform.basis.z
	if not world.has_method("raycast_voxel"):
		return

	var result: Dictionary = world.call("raycast_voxel", origin, dir, max_interact_distance)
	if not result.get("hit", false):
		return

	var target: Vector3i = result["previous"]
	if _would_place_block_intersect_player(target, world):
		return

	if world.has_method("set_voxel_global"):
		var place_type: int = _get_selected_place_type()
		if place_type == VoxelTypes.VoxelType.AIR:
			return
		world.call("set_voxel_global", target, place_type)

func _on_space_pressed() -> void:
	_space_press_time_sec = Time.get_ticks_msec() / 1000.0
	_space_held = true
	if not _fly_mode and is_on_floor():
		_jump_consumed_on_floor = false

func _on_space_released() -> void:
	var now_sec: float = Time.get_ticks_msec() / 1000.0
	_space_held = false
	var press_duration: float = now_sec - _space_press_time_sec
	if press_duration <= double_tap_window_seconds:
		if now_sec - _last_space_tap_time_sec <= double_tap_window_seconds:
			_fly_mode = not _fly_mode
			velocity.y = 0.0
			_last_space_tap_time_sec = -1000.0
			return
		_last_space_tap_time_sec = now_sec

func _init_hotbar() -> void:
	_hotbar_items = [
		VoxelTypes.VoxelType.DIRT,
		VoxelTypes.VoxelType.GRASS,
		VoxelTypes.VoxelType.STONE,
		VoxelTypes.VoxelType.AIR,
		VoxelTypes.VoxelType.AIR,
		VoxelTypes.VoxelType.AIR,
		VoxelTypes.VoxelType.AIR,
		VoxelTypes.VoxelType.AIR,
		VoxelTypes.VoxelType.AIR,
	]
	_hotbar_selected_index = clampi(_hotbar_selected_index, 0, _hotbar_items.size() - 1)
	_refresh_hotbar_ui()

func _get_selected_place_type() -> int:
	if _hotbar_items.is_empty():
		return VoxelTypes.VoxelType.AIR
	_hotbar_selected_index = clampi(_hotbar_selected_index, 0, _hotbar_items.size() - 1)
	return _hotbar_items[_hotbar_selected_index]

func _try_select_hotbar_by_number_key(keycode: Key) -> void:
	if keycode < KEY_1 or keycode > KEY_9:
		return
	var idx: int = keycode - KEY_1
	_select_hotbar_index(idx)

func _try_select_hotbar_by_wheel(button_index: MouseButton) -> void:
	if _hotbar_items.is_empty():
		return
	if button_index == MOUSE_BUTTON_WHEEL_UP:
		_select_hotbar_index((_hotbar_selected_index + _hotbar_items.size() - 1) % _hotbar_items.size())
	elif button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_select_hotbar_index((_hotbar_selected_index + 1) % _hotbar_items.size())

func _select_hotbar_index(index: int) -> void:
	if _hotbar_items.is_empty():
		return
	var clamped: int = clampi(index, 0, _hotbar_items.size() - 1)
	if clamped == _hotbar_selected_index:
		return
	_hotbar_selected_index = clamped
	_refresh_hotbar_ui()

func _refresh_hotbar_ui() -> void:
	var hotbar: Control = _get_hotbar()
	if hotbar == null:
		return
	var slots: Node = hotbar.get_node_or_null("Slots")
	if slots == null:
		return

	for i in range(min(_hotbar_items.size(), slots.get_child_count())):		
		var slot: ColorRect = slots.get_child(i) as ColorRect
		if slot == null:
			continue
		var icon: TextureRect = slot.get_node_or_null("Icon") as TextureRect
		if icon != null:
			icon.texture = BlockRegistryScript.icon_for(_hotbar_items[i])
		var selected: bool = i == _hotbar_selected_index
		slot.color = Color(0.12, 0.12, 0.12, 0.65) if selected else Color(0.05, 0.05, 0.05, 0.5)

		var border: Panel = slot.get_node_or_null("Border") as Panel
		if border != null:
			var sb: StyleBoxFlat = StyleBoxFlat.new()
			sb.bg_color = Color(0.0, 0.0, 0.0, 0.0)
			sb.border_width_left = 3
			sb.border_width_right = 3
			sb.border_width_top = 3
			sb.border_width_bottom = 3
			sb.border_color = Color(1.0, 0.92, 0.25, 1.0) if selected else Color(0.0, 0.0, 0.0, 0.0)
			border.add_theme_stylebox_override("panel", sb)

func _would_place_block_intersect_player(target_voxel: Vector3i, world: Node) -> bool:
	# 规则：不允许把方块放进玩家当前占据的空间（避免把自己“封进方块里”或导致掉落/穿透）。
	# 允许“跳起来往脚下放方块搭高”：玩家跳起后占据空间上移，脚下目标格子不再相交，因此可放置。
	var voxel_scale_value: float = 1.0
	if world != null:
		voxel_scale_value = world.get("voxel_scale")

	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3.ONE * voxel_scale_value * 0.98

	var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = Transform3D(Basis.IDENTITY, (Vector3(target_voxel) + Vector3(0.5, 0.5, 0.5)) * voxel_scale_value)
	query.collision_mask = 2
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var hits: Array[Dictionary] = space.intersect_shape(query, 8)
	for h in hits:
		var collider: Object = h.get("collider", null)
		if collider == self:
			return true
	return false
