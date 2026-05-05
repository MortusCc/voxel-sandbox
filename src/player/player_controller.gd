extends CharacterBody3D
class_name PlayerController

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

@export var item_magnet_radius: float = 1.0
@export var item_magnet_drop_grace_seconds: float = 1.0
@export var item_magnet_target_height: float = 0.15

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
var _hotbar_selected_index: int = 0
var _hotbar_item_ids: PackedInt32Array = PackedInt32Array()
var _hotbar_counts: PackedInt32Array = PackedInt32Array()
var _cached_camera: Camera3D
var _cached_world: Node
var _item_magnet: Area3D

func _ready() -> void:
	_ensure_input_actions()
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
	_ensure_item_magnet()
	_init_hotbar()

func _ensure_input_actions() -> void:
	# 作用：统一把“移动/疾跑/飞行下落”等按键放到 InputMap 里，后续可在 Project Settings 里自由改键。
	# 说明：只在缺失时补齐，不会覆盖你已经在项目里配置过的输入映射。
	_ensure_key_action("move_forward", KEY_W)
	_ensure_key_action("move_back", KEY_S)
	_ensure_key_action("move_left", KEY_A)
	_ensure_key_action("move_right", KEY_D)
	_ensure_key_action("sprint", KEY_SHIFT)
	_ensure_key_action("fly_down", KEY_CTRL)
	_ensure_key_action("jump", KEY_SPACE)
	_ensure_key_action("drop_item", KEY_Q)

func _ensure_key_action(action_name: StringName, keycode: Key) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)

	for ev in InputMap.action_get_events(action_name):
		if ev is InputEventKey and (ev as InputEventKey).keycode == keycode:
			return

	var e: InputEventKey = InputEventKey.new()
	e.keycode = keycode
	InputMap.action_add_event(action_name, e)

func _ensure_item_magnet() -> void:
	# 作用：统一由玩家控制“吸附范围”。任何掉落物进入该范围后，开始飞向玩家并拾取。
	if _item_magnet != null and is_instance_valid(_item_magnet):
		_update_item_magnet_radius()
		return

	_item_magnet = Area3D.new()
	_item_magnet.name = "ItemMagnet"
	_item_magnet.collision_layer = 0
	_item_magnet.collision_mask = 4
	add_child(_item_magnet)

	var cs: CollisionShape3D = CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	var s: SphereShape3D = SphereShape3D.new()
	s.radius = max(0.1, item_magnet_radius)
	cs.shape = s
	_item_magnet.add_child(cs)

	_item_magnet.body_entered.connect(_on_item_magnet_body_entered)

func _update_item_magnet_radius() -> void:
	if _item_magnet == null or not is_instance_valid(_item_magnet):
		return
	var cs: CollisionShape3D = _item_magnet.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs == null:
		return
	var s: SphereShape3D = cs.shape as SphereShape3D
	if s == null:
		return
	s.radius = max(0.1, item_magnet_radius)

func _on_item_magnet_body_entered(body: Node) -> void:
	if body == null:
		return
	if body.has_method("start_attract"):
		body.set("attract_target_height", item_magnet_target_height)
		body.call("start_attract", self)

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
		if event.keycode == KEY_Q:
			_try_drop_selected_one()

	if event is InputEventKey and event.pressed and not event.echo:
		_try_select_hotbar_by_number_key(event.keycode)

	if event is InputEventMouseButton and event.pressed:
		_try_select_hotbar_by_wheel(event.button_index)

func _physics_process(delta: float) -> void:
	_handle_interaction_input()
	var xform_basis: Basis = global_transform.basis
	var move_input: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	# 说明：Input.get_vector 的第三/第四个参数语义是 up/down（上为 -1，下为 +1）。
	# 在 3D 里，Basis.z 指向“后方”，Basis.-z 指向“前方”。
	# 因此这里直接用 Basis.z * y：W(上,-1) => -z(前)，S(下,+1) => +z(后)。
	var input_dir: Vector3 = (xform_basis.x * move_input.x) + (xform_basis.z * move_input.y)
	if input_dir.length() > 0.0001:
		input_dir = input_dir.normalized()

	if _fly_mode:
		var fly_h_speed: float = fly_speed
		if Input.is_action_pressed("sprint"):
			fly_h_speed *= sprint_multiplier

		velocity.x = input_dir.x * fly_h_speed
		velocity.z = input_dir.z * fly_h_speed

		var v: float = 0.0
		if Input.is_action_pressed("jump"):
			v += fly_vertical_speed
		if Input.is_action_pressed("fly_down"):
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
	if Input.is_action_pressed("sprint"):
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

	var place_type: int = _get_selected_place_type()
	if place_type == VoxelTypes.VoxelType.AIR:
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

	if world.has_method("place_voxel_at_ray"):
		var placed: bool = world.call("place_voxel_at_ray", origin, dir, place_type)
		if placed:
			_consume_selected_one()

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
	_hotbar_selected_index = clampi(_hotbar_selected_index, 0, 8)
	_hotbar_item_ids.resize(9)
	_hotbar_counts.resize(9)
	for i in range(9):
		_hotbar_item_ids[i] = VoxelTypes.VoxelType.AIR
		_hotbar_counts[i] = 0

	# 说明：初始给三种方块各一组，便于测试拾取/放置/堆叠。
	_hotbar_item_ids[0] = VoxelTypes.VoxelType.DIRT
	_hotbar_counts[0] = 32
	_hotbar_item_ids[1] = VoxelTypes.VoxelType.GRASS
	_hotbar_counts[1] = 32
	_hotbar_item_ids[2] = VoxelTypes.VoxelType.STONE
	_hotbar_counts[2] = 32
	_hotbar_item_ids[3] = 4
	_hotbar_counts[3] = 32
	_hotbar_item_ids[4] = 5
	_hotbar_counts[4] = 32
	_hotbar_item_ids[5] = VoxelTypes.VoxelType.GLASS
	_hotbar_counts[5] = 32
	_hotbar_item_ids[6] = VoxelTypes.VoxelType.SAND
	_hotbar_counts[6] = 32

	_refresh_hotbar_ui()

