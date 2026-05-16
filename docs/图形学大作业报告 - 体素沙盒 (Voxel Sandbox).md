# 图形学大作业报告 - 体素沙盒 (Voxel Sandbox)

更新说明：本文档会随项目迭代持续更新，用于最终提交的大作业报告（含配置过程、关键算法原理、代码说明与运行结果）。

## 更新记录
- 2026-05-03：初始化报告结构；补充当前已实现的体素网格生成、Texture Atlas UV、Blinn-Phong、DDA 拾取、草地群系染色与侧面覆盖层等内容。
- 2026-05-03：修复运行时纹理图集构建导致的“黑白方块/缺贴图”现象；改为从导入后的 Texture2D 提取 Image 并在运行时拼接多行 Atlas（兼容导出）。
- 2026-05-03：修复区块网格六个面的顶点绕序不一致导致的“缺顶面/只见内壁”显示问题；统一各面为一致的外法线绕序以配合背面剔除。
- 2026-05-03：重新验证并统一六个面的顶点绕序与 UV 朝向；将侧面 UV 的 v 轴与世界 y 对齐，保证草侧纹理“草皮朝上”且不再出现 90° 旋转。
- 2026-05-03：调整材质光照表现：弱化/关闭镜面高光、提高粗糙度并增加用于调试的环境补光（相机挂载点光源），避免无直射光面完全发黑。
- 2026-05-03：改为更“正规”的材质光照：使用引擎 PBR 光照通道（设置 ROUGHNESS/SPECULAR/METALLIC），并将粗糙度与镜面强度按“方块类型/面”写入顶点属性，实现不同材质差异；同时将图集采样设置为 nearest，恢复像素风锐利感。
- 2026-05-03：加入 HUD 十字准心；调整主光源为“太阳”式方向光（位于场景上方、带阴影与偏暖色调），便于交互与观察光照效果。
- 2026-05-03：实现玩家碰撞与地形碰撞：区块网格生成后同步生成 Trimesh 静态碰撞体；玩家由自由相机改为 CharacterBody3D（胶囊体），支持重力与跳跃，可站立在体素方块表面。
- 2026-05-03：修复切换 16×16 贴图后“场景不可见/图集构建报错”：在运行时拼接 Texture Atlas 前统一把各张贴图转换为相同像素格式（RGBA8）并按 tile 尺寸做 nearest resize，避免 `Image.blit_rect()` 的格式不一致错误。
- 2026-05-03：调整玩家出生点到区块地表上方；加入“双击空格切换飞行模式”，飞行模式下悬停不受重力，Space 上升、Ctrl 下降，便于开发期快速观察与测试。
- 2026-05-03：加入放置规则：禁止在玩家当前占据空间内放置方块（防止把自己封进方块导致掉落/穿透），但允许跳起后在脚下放置方块用于搭高；同时将玩家与地形碰撞层分离，便于做精确的放置相交检测。
- 2026-05-03：为便于调试与表现细节，添加/加强环境光（WorldEnvironment Ambient Light），降低背光面“全黑”的可见性；同时增大跳跃初速度，使玩家可跳起后在脚下放置方块完成“搭高”操作。
- 2026-05-03：修复交互后出现“透视/黑片”的主要渲染问题：将网格三角形绕序统一为 CW 正面并与 `render_mode cull_back` 匹配，避免外表面被背面剔除导致只能看到内部面（内部面在环境光较弱时易呈现接近全黑的错觉）。
- 2026-05-03：修复“背光面纯黑”配置问题：Environment 的 `ambient_light_source` 之前误设为 Disabled（数值 1），导致环境光被关闭；改为 Color（数值 2）后，背光面可见且更接近户外光照效果。
- 2026-05-03：为避免调试阶段因绕序/剔除导致的“局部透视/缺面”干扰判断，曾将体素材质临时设置为双面渲染（`cull_disabled`）。在绕序验证通过后恢复为 `cull_back`，避免看到顶面背面（三角形分割造成的锯齿状边缘）并提升渲染效率。
- 2026-05-03：修复“转头后放置方块出现透视/缺面”的交互问题：改进 3D DDA 射线遍历的起点处理（沿射线方向加极小偏移，避免落在体素边界造成抖动），并将放置目标从“last_empty”改为“命中体素沿命中法线的相邻空气格子”；同时增加“只允许放置在空气格子”校验，避免把方块放进实体体素导致面重叠与 z-fighting。
- 2026-05-03：进一步修复射线方向性 bug：当射线起点恰好落在体素边界（坐标为整数）时，按“沿负方向行进则归属到边界后方体素”的规则修正初始体素归属，消除“正向正常、背向错位”的放置偏差。
- 2026-05-03：最终解决”背向透视（遮挡关系错误）”：问题并非射线放置错格，也不是 CPU 面剔除漏面，而是深度写入策略与 alpha 通道交互导致的遮挡异常。最终采用 `depth_draw_opaque` + 强制 ALPHA=1 + `ALPHA_SCISSOR_THRESHOLD` 方案：实体方块纹理 alpha 置为 1 确保写入深度，仅树叶/玻璃通过 alpha 裁剪阈值丢弃片元。遮挡关系恢复正常、稳定不再透视。
- 2026-05-03：修复“掉入地面/内部顶住”的碰撞异常：trimesh 生成的 ConcavePolygonShape3D 默认可能为单面碰撞，启用 `backface_collision` 使其双面碰撞，避免因绕序/背面导致的穿透与卡住。
- 2026-05-03：修复方块交互后出现“透视/消失面”现象：对体素材质强制使用不透明渲染（ALPHA=1），避免纹理 alpha 通道或图集空白区域导致透明混合；同时调整相机相对玩家高度，符合第一人称视角（约 1.5~1.6m）。
- 2026-05-03：清理调试代码：移除为定位”背向透视”引入的 debug 导出参数与控制台日志输出，保留最终修复配置（`depth_draw_opaque` + ALPHA=1 + `ALPHA_SCISSOR_THRESHOLD`）与核心功能代码，避免项目在后续迭代中被大量调试开关干扰。
- 2026-05-04：实现“快捷栏/掉落物”的方块 3D 预览：使用 SubViewport 离屏渲染 + 缓存，直接在 UI 上显示立方体方块预览，不再依赖预渲染 PNG 图标；掉落物也改为 3D 小方块并带旋转/悬浮与吸附拾取。
- 2026-05-04：将“是否遮挡面/染色模式/侧面覆盖层/Alpha 镂空”等渲染与剔除属性从硬编码迁移到 BlockData 资源字段，做到可配置可扩展；并工程化运行时 Atlas 构建与 tile 自动分配，新增方块只需添加贴图与 .tres 即可自动支持世界渲染与 UI 预览。
- 2026-05-04：优化快捷栏 3D 预览视角：改为使用对角方向相机位置（正交投影）以稳定显示“上/前/侧”三面，草方块侧面草皮与覆盖层在 UI 中更容易辨识。
- 2026-05-04：新增最简“昼夜天空”系统：基于 WorldEnvironment + ProceduralSkyMaterial 实现上下两段天空颜色，并按时间平滑过渡昼夜；同时使用太阳/不同月相贴图显示天体位置（无天气、无生物群系颜色混合的简化版）。
- 2026-05-04：调整太阳/月亮贴图天体的显示尺寸：改用“世界直径 → pixel_size”计算，并强制最近邻采样，避免远距离下天体缩成黑点或被模糊成深色点。
- 2026-05-04：修复太阳贴图显示为“黑底斜四边形”：为天体贴图材质强制启用 billboard（始终面向相机），太阳默认使用加法混合隐藏黑色背景，更接近 Minecraft 的天体渲染效果。
- 2026-05-04：将月亮天体也改为可选“加法混合”，避免月落/月出时贴图黑底穿帮；并让 DirectionalLight3D 的方向/颜色/强度随时间在“太阳光→月光”间平滑过渡，开启方向光阴影实现体素地形与角色的影子效果（可调阴影距离与偏移参数）。
- 2026-05-04：新增云层系统：多层 PlaneMesh 云 + 独立 clouds.gdshader（unshaded/blend_mix）+ 昼夜颜色/透明度平滑过渡 + 可调移动速度与纹理缩放。
- 2026-05-04：区块架构重构：Y 方向不再分块（仅 XZ 16×16），Chunk 内部改为按列字典存储 y→voxel_type，支持任意高度体素堆叠。
- 2026-05-04：新增基岩方块（y=0 铺 1 层，不可破坏，不进入快捷栏）。
- 2026-05-04：新增玻璃方块（alpha 裁剪镂空，同材质相邻面不生成内部面，透光）。
- 2026-05-04：新增沙子方块 + 重力掉落系统：连续沙柱整体打包为下落实体（带碰撞与重力），触底后按柱逐格回填为体素方块，避免并发丢块。
- 2026-05-04：群系从 3 类扩展为 4 类（平原/森林/干旱/沙漠）；沙漠不生成树，地表全沙子、无泥土草方块。
- 2026-05-04：洞穴天光传播系统：Chunk 重建前执行 BFS 天光传播（从列顶直射光向下，衰减步长 2），跨区块通过采样邻居 Chunk 的缓存光值实现连续渐变。
- 2026-05-04：世界流式加载优化：以玩家为中心按半径加载/卸载区块，碰撞仅对近区启用，网格重建按队列节流。
- 2026-05-04：导出纹理方案统一：编辑器运行生成 block_atlas.png → 写入项目目录 → 导出版 load("res://resources/textures/block_atlas.png") 由 Godot 导入管线提供纹理；同时将 tile 映射烘焙写入各 .tres 文件保证导出后正确采样。
- 2026-05-14：更新文档与代码一致：修正 Texture Atlas 图集尺寸描述（4×2→动态N×2/当前10列）；修正光照模型描述（Blinn-Phong→Godot PBR+自定义天光）；更新附录文件行数。

