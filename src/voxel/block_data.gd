extends Resource
class_name BlockData

@export var id: int = 0
@export var display_name: String = ""
@export var solid: bool = true

@export var icon_texture: Texture2D

@export var tile_top: Vector2i = Vector2i.ZERO
@export var tile_side: Vector2i = Vector2i.ZERO
@export var tile_bottom: Vector2i = Vector2i.ZERO

@export var roughness_top: float = 1.0
@export var roughness_side: float = 1.0
@export var roughness_bottom: float = 1.0

@export var specular_top: float = 0.04
@export var specular_side: float = 0.04
@export var specular_bottom: float = 0.04

func tile_for_face(face: int) -> Vector2i:
	match face:
		VoxelTypes.Face.POS_Y:
			return tile_top
		VoxelTypes.Face.NEG_Y:
			return tile_bottom
		_:
			return tile_side

func material_params_for_face(face: int) -> Vector2:
	match face:
		VoxelTypes.Face.POS_Y:
			return Vector2(roughness_top, specular_top)
		VoxelTypes.Face.NEG_Y:
			return Vector2(roughness_bottom, specular_bottom)
		_:
			return Vector2(roughness_side, specular_side)
