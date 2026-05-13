extends Camera3D
class_name FlyCamera

## ============================================================
## 自由飞行相机 (FlyCamera) — 旧版调试用飞行相机（已被 PlayerController 取代）
## ============================================================
## 说明：此脚本为开发早期的自由飞行相机，支持WASD+空格/Ctrl飞行移动和鼠标视角。
## 当前版本的主玩家控制器为 PlayerController (CharacterBody3D, 支持碰撞/重力/飞行双模式)。
## 此文件保留用于可能的回退对比测试。
## ============================================================

@export var move_speed: float = 8.0
@export var sprint_multiplier: float = 2.5
@export var mouse_sensitivity: float = 0.0025
@export var voxel_world_path: NodePath

var _yaw: float = 0.0
var _pitch: float = 0.0
var _mouse_captured: bool = true

func _ready() -> void:
	_mouse_captured = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_yaw = rotation.y
	_pitch = rotation.x

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_mouse_captured = not _mouse_captured
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE)
		return

	if _mouse_captured and event is InputEventMouseMotion:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
		rotation = Vector3(_pitch, _yaw, 0.0)

	if event.is_action_pressed("break_block"):
		_try_break_block()
	elif event.is_action_pressed("place_block"):
		_try_place_block()

func _physics_process(delta: float) -> void:
	var input_dir: Vector3 = Vector3.ZERO

	if Input.is_key_pressed(KEY_W):
		input_dir += -global_transform.basis.z
	if Input.is_key_pressed(KEY_S):
		input_dir += global_transform.basis.z
	if Input.is_key_pressed(KEY_A):
		input_dir += -global_transform.basis.x
	if Input.is_key_pressed(KEY_D):
		input_dir += global_transform.basis.x
	if Input.is_key_pressed(KEY_E):
		input_dir += global_transform.basis.y
	if Input.is_key_pressed(KEY_Q):
		input_dir += -global_transform.basis.y

	if input_dir.length() > 0.0001:
		input_dir = input_dir.normalized()

	var speed: float = move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= sprint_multiplier

	global_position += input_dir * speed * delta

func _try_break_block() -> void:
	var world: Node = get_node_or_null(voxel_world_path)
	if world == null:
		return

	var origin: Vector3 = global_position
	var dir: Vector3 = -global_transform.basis.z
	if world.has_method("break_voxel_at_ray"):
		world.call("break_voxel_at_ray", origin, dir)

func _try_place_block() -> void:
	var world: Node = get_node_or_null(voxel_world_path)
	if world == null:
		return

	var origin: Vector3 = global_position
	var dir: Vector3 = -global_transform.basis.z
	if world.has_method("place_voxel_at_ray"):
		world.call("place_voxel_at_ray", origin, dir, VoxelTypes.VoxelType.DIRT)