---

## 一、程序运行的软硬件环境（15分）

### 1）程序运行所需的环境和使用的编程语言（5分）
- 操作系统：Windows（本机开发环境）
- 引擎版本：Godot 4.6（Forward Plus 渲染管线）
- 编程语言：
  - GDScript（核心逻辑与网格生成、交互系统）
  - GDShader（自定义光照与草地群系染色效果）
- 运行形态：桌面端 3D 图形交互程序（体素沙盒原型）

### 2）程序运行所需的环境配置过程（10分）
1. 安装 Godot 4.6（标准版 Editor）。
2. 打开项目：
   - 使用 Godot Project Manager 选择项目目录：`e:\Godot\GodotProjects\voxel-sandbox`
   - 打开 `project.godot`。
3. 运行入口：
   - 主场景：`res://scenes/main.tscn`（已在 `project.godot` 中设置为 main_scene）。
4. 纹理资源准备：
   - 放置纹理到：`res://resources/textures/`
   - 当前使用 Minecraft 16×16 纹理（草顶、草侧、泥土、石头、草侧覆盖层）。
5. 关键导入设置：
   - 像素风贴图需要关闭 Filter（Nearest），避免显示发糊。

（请在此处插入以下截图）
- 图 1：Godot Project Manager 打开项目截图 —— 展示项目管理器中列出 "VoxelSandbox" 项目，右侧显示项目路径与 Godot 版本号（4.6）。
- 图 2：项目结构与主场景 main.tscn 截图 —— 展示 FileSystem 面板中 src/（voxel/、player/、world/）、resources/（textures/block/、blocks/）、shaders/、scenes/ 的目录结构；Scene 面板显示 main.tscn 的节点树（VoxelWorld、Player、SkyController、WorldEnvironment、HUD 等）。
- 图 3：纹理导入设置（Filter/Repeat）截图 —— 选中任一张 .png 纹理（如 grass_block_top.png），Import 面板中 Filter 设为 Nearest、Repeat 设为 Disabled，展示像素风贴图的典型导入配置。

