@tool
extends MarchingSquaresTerrain
## Keep Yugen's editable height/grass data, with the game's pixel materials.
const FEATURES = preload("res://scripts/terrain_features.gd")
const EXCAVATION = preload("res://scripts/terrain_excavation.gd")
var _structural_cuts: Array[Dictionary] = FEATURES.excavations()

func prepare_cell_modifiers(chunk: MarchingSquaresTerrainChunk) -> Variant:
	# Both offsets are relative to WaterGarden, independent of its world location.
	# Snapshot Node3D transforms here; cell generation also runs on worker threads.
	return {"cuts": _structural_cuts.duplicate(true), "offset": position + chunk.position}

func modify_cell_geometry(cell: MarchingSquaresTerrainCell) -> void:
	var context: Dictionary = cell.chunk.geometry_modifier_context
	EXCAVATION.apply(cell, context.cuts, context.offset)

@export var pixel_materials := true:
	set(value):
		pixel_materials = value
		if is_inside_tree():
			apply_pixel_materials()

func _ready() -> void:
	load_finished.connect(apply_pixel_materials)
	apply_pixel_materials()

func apply_pixel_materials() -> void:
	terrain_material.shader = preload("res://shaders/reference_terrain.gdshader") if pixel_materials else preload("res://addons/MarchingSquaresTerrain/resources/shaders/mst_terrain.gdshader")
	var grass_mat := grass_mesh.material as ShaderMaterial
	grass_mat.shader = preload("res://shaders/reference_foliage.gdshader") if pixel_materials else preload("res://addons/MarchingSquaresTerrain/resources/shaders/mst_grass.gdshader")
	if pixel_materials:
		grass_mat.set_shader_parameter("leaf_texture", preload("res://assets/foliage/grassleaf.png"))
		grass_mat.set_shader_parameter("path_clearance", preload("res://assets/roads/grass_clearance.res"))
		grass_mat.set_shader_parameter("path_world_to_map", get_parent().global_transform.affine_inverse())
		grass_mat.set_shader_parameter("use_path_clearance", true)
	else:
		force_batch_update()
	for chunk: MarchingSquaresTerrainChunk in chunks.values():
		if chunk.mesh:
			chunk.mesh.surface_set_material(0, terrain_material)
		if chunk.grass_planter:
			chunk.grass_planter.multimesh.mesh = grass_mesh
			# Billboard rotation and wind extend beyond the original flat card AABB.
			# Includes the strongest wind plus nearby player displacement.
			chunk.grass_planter.extra_cull_margin = 1.6
