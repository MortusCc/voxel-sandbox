extends Resource
class_name BlockData

## 方块唯一 ID（与 VoxelTypes / 注册表一致）
@export var id: int = 0
## 在 UI / 调试输出中展示的名称
@export var display_name: String = ""
## 是否占据一个体素格（为 false 时会被当作"空气/不存在"处理）
@export var solid: bool = true
## 是否遮挡相邻体素的面（用于面剔除）。树叶/玻璃这类应设为 false
@export var occludes_faces: bool = true
## 染色模式：无 / 仅顶面（草）/ 全面（树叶）
@export_enum("无染色:0", "仅顶面染色:1", "全面染色:2") var tint_mode: int = 0
## 是否启用侧面覆盖层（例如草方块侧面 overlay）
@export var use_side_overlay: bool = false
## Alpha 裁剪阈值：0 表示不裁剪；>0 表示 tex.a < 阈值 时丢弃像素（树叶镂空）
@export var alpha_cutoff: float = 0.0

## 快捷栏/列表回退用的静态图标（可选；启用 3D 预览后通常仅用于兜底）
@export var icon_texture: Texture2D

## 顶面贴图 tile（图集坐标）
@export var tile_top: Vector2i = Vector2i.ZERO
## 侧面贴图 tile（图集坐标）
@export var tile_side: Vector2i = Vector2i.ZERO
## 底面贴图 tile（图集坐标）
@export var tile_bottom: Vector2i = Vector2i.ZERO

## 顶面粗糙度（0 光滑 - 1 粗糙）
@export var roughness_top: float = 1.0
## 侧面粗糙度（0 光滑 - 1 粗糙）
@export var roughness_side: float = 1.0
## 底面粗糙度（0 光滑 - 1 粗糙）
@export var roughness_bottom: float = 1.0

## 顶面镜面强度（0 无高光 - 1 高光强）
@export var specular_top: float = 0.04
## 侧面镜面强度（0 无高光 - 1 高光强）
@export var specular_side: float = 0.04
## 底面镜面强度（0 无高光 - 1 高光强）
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