---

## 二、关键技术和难点问题（30分）

### 1）程序设计中使用的关键技术和涉及的相关算法的原理（10分）

#### A. 动态网格构建（Procedural Mesh Generation）+ 面剔除（Face Culling）
目标：避免把每个方块直接做成独立 MeshInstance3D，而是将区块（Chunk）内的体素合并成一个网格，并且只生成暴露面，隐藏内部面，减少三角形数。

核心思想：
- 对每个体素检查 6 个邻居（±X/±Y/±Z）。
- 若邻居为空气或透明方块，则该方向的面可见，需要生成 2 个三角形（4 个顶点 + 6 个索引）。
- 若邻居为实体，则该面被遮挡，不生成。

伪码：
```
for 每个体素 in 区块:
  if 体素是空气: 跳过
  for 6个面方向:
    邻居 = 体素坐标 + 面方向偏移
    邻居类型 = 查询邻居所在体素
    if 邻居遮挡面: 跳过                           // 邻居是实体方块 → 面被遮挡，不生成
    if 邻居类型是玻璃 且 当前体素也是玻璃: 跳过    // 同材质透明方块相邻 → 不生成内部面
    生成该面的4个顶点 + 6个索引                   // 暴露面 → 推入网格数组
```

说明：实体方块（石头、泥土、草方块等）设置 `occludes_faces = true`，会遮挡相邻面；树叶和玻璃设置 `occludes_faces = false`，相邻面仍然生成（可看到内部）。但两块玻璃相邻时只保留外表面、不生成内部面——这是网格生成阶段额外判断的规则，避免玻璃墙内部出现多余的边框线。

数据通道（Vertex Attributes）：
- POSITION：每个顶点的 3D 坐标
- NORMAL：每个面写入常量法线（立方体各面法线固定）
- TEXCOORD0(UV)：从 Texture Atlas 动态计算得到
- COLOR：顶点色本项目用作“掩码通道”，标记哪些面需要草地染色/侧面覆盖层叠加（见后文）

#### B. Texture Atlas UV 计算（Texture Mapping）
目标：使用一张纹理图集（Texture Atlas）承载多种方块纹理，网格生成阶段为每个面分配 UV，使不同面采样到不同 tile。

核心思想：
- 将图集视为 `atlas_columns × atlas_rows` 的格子。
- 每个格子对应一个 tile 索引 `(tile_x, tile_y)`。
- 将 tile 坐标映射到 UV 区间：
  - `du = 1/atlas_columns`, `dv = 1/atlas_rows`
  - `u0 = tile_x * du`, `u1 = (tile_x + 1) * du`
  - `v0 = tile_y * dv`, `v1 = (tile_y + 1) * dv`
- 为四个顶点按约定顺序赋值 UV。

本项目图集组织方式（当前实现）：
- N 列 × 2 行（动态列数，取决于实际贴图数量；当前 10 列）
- 第 0 行：所有方块的基础纹理（按文件名排序，grass_block_top / grass_block_side / dirt / stone / oak_log / oak_log_top / oak_leaves / bedrock / glass / sand）
- 第 1 行：对应位置的覆盖层纹理（仅 grass_block_side_overlay 有效，其余为空）

#### C. 射线拾取：3D DDA（Digital Differential Analyzer）栅格遍历
目标：玩家准星（相机前方射线）命中哪个方块，用于鼠标左键破坏/右键放置。不依赖在场景中放置成千上万个碰撞体做逐方块射线检测。

核心思想：不按固定步长（如 `t += 0.01`）推进射线——步长太小则慢，太大则可能跳过薄墙。而是精确计算射线依次穿过哪些体素格边界，每次跨过最近的一个边界进入下一格。

关键变量（射线 `P(t) = origin + t × direction`）：
- `t_max_x/y/z`：沿各轴走到**下一个格边界**所需的 t 值
- `t_delta_x/y/z`：沿各轴**跨过一整格**需要的 t 增量（`= 1.0 / |direction|`）

伪码：
```
voxel = floor(origin)                     // 射线起点所在体素格
step  = sign(direction)                   // 各轴行进方向：+1 / -1
t_max = (next_boundary - pos) / direction  // 到各轴下一格边界的 t
t_delta = abs(1.0 / direction)            // 跨一格需要的 t 增量

while 累计步数 < 最大步数:
  if t_max.x 最小:   voxel.x += step.x;  t_max.x += t_delta.x   // 跨过 x 边界
  elif t_max.y 最小: voxel.y += step.y;  t_max.y += t_delta.y   // 跨过 y 边界
  else:             voxel.z += step.z;  t_max.z += t_delta.z   // 跨过 z 边界
  if voxel 是实体方块: 命中，返回 voxel 和命中面法线
未命中
```

复杂度：O(射线穿过的格子数)，对 6 格交互距离通常仅十几次迭代，且保证不跳过任何格子。

关键边界处理：当射线起点恰好落在体素格边界（坐标 ≈ 整数），需根据行进方向修正初始体素的归属，避免正向和背向命中结果差一格。

#### D. 自定义着色器：PBR 光照 + 草地群系染色（Biome Grass Tint）
1) 基础光照（Godot 内置 PBR + 自定义天光叠加）
- 使用 Godot 引擎的 `diffuse_lambert` 漫反射 + roughness/specular 参数控制镜面反射
- 不使用传统 Blinn-Phong 公式，而是在引擎 PBR 通道基础上叠加自定义天光计算（`sky_brightness` × 顶点 COLOR.b 天光值）
- 各面粗糙度/镜面强度通过顶点属性传入，不同方块类型可配置不同材质参数

2) 草地群系染色（加分项）
目标：复现 Minecraft 草方块“顶面随群系变化”的效果，并让侧面草皮与顶面颜色一致。

