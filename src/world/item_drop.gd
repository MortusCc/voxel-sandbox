extends CharacterBody3D

const BlockRegistryScript := preload("res://src/voxel/block_registry.gd")

@export var item_id: int = 0
@export var count: int = 1

@onready var _sprite: Sprite3D = $Sprite3D

@export var gravity: float = 18.0
@export var ground_friction: float = 10.0

@export var attract_accel: float = 35.0
@export var attract_speed: float = 12.0
@export var pickup_distance: float = 0.6
@export var attract_target_height: float = 0.45
@export var attract_delay: float = 0.0

@export var hover_height: float = 0.22
@export var hover_amplitude: float = 0.05
@export var hover_speed: float = 4.0

var _time: float = 0.0
var _target: Node
var _base_sprite_y: float = 0.0
var _attract_delay_left: float = 0.0


func _ready() -> void:
	# 说明：
	# - 掉落物有重力，会落到地面。
	# - 落地后“竖直平面”朝向玩家（绕 Y 轴），并做轻微上下悬浮抖动。
	# - 玩家进入吸附范围后，掉落物会从原地飞向玩家，接近后触发拾取。
	_refresh_visual()
	_base_sprite_y = _sprite.position.y if _sprite != null else 0.0
	_attract_delay_left = max(0.0, attract_delay)
	velocity = Vector3(randf() - 0.5, 1.8, randf() - 0.5) * 1.2


func _physics_process(delta: float) -> void:
	_time += delta
	if _attract_delay_left > 0.0:
		_attract_delay_left = max(0.0, _attract_delay_left - delta)

	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam != null and _sprite != null:
		var to_cam: Vector3 = cam.global_position - global_position
		to_cam.y = 0.0
		if to_cam.length() > 0.0001:
			_sprite.rotation = Vector3(0.0, atan2(to_cam.x, to_cam.z), 0.0)

	if _target != null and is_instance_valid(_target) and _attract_delay_left <= 0.0:
		var target_pos: Vector3 = (_target as Node3D).global_position + Vector3.UP * attract_target_height if _target is Node3D else global_position
		var to_target: Vector3 = target_pos - global_position
		var d: float = to_target.length()
		if d <= pickup_distance:
			_try_pickup(_target)
			return

		var dir: Vector3 = to_target / max(0.0001, d)
		var desired_vel: Vector3 = dir * min(attract_speed, d * 10.0)
		velocity = velocity.move_toward(desired_vel, attract_accel * delta)
		move_and_slide()
	else:
		velocity.y -= gravity * delta
		if is_on_floor():
			velocity.y = 0.0
			velocity.x = move_toward(velocity.x, 0.0, ground_friction * delta)
			velocity.z = move_toward(velocity.z, 0.0, ground_friction * delta)
		move_and_slide()

	if _sprite != null:
		var hovering: bool = is_on_floor() and (_target == null or not is_instance_valid(_target))
		var y: float = _base_sprite_y
		if hovering:
			y += hover_height + hover_amplitude * sin(_time * hover_speed)
		_sprite.position.y = y


func _refresh_visual() -> void:
	if _sprite == null:
		return
	_sprite.texture = BlockRegistryScript.icon_for(item_id)

func set_attract_delay(seconds: float) -> void:
	_attract_delay_left = max(0.0, seconds)


func start_attract(target: Node) -> void:
	# 由玩家的“吸附范围”触发，掉落物开始飞向玩家。
	if target == null:
		return
	if not target.has_method("pickup_item"):
		return
	_target = target


func _try_pickup(body: Node) -> void:
	# 规则：拾取逻辑归玩家管理（是否满背包、剩余多少），掉落物只负责“飞向玩家并请求拾取”。
	if body == null or not is_instance_valid(body):
		_target = null
		return
	if not body.has_method("pickup_item"):
		_target = null
		return
	var remain: int = body.call("pickup_item", item_id, count)
	if remain <= 0:
		queue_free()
		return
	count = remain
	_target = null