func _get_selected_place_type() -> int:
	_hotbar_selected_index = clampi(_hotbar_selected_index, 0, 8)
	if _hotbar_counts.size() != 9:
		return VoxelTypes.VoxelType.AIR
	if _hotbar_counts[_hotbar_selected_index] <= 0:
		return VoxelTypes.VoxelType.AIR
	return _hotbar_item_ids[_hotbar_selected_index]

func _try_select_hotbar_by_number_key(keycode: Key) -> void:
	if keycode < KEY_1 or keycode > KEY_9:
		return
	var idx: int = keycode - KEY_1
	_select_hotbar_index(idx)

func _try_select_hotbar_by_wheel(button_index: MouseButton) -> void:
	if button_index == MOUSE_BUTTON_WHEEL_UP:
		_select_hotbar_index((_hotbar_selected_index + 8) % 9)
	elif button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_select_hotbar_index((_hotbar_selected_index + 1) % 9)

func _select_hotbar_index(index: int) -> void:
	var clamped: int = clampi(index, 0, 8)
	if clamped == _hotbar_selected_index:
		return
	_hotbar_selected_index = clamped
	_refresh_hotbar_ui()

func _refresh_hotbar_ui() -> void:
	var hotbar: Control = _get_hotbar()
	if hotbar == null:
		return
	if _hotbar_item_ids.size() != 9 or _hotbar_counts.size() != 9:
		return
	var stacks: Array = []
	stacks.resize(9)
	for i in range(9):
		stacks[i] = {"item_id": _hotbar_item_ids[i], "count": _hotbar_counts[i]}
	if hotbar.has_method("set_stacks"):
		hotbar.call("set_stacks", stacks, _hotbar_selected_index)
	elif hotbar.has_method("set_items"):
		var items: Array[int] = []
		items.resize(9)
		for i in range(9):
			items[i] = _hotbar_item_ids[i]
		hotbar.call("set_items", items, _hotbar_selected_index)

func pickup_item(item_id: int, count: int) -> int:
	# 返回：剩余未拾取数量；0 表示全部进入快捷栏。
	return _add_to_hotbar(item_id, count)

func _add_to_hotbar(item_id: int, amount: int) -> int:
	if amount <= 0:
		return 0
	if item_id == VoxelTypes.VoxelType.AIR:
		return amount
	if item_id == VoxelTypes.VoxelType.BEDROCK:
		return amount
	if _hotbar_item_ids.size() != 9 or _hotbar_counts.size() != 9:
		return amount

	var remain: int = amount
	var max_stack: int = 64

	for i in range(9):
		if remain <= 0:
			break
		if _hotbar_item_ids[i] == item_id and _hotbar_counts[i] > 0 and _hotbar_counts[i] < max_stack:
			var can_add: int = min(remain, max_stack - _hotbar_counts[i])
			_hotbar_counts[i] += can_add
			remain -= can_add

	for i in range(9):
		if remain <= 0:
			break
		if _hotbar_counts[i] <= 0 or _hotbar_item_ids[i] == VoxelTypes.VoxelType.AIR:
			var put: int = min(remain, max_stack)
			_hotbar_item_ids[i] = item_id
			_hotbar_counts[i] = put
			remain -= put

	if remain != amount:
		_refresh_hotbar_ui()
	return remain

func _consume_selected_one() -> void:
	var slot: int = clampi(_hotbar_selected_index, 0, 8)
	if _hotbar_item_ids.size() != 9 or _hotbar_counts.size() != 9:
		return
	if _hotbar_counts[slot] <= 0:
		return
	_hotbar_counts[slot] -= 1
	if _hotbar_counts[slot] <= 0:
		_hotbar_counts[slot] = 0
		_hotbar_item_ids[slot] = VoxelTypes.VoxelType.AIR
	_refresh_hotbar_ui()

func _try_drop_selected_one() -> void:
	var world: Node = _get_world()
	var cam: Camera3D = _get_camera()
	if world == null or cam == null:
		return
	if not world.has_method("spawn_item_drop"):
		return

	var slot: int = clampi(_hotbar_selected_index, 0, 8)
	if _hotbar_item_ids.size() != 9 or _hotbar_counts.size() != 9:
		return
	var item_id: int = _hotbar_item_ids[slot]
	if item_id == VoxelTypes.VoxelType.AIR or _hotbar_counts[slot] <= 0:
		return
	_hotbar_counts[slot] -= 1
	if _hotbar_counts[slot] <= 0:
		_hotbar_counts[slot] = 0
		_hotbar_item_ids[slot] = VoxelTypes.VoxelType.AIR
	_refresh_hotbar_ui()

	var forward: Vector3 = -cam.global_transform.basis.z
	var dist: float = max(1.2, item_magnet_radius + 0.6)
	var drop_pos: Vector3 = cam.global_position + forward * dist
	var drop: Variant = world.call("spawn_item_drop", item_id, 1, drop_pos)
	if typeof(drop) == TYPE_OBJECT and drop != null:
		if drop.has_method("set_attract_delay"):
			drop.call("set_attract_delay", item_magnet_drop_grace_seconds)
		drop.set("attract_target_height", item_magnet_target_height)
		drop.set("velocity", forward * 6.0 + Vector3.UP * 2.0)

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