实现要点：
- 网格阶段通过顶点色传入“掩码通道”：
  - `COLOR.r = 1`：草顶面（需要 tint）
  - `COLOR.g = 1`：草侧面草皮覆盖层（需要叠加 overlay 并 tint）
- Shader 阶段：
  - 采样基础贴图（第 0 行 UV）。
  - 对草顶面：`tex * grass_tint * biome`。
  - 对草侧面：额外采样覆盖层（UV 向下偏移一行），对覆盖层 `overlay * grass_tint * biome`，按 `overlay.a` alpha 叠加到侧面底图上。
  - biome 参数当前用世界坐标噪声近似（也可扩展为群系 colormap 查表）。

### 2）在程序设计时遇到了哪些难点问题？又是如何解决的？（10分）
1. 体素数据初始化时机导致的越界崩溃：
   - 现象：`PackedByteArray` 未 resize 时写入导致 out of bounds。
   - 原因：Chunk 被 `new()` 创建后在入树前就被调用填充地形，`_ready()` 尚未执行。
   - 解决：在体素读写/网格生成入口统一做 `_ensure_voxel_buffer()`，确保缓冲区长度正确。
2. GDScript 语法差异导致的解析错误：
   - 现象：使用 `condition ? a : b` 报错。
   - 解决：改用 `a if condition else b`。
3. 类型与全局类名遮蔽导致的告警：
   - 现象：`const VoxelTypes := preload(...)` 与 `class_name VoxelTypes` 冲突。
   - 解决：直接使用全局类名，避免同名 const。
4. 纹理显示为黑白块（缺贴图）：
   - 现象：运行后体素表面出现黑白方块（引擎的缺贴图/占位显示），导致看不到 Minecraft 纹理。
   - 原因：Shader 编译失败或图集纹理无效会触发占位显示；此外，直接用 `Image.load("res://...png")` 读取源文件在导出后可能不可用。
   - 解决：修复 Shader 中世界坐标变量的获取方式（通过 vertex varying 传递 world_pos）；图集构建改为从导入后的 `Texture2D` 获取 `Image`（`Texture2D.get_image()`），再用 `Image.blit_rect()` 拼接多行 Texture Atlas，并创建 `ImageTexture` 供 Shader 使用（更兼容导出）。
5. 洞穴天光无法传播（洞内全黑）：
   - 现象：任何洞口光照只能照亮洞口第一格，洞内完全漆黑无渐变过渡。
   - 原因：天光仅按"列顶最高遮挡体素以上/以下"做二值判断（15 或 0），无传播衰减模型。
   - 解决：在 Chunk 重建网格前执行 BFS 天光传播——从列顶直射光（值 15）出发，穿过透光方块（树叶/玻璃）向六邻方向扩散，每步衰减 2 格光值；跨区块通过读取相邻 Chunk 的 `_skylight_cache` 实现连续过渡。
6. 沙子下落并发丢块：
   - 现象：堆叠多格沙子柱，挖掉底部后多块沙子同时下落，稳定后总数量减少。
   - 原因：每块沙子独立生成为一个下落实体，多个实体在同一列重叠/抢位，回填时互相覆盖导致丢块。
   - 解决：将连续沙柱整体打包为一个下落实体（携带 `height_blocks` 参数），落地时一次性逐格回填整根柱子；下落过程中使用向上射线检测支撑面，避免中心点误差导致错格。
7. 导出后纹理全白/条纹化：
   - 现象：编辑器运行正常，导出 exe 后所有体素面变成白色或拉伸条纹。
   - 原因：导出后 `res://` 的目录枚举与资源存在性判断与编辑器环境不一致，`DirAccess` 无法列出源 PNG；`Texture2D.get_image()` 在导出环境可能返回空。
   - 解决：编辑器运行生成 `block_atlas.png` 并保存到项目目录；导出环境直接 `load("res://resources/textures/block_atlas.png")` 走 Godot 的导入管线获取压缩纹理；同时将 tile 映射烘焙写入各 .tres 文件，确保即使动态映射失效也能正确采样图集格子。
8. 区块 Y 方向分块导致高柱消失：
   - 现象：在同一 (x,z) 位置向上堆叠方块超过 16 格后顶部消失。
   - 原因：原有架构按 16×16×16 三维分块，但世界只维护 y=0 的 Chunk 键；体素落在 y≥16 时找不到对应 Chunk 被当作空气。
   - 解决：重构为 XZ 二维分块（16×16，Y 不限高度），Chunk 内部改为按列字典存储 y→voxel_type，同时修改世界坐标映射 `_voxel_to_chunk_coord` 将 Y 恒置为 0，所有体素读写/查询均适配新模型。

### 3）程序内容与本课程相关的主要技术点（10分）
- 顶点/索引缓冲的手动构建（ArrayMesh）
- 面剔除（不生成内部面）作为几何层面的优化
- Texture Atlas 与 UV 变换（tile→UV 区间映射）
- 法线方向与光照模型（引擎 PBR 通道 + 自定义天光叠加）
- Shader 中使用额外顶点属性（COLOR 作为掩码通道）驱动片元逻辑
- DDA 栅格遍历（空间离散化与光线行进）

---

## 三、程序源代码和使用说明（20分）

### 1）程序源代码（10分）
项目采用”模块化脚本 + 场景入口”的组织方式，共 13 个核心 GDScript 文件 + 2 个 GDShader 文件：

**核心体素系统（src/voxel/）**
- `voxel_types.gd` — 体素类型枚举（AIR/GRASS/DIRT/...）与面方向定义
- `block_data.gd` — 方块属性资源类（solid/occludes/tint_mode/tile坐标/粗糙度等）
- `block_registry.gd` — 方块注册表：扫描 .tres 加载 BlockData，维护 id→Resource 映射
- `atlas_builder.gd` — 纹理图集构建器：运行时拼接多张纹理为一张大图
- `voxel_chunk.gd` — 区块节点（MeshInstance3D）：列字典存储 + 面剔除网格生成 + BFS天光传播 + 碰撞体
- `voxel_world.gd` — 世界管理器（Node3D）：地形生成 + 树生成 + DDA射线拾取 + 区块流式加载 + 交互

**玩家系统（src/player/）**
- `player_controller.gd` — 玩家控制器（CharacterBody3D）：第一人称/飞行双模式 + 快捷栏管理 + 放置碰撞检测

**世界实体（src/world/）**
- `sky_controller.gd` — 天空/昼夜控制器：ProceduralSkyMaterial + 日月Sprite + 方向光 + 环境光 + 云层 + 月相
- `item_drop.gd` — 掉落物实体（CharacterBody3D）：重力下落 + 悬浮旋转 + 吸附拾取
- `falling_block.gd` — 下落实体（CharacterBody3D）：沙柱整体打包下落 + 触底逐格回填

**UI 系统（src/ui/）**
- `hotbar.gd` — 快捷栏 UI（Control）：9格物品槽渲染 + 选中高亮 + 3D预览图标
- `block_preview_renderer.gd` — 方块3D预览渲染器（SubViewport离屏渲染 → Texture2D缓存）

**着色器（shaders/）**
- `voxel_lit.gdshader` — 体素方块着色器：纹理采样 + 群系染色 + 侧面覆盖层 + alpha裁剪 + 天光计算
- `clouds.gdshader` — 云层着色器：世界空间采样 + 昼夜颜色/透明度过渡

**场景文件（scenes/）**
- `main.tscn` — 项目入口场景（VoxelWorld + Player + SkyController + WorldEnvironment + HUD）
- `item_drop.tscn` — 掉落物场景模板
- `falling_block.tscn` — 下落实体场景模板
- `hotbar.tscn` — 快捷栏 UI 场景

**系统架构图（数据流）：**

```
                         SkyController
                        (昼夜/日月/云/光照)
                              │
                              ▼ sky_brightness
 textures/*.png               │
      │                       │
      ▼                       │
 AtlasBuilder ──► block_atlas.png ──► ShaderMaterial (voxel_lit.gdshader)
      │                                            │
      ▼ tile映射                                    │
 BlockRegistry ──► BlockData (.tres)               │
      │                                            │
      ▼ 方块属性查询                                 ▼
 VoxelWorld ◄────────────────────── VoxelChunk (网格+碰撞)
      │         sample_neighbor/          │
      │         sample_skylight           │
      │                                   ▼
      ├── DDA射线 ◄── PlayerController ──► Camera3D
      │       │           │
      │   hit_voxel    WASD/Space/Click
      │       │           │
      ├── set_voxel   快捷栏 ◄── ItemDrop (拾取)
      │       │
      ├── break_voxel ──► ItemDrop (掉落)
      │       │
      └── FallingBlock (沙子下落/回填)
```

> 图 4：系统结构图 — 展示各模块间的数据流与依赖关系。

**关键代码展示**

代码片段 1：面剔除与网格生成核心循环（`voxel_chunk.gd` — `rebuild_mesh()`）
```gdscript
for z in range(chunk_size):
    for x in range(chunk_size):
        var col: Dictionary = _columns[_col_index(x, z)]
        for k in col.keys():
            var y: int = int(k)
            var voxel_type: int = int(col[k])
            if not BlockRegistryScript.is_solid(voxel_type):
                continue
            # 六个方向逐个检查邻居，暴露面才生成
            for face_idx in 6:
                var offset: Vector3i = _FACE_OFFSETS[face_idx]
                var neighbor_global: Vector3i = global_voxel + offset
                var neighbor_type: int
                if is_in_bounds(nl.x, nl.y, nl.z):
                    neighbor_type = get_voxel_local(nl.x, nl.y, nl.z)
                else:
                    neighbor_type = int(sample_neighbor.call(neighbor_global))
                # 玻璃相邻同类型不生成内部面
                if voxel_type == VoxelTypes.GLASS and neighbor_type == voxel_type:
                    continue
                if BlockRegistryScript.occludes_faces(neighbor_type):
                    continue
                _try_add_face(face_idx, ...)
```

代码片段 2：tile→UV 计算（`voxel_chunk.gd` — `_tile_uv_rect()`）
```gdscript
func _tile_uv_rect(tile: Vector2i) -> Rect2:
    var cols: int = max(1, atlas_columns)
    var rows: int = max(1, atlas_rows)
    var tp: float = max(1.0, tile_pixels * 1.0)
    var atlas_w: float = float(cols) * tp
    var atlas_h: float = float(rows) * tp
    var left: float = (float(tile.x) * tp + pad_px) / atlas_w
    var right: float = (float(tile.x + 1) * tp - pad_px) / atlas_w
    var top: float = (float(tile.y) * tp + pad_px) / atlas_h
    var bottom: float = (float(tile.y + 1) * tp - pad_px) / atlas_h
    return Rect2(Vector2(left, top), Vector2(right - left, bottom - top))
```

代码片段 3：DDA 栅格遍历（`voxel_world.gd` — `raycast_voxel()`）
```gdscript
var pos: Vector3 = origin / voxel_scale
var voxel: Vector3i = Vector3i(floori(pos.x), floori(pos.y), floori(pos.z))
var step: Vector3i = Vector3i(sign(dir.x), sign(dir.y), sign(dir.z))
# 计算各轴跨越一格所需 t 增量与到下一格边界的 t 距离
var t_delta: Vector3 = Vector3(absf(1.0/dir.x), absf(1.0/dir.y), absf(1.0/dir.z))
var next_bound: Vector3 = Vector3(voxel.x+(1 if step.x>0 else 0), ...)
var t_max: Vector3 = Vector3((next_bound.x-pos.x)/dir.x, ...)
for _i in max_steps:
    if t_max.x < t_max.y and t_max.x < t_max.z:
        voxel.x += step.x; t_max.x += t_delta.x
    elif t_max.y < t_max.z:
        voxel.y += step.y; t_max.y += t_delta.y
    else:
        voxel.z += step.z; t_max.z += t_delta.z
    if BlockRegistryScript.is_solid(_sample_voxel_global(voxel)):
        return {"hit": true, "voxel": voxel, ...}
```

代码片段 4：Shader 草地群系染色与侧面 overlay 叠加（`voxel_lit.gdshader` — `fragment()`）
```glsl
// 顶点色 COLOR.r = 草顶面掩码, COLOR.g = 草侧面覆盖层掩码
float grass_top_mask = clamp(COLOR.r, 0.0, 1.0);
float grass_side_overlay_mask = clamp(COLOR.g, 0.0, 1.0);
// 解码群系 ID：UV2.x 打包了 leaf_flag 与 biome_id
float leaf_mask = step(0.5, UV2.x);
float biome_id = floor(clamp((UV2.x - leaf_mask * 0.5) * 8.0, 0.0, 2.999));
// 从 colormap 查群系色
vec3 grass_base = texture(grass_colormap, th).rgb;
// 顶面染色
vec3 top_rgb = tex.rgb * mix(vec3(1.0), tint, grass_top_mask) * albedo_tint;
// 侧面覆盖层叠加（UV 向下偏移一行读取 overlay）
float dv = 1.0 / max(atlas_rows, 1.0);
vec2 overlay_uv = UV + vec2(0.0, dv);
vec4 overlay = textureLod(atlas_texture, overlay_uv, 0.0);
vec3 side_rgb = base_rgb * (1.0 - overlay.a * grass_side_overlay_mask)
              + overlay.rgb * tint * albedo_tint * (overlay.a * grass_side_overlay_mask);
vec3 albedo = mix(side_rgb, top_rgb, grass_top_mask);
// 天光与遮挡衰减
ALBEDO = albedo * light01;
ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;
```

### 2）程序中使用的特殊函数的功能列表（10分）
本项目尽量避免“直接堆叠现成方块节点”，但允许使用引擎提供的底层数据结构与渲染接口：
- `ArrayMesh.add_surface_from_arrays()`：将顶点/法线/UV/颜色/索引数组提交为可渲染网格。
- `Image.create()` / `Image.blit_rect()`：在运行时拼接多张贴图生成 Texture Atlas。
- `ImageTexture.create_from_image()`：将 `Image` 转为 GPU 可用纹理资源。
- `floori()`：将连续空间坐标映射到体素网格坐标（DDA 初始体素定位）。
- `absf()` / `ceili()` / `clampf()`：数值处理（DDA、相机控制、Shader 参数等）。

---

## 四、程序运行结果（20分）

### 1）软件使用说明（10分）
- 视角：鼠标移动
- 移动：W/A/S/D
- 跳跃：空格
- 飞行：连续点击两下空格
  - 飞行时上下移动：Ctrl（下降）/空格（上升）

- 加速：Shift
- 交互：
  - 破坏方块：鼠标左键
  - 放置方块：鼠标右键
  - 切换快捷栏方块：鼠标滚轮/数字键
- 切换鼠标捕获/释放：ESC

### 2）程序运行结果（10分）
（请在此处插入以下截图）
- 图 5：初始地形与光照效果截图 —— 展示随机生成的山丘地形，可见多种群系（平原绿草/森林深草/干旱黄草/沙漠沙子）的交界过渡；方向光阴影投射在地形上，天空盒与云层可见，PBR 光照 + 自定义天光使各面随法线明暗变化。
- 图 6：草地方块顶面与侧面草皮颜色一致截图 —— 展示草方块顶面与侧面草皮覆盖层的群系染色效果一致（同为平原绿或干旱黄），侧面下半部分为泥土纹理，过渡自然。
- 图 7：方块删除/放置截图 —— 展示玩家准星对准方块后出现白色线框高亮；左键破坏后方块消失并掉落 3D 旋转小方块；右键放置后在目标空气格生成新方块。
- 图 8：昼夜天空与云层截图 —— 展示白天太阳贴图（billboard + 加法混合）与夜晚月亮（月相贴图）的视觉效果；云层在昼夜有不同的颜色与透明度表现。
- 图 9：洞穴天光衰减截图 —— 展示从洞口向内天光逐格衰减的效果（洞口附近亮 15，向内逐格变暗到 0），体现 BFS 天光传播的渐变过渡。
- 图 10：沙漠群系截图 —— 展示沙漠区域地表全为沙子、无树、无泥土/草方块，与相邻群系（平原/森林）形成明显对比。
- 图 11：沙子重力掉落截图 —— 展示沙子在挖掉支撑后以"下落方块柱"实体形式掉落并在落地后恢复为方块的全过程。
- 图 12：玻璃墙截图 —— 展示玻璃方块使用 alpha 裁剪实现镂空效果，内部相邻面不可见仅外表面可见。

---

## problems_and_diagnostics

本节用于记录开发过程中常见问题的定位思路与快速排查方法，便于后续迭代时复现与回归验证。

### 0）高柱体素“堆到一定高度消失/变虚空”（已解决）
- 现象：沿 Y 方向堆叠方块柱，达到一定高度后顶部方块消失，继续向上/向下操作会出现“下面也变空气”的错觉。
- 根因：区块按 16×16×16 切分时，Y 方向也参与分块；但世界侧只创建/维护了 y=0 的区块键，导致高处查询/写入落到不存在的 y!=0 区块。
- 解决：区块坐标改为仅按 XZ 分块（16×16），Y 不分块；Chunk 内部改为按列存储 y->voxel_type，世界查询与 set_voxel 均忽略 chunk_y。
- 验证：在同一 (x,z) 位置堆叠任意高度方块柱，不应再出现“上方消失/下方变虚空”；跨区块边界放置也应稳定。

### 0.1）玻璃纹理/透明表现异常（已解决）
- 现象：玻璃显示为纯白/发灰块，或纹理与导入的 `glass.png` 不一致。
- 根因：
  - 图集（atlas）未按最新纹理重建/映射未正确应用时，玻璃会采样到错误的 tile。
  - 透明混合路径对贴图 alpha 依赖较强，若贴图 alpha 不是“整块半透明”，会表现为“看起来不透明/发灰”。
- 解决：
  - 图集映射统一由 `BlockRegistryScript.apply_atlas_mapping()` 应用，避免加载顺序导致映射未生效。
  - 玻璃改为与树叶一致的 alpha 裁剪（`alpha_cutoff`）路径，表现稳定可控。
- 验证：玻璃应使用正确纹理；与树叶对比，透明/裁剪边缘应一致且稳定。

### 0.2）玻璃相接“内部面可见”（已解决）
- 现象：一整面玻璃墙中，相邻玻璃块之间的内部面仍被渲染，出现多余的边框/重叠线。
- 根因：玻璃 `occludes_faces=false` 使常规“邻居遮挡剔除”不生效，导致同材质相邻时仍生成内部面。
- 解决：网格生成时加入“同类型玻璃相邻则不生成该面”的规则，仅保留面向空气的外表面。
- 验证：搭建大面积玻璃墙，内部相接面不应可见；仅外表面可见。

### 0.3）沙子重力掉落（已实现）
- 现象/需求：沙子放置在空中或支撑被挖掉后，应逐格下落直到落在实体方块上。
- 方案：参考 MC 思路实现“下落方块实体”。当检测到沙子下方为空气时，将连续沙柱整体实体化为一个下落实体（带碰撞与重力）；触底后再将整根柱子回填为体素方块，避免并发下落丢块。
- 验证：堆叠多格沙子柱，挖掉底部支撑后应整体下落并保持数量不变；下落柱侧面纹理应按高度重复铺贴而非拉伸。

### 0.4）新增“沙漠”群系（已实现）
- 现象/需求：群系增加沙漠；不生成树；地表不出现泥土/草方块，地面均为沙子。
- 方案：扩展群系 ID 到 4 类（平原/森林/干旱/沙漠），地形生成在沙漠群系将表层若干层替换为沙子并禁用树生成逻辑。
- 验证：在渲染半径内应能看到连续沙漠区域，地表为沙子且无树；其他群系行为不受影响。

### 1）”背向透视/遮挡关系错误”（已解决）
- 现象：本应被遮挡的面在前景可见，表现为稳定的”穿帮/透视”而非轻微闪烁。
- 根因：纹理 alpha 通道或图集空白区域导致部分片元在不透明路径下不写深度，深度写入策略和 alpha 通道交互异常。
- 解决：体素 Shader 使用 `depth_draw_opaque` + 强制 ALPHA=1 + `ALPHA_SCISSOR_THRESHOLD` 方案：实体方块纹理 alpha 置为 1 确保写入深度，仅树叶/玻璃通过 alpha 裁剪阈值正确丢弃片元。遮挡关系恢复正常。
- 验证：在相同视角与复现点反复放置/破坏方块，不应再出现稳定穿帮；远近移动也不应出现”层级颠倒”。

### 2）自定义 BlockData 资源字段“被清空/变成空壳”
- 现象：`.tres` 打开后字段不见了，或保存后只剩 `[resource]`，之前设置的 tile/参数丢失。
- 根因：`.tres` 未绑定脚本或脚本类未被 Godot 正确识别时，编辑器可能按普通 `Resource` 重写序列化。
- 解决：确保 `.tres` 内包含脚本 ext_resource，并在 `[resource]` 下设置 `script = ExtResource("1")`。
- 验证：重新打开 `.tres`，应能看到 BlockData 的导出字段并可编辑；运行时 `BlockRegistry.get_block()` 不应返回 null。

### 3）快捷栏图标不显示/选中无反应
- 现象：Hotbar 显示为空或选中框不更新，滚轮/数字键无效果。
- 排查：
  - 确认 Player 的 `hotbar_path` 指向 `../HUD/Hotbar`，且 Hotbar 下存在 `Slots`，并包含 `Slot0..Slot8`。
  - 确认 `BlockRegistry` 能加载对应 `.tres`（资源路径是否存在、是否被移动）。
  - 确认输入事件未被 UI 吞掉（本项目 Hotbar/Crosshair 的 `mouse_filter` 需为 IGNORE）。

### 4）准星方块线框不出现/位置偏移
- 现象：看不到线框，或线框与方块不对齐。
- 排查：
  - 确认 `VoxelWorld.update_block_highlight()` 存在且 Player 每隔一定时间调用更新。
  - 确认 `voxel_scale` 与线框的 position/scale 同步（线框节点按体素坐标乘 voxel_scale 放置）。
  - 若频繁抖动：可提高 `highlight_update_interval`（例如 0.05~0.1）以减少更新频率。

### 5）物品/预览方块“背面可见、正面不可见”（绕序/剔除问题）
- 现象：掉落物或快捷栏 3D 预览出现“从上方看不到顶/底面、从下方反而能看到全貌”，或部分面像被翻转。
- 根因：预览/掉落物的立方体网格面顶点绕序与世界体素网格不一致，配合 `render_mode cull_back` 时会被错误背面剔除。
- 解决：预览/掉落物立方体生成统一复用与 VoxelChunk 相同的各面角点顺序与三角形索引顺序，保证外法线一致并与背面剔除匹配。
- 验证：从任意角度观察掉落物与快捷栏 3D 图标，六个面均应正常可见/遮挡；顶面/底面不应消失或反转。

### 6）洞穴天光传播“洞内全黑无渐变”（已解决）
- 现象：洞口仅第一格亮，洞内完全漆黑，无逐格衰减。
- 根因：天光使用二值判断——仅判断体素在"列顶最高遮挡方块"之上还是之下，不存在传播衰减。
- 解决：Chunk 重建前执行 BFS 天光传播缓存（`_build_skylight_cache`）：从列顶直射光出发，穿过透光方块向六邻扩散，每步衰减 2 格光值；网格生成时从缓存读取天光值写入 `COLOR.b`。跨区块通过 `_sample_skylight_global` 读取邻居 Chunk 的 `_skylight_cache`。
- 验证：在洞口观察洞壁方块，天光应从 15 向洞内逐格递减至 0；跨区块交界不应出现跳变。

### 7）导出 exe 后全白/条纹/全基岩（已解决）
- 现象：编辑器正常运行，导出后所有体素面变为白色、拉伸条纹或全部显示基岩纹理。
- 根因：导出后 `DirAccess` 枚举不可靠（`get_files()` 通常只返回 .gd/.import）；`Texture2D.get_image()` 可能返回空；BlockData 资源的 tile 映射在导出环境可能未正确应用。
- 解决：
  - 编辑器运行生成 `block_atlas.png` 并保存到 `res://resources/textures/`，导出时 `load()` 该 PNG 走 Godot 导入管线。
  - BlockRegistry 增加固定清单 `_known_block_paths` 回退加载。
  - 编辑器运行阶段将 tile 映射烘焙写入各 .tres 文件的 `tile_top/side/bottom` 字段并 `ResourceSaver.save()`。
  - 图集列数/行数从 `block_atlas.png` 实际尺寸除以 tile_pixels 推导，不依赖 base_paths 数量。
- 验证：编辑器运行一次后重新导出，exe 纹理显示应与编辑器内一致。

### 8）沙子下落丢块（已解决）
- 现象：多格沙子柱共同下落，稳定后数量减少。
- 根因：每块沙子独立生成下落实体，多实体重叠争抢落地位置。
- 解决：连续沙柱整体打包为一个下落实体（`height_blocks`），落地时逐格回填整根柱子。
- 验证：堆 5 高沙柱并挖掉底部，稳定后为 4 格高。

## 五、学习本课后的收获与体会（10分）

### 1）程序的优点与存在问题（5分）

**优点：**
- 面剔除（不生成内部面）大幅减少三角形数量，一个 16×16×N 的 Chunk 通常仅几千面，远低于"每方块 6 面"的 6N³ 量级。
- Texture Atlas 将所有方块纹理合并为一张图集，一次材质绑定即可渲染整个 Chunk，避免频繁材质切换。
- Shader 中将群系染色/侧面覆盖层/alpha 裁剪等效果统一在 fragment 中完成，新增方块只需配置 .tres 即可自动获得这些视觉效果。
- DDA 射线拾取不依赖块级碰撞体，准确且高效（O(射线步数)），支持任意距离的方块交互。
- 昼夜天空 + 云层 + 天光传播共同构成完整的户外/洞穴光照体系，视觉层次丰富。
- 沙子下落整柱打包、流式区块加载等设计在"好玩"与"性能"之间取得了良好平衡。

**存在的问题与改进方向：**
- 当前面剔除是"按邻居遮挡"的简单策略，未实现 Greedy Meshing（贪心网格合并），大面积平面（如平坦地形）仍有冗余三角形。
- 天光传播仅在 Chunk 重建时执行一次，大范围破坏方块后需要重建多个 Chunk 才能看到天光更新。
- 树生成逻辑为硬编码模板，未支持不同树种/高度/冠型变化。
- 尚未实现液体（水/岩浆）、红石等效电路系统等高阶功能。
- 世界保存/加载（序列化）尚未实现，每次启动重新生成。

### 2）程序设计的收获与体会（5分）
- **从离散数据到连续渲染的映射**：将体素数据（按列字典、稀疏存储）转换为 GPU 可渲染的 ArrayMesh，需要统一坐标体系（每个面的 4 个角点世界坐标 = local_origin + corner * voxel_scale）、绕序（CW 正面以配合 cull_back）、法线（每个面 4 个顶点共享同一法线）、UV（tile 坐标 → 归一化 UV 区间）和索引。任一环节出错都会导致"面消失/翻转/纹理错乱"。
- **Shader 是管线中的关键环节**：顶点属性（COLOR/UV2）由 CPU 端填入掩码含义（草顶面/覆盖层/群系ID/alpha_cutoff），Shader 在 fragment 中解码并驱动染色、叠加、裁剪——这种"几何 + 着色"分离的设计使渲染效果完全可配置。
- **导出兼容性不可忽视**：Godot 的编辑器运行与导出版对 `res://` 文件系统的行为不一致（DirAccess 枚举、Texture2D.get_image 可用性等），必须在设计之初就考虑"导出版走的路径"（导入管线 → load → 压缩纹理），否则会反复踩坑。
- **物理与体素的桥接**：下落实体（CharacterBody3D + 碰撞 + 重力）与体素世界（ArrayMesh + Trimesh 碰撞）之间的交互（落地射线检测 + 整柱回填）是典型的"实体系统 ↔ 网格系统"数据同步问题，体现了图形学与物理引擎的协作关系。

---

## 六、参考文献（5分）
1. Godot Engine Documentation (4.6): ArrayMesh, SurfaceTool, Shading Language, ImmediateMesh, Image, ImageTexture —— https://docs.godotengine.org/
2. Blinn, J. F. (1977). Models of light reflection for computer synthesized pictures. ACM SIGGRAPH Computer Graphics, 11(2), 192-198.
3. Amanatides, J., & Woo, A. (1987). A fast voxel traversal algorithm for ray tracing. Eurographics '87, 3-10.
4. LearnOpenGL: Face Culling, Blinn-Phong Lighting, Textures —— https://learnopengl.com/
5. Perlin, K. (1985). An image synthesizer. ACM SIGGRAPH Computer Graphics, 19(3), 287-296.
6. Minecraft Wiki: Skylight / Block Light propagation model —— https://minecraft.wiki/
