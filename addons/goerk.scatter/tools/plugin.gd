@tool
extends EditorPlugin

const Scatter3D = preload("res://addons/goerk.scatter/scatter3d.gd")
const PaletteScene = preload("res://addons/goerk.scatter/tools/palette.tscn")
const Palette = preload("./palette.gd")
const Util = preload("../util/util.gd")
const ScatterLogger = preload("../util/logger.gd")

const ACTION_PAINT = 0
const ACTION_ERASE = 1

const FOREST_MAX_ATTEMPT_MULTIPLIER = 8
const FOREST_RAY_PADDING = 10.0

var _node : Scatter3D
var _selected_patterns := []
var _mouse_position := Vector2()
var _editor_camera : Camera3D
var _collision_mask := 1
var _placed_instances = []
var _removed_instances = []
var _disable_undo := false
var _pattern_margin := 0.0
var _logger = ScatterLogger.get_for(self)
var _current_action := -1
var _cmd_pending_action := false

var _palette : Palette
var _error_dialog = null


static func get_icon(name):
	return load("res://addons/goerk.scatter/tools/icons/icon_" + name + ".svg")


func _enter_tree():
	_logger.debug("Scatter plugin Enter tree")
	# The class is globally named but still need to register it just so the node creation dialog gets it
	# https://github.com/godotengine/godot/issues/30048
	add_custom_type("Scatter3D", "Node3D", Scatter3D, get_icon("scatter3d_node"))
	
	var base_control = get_editor_interface().get_base_control()
	
	_palette = PaletteScene.instantiate()
	_palette.patterns_selected.connect(_on_Palette_patterns_selected)
	_palette.pattern_added.connect(_on_Palette_pattern_added)
	_palette.patterns_removed.connect(_on_Palette_patterns_removed)
	_palette.hide()
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, _palette)
	_palette.set_preview_provider(get_editor_interface().get_resource_previewer())
	_palette.call_deferred("setup_dialogs", base_control)

	_error_dialog = AcceptDialog.new()
	_error_dialog.min_size = Vector2i(300, 200)
	_error_dialog.hide()
	_error_dialog.title = "Error"
	base_control.add_child(_error_dialog)
	

func _exit_tree():
	_logger.debug("Scatter plugin Exit tree")
	_edit(null)
	
	remove_custom_type("Scatter3D")
	
	_palette.queue_free()
	_palette = null
	
	_error_dialog.queue_free()
	_error_dialog = null


func _handles(obj):
	return obj != null and obj is Scatter3D


func _edit(obj):
	_node = obj
	if _node:
		var patterns = _node.get_patterns()
		_palette.load_patterns(patterns)
		set_physics_process(true)
	else:
		set_physics_process(false)


func _make_visible(visible):
	_palette.set_visible(visible)
	# TODO Workaround https://github.com/godotengine/godot/issues/6459
	# When the user selects another node, I want the plugin to release its references.
	if not visible:
		_edit(null)


func _forward_3d_gui_input(p_camera, p_event):
	if _node == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	var captured_event = EditorPlugin.AFTER_GUI_INPUT_PASS
	
	if p_event is InputEventMouseButton:
		var mb = p_event
		
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			# Need to check modifiers before capturing the event,
			# because they are used in navigation schemes
			if (not mb.ctrl_pressed) and (not mb.alt_pressed):# and mb.button_index == MOUSE_BUTTON_LEFT:
				if mb.pressed:
					match mb.button_index:
						MOUSE_BUTTON_LEFT:
							_current_action = ACTION_PAINT
						MOUSE_BUTTON_RIGHT:
							_current_action = ACTION_ERASE
					_cmd_pending_action = true
				
				captured_event = EditorPlugin.AFTER_GUI_INPUT_STOP
				
				if mb.pressed == false:
					# Just finished painting gesture
					_on_action_completed(_current_action)
	
	elif p_event is InputEventMouseMotion:
		var mm = p_event
		var mouse_position = mm.position

		# Need to do an extra conversion in case the editor viewport is in half-resolution mode
		var viewport = p_camera.get_viewport()
		var viewport_container = viewport.get_parent()
		var screen_position = mouse_position * viewport.get_visible_rect().size / viewport_container.size

		_mouse_position = screen_position
		# Trigger action only if these buttons are held
		_cmd_pending_action = (mm.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT)) != 0

	_editor_camera = p_camera
	return captured_event


func _physics_process(_unused_delta):
	if _editor_camera == null:
		return
	if not is_instance_valid(_editor_camera):
		_editor_camera = null
		return
	if _node == null:
		return
	
	if _cmd_pending_action:
		# Consume
		_cmd_pending_action = false

		var ray_origin = _editor_camera.project_ray_origin(_mouse_position)
		var ray_dir = _editor_camera.project_ray_normal(_mouse_position)
		var ray_distance = _editor_camera.far

		match _current_action:
			ACTION_PAINT:
				_paint(ray_origin, ray_dir, ray_origin + ray_dir * ray_distance)
			ACTION_ERASE:
				_erase(ray_origin, ray_dir)


func _paint(ray_origin: Vector3, ray_dir: Vector3, ray_end: Vector3):
	var forest_mode := _palette.is_forest_mode_enabled()
	var forest_patterns = _get_forest_patterns()
	if forest_mode:
		if len(forest_patterns) == 0:
			return
	elif len(_selected_patterns) == 0:
		return
	
	var space_state := _node.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end, _collision_mask)
	var hit = space_state.intersect_ray(query)
	
	if not _is_paintable_hit(hit):
		return
	
	if forest_mode:
		_paint_forest(hit.position, hit.normal, ray_dir, forest_patterns)
	else:
		_paint_single(hit.position)


func _is_paintable_hit(hit: Dictionary) -> bool:
	if hit.is_empty():
		return false

	var hit_instance_root = null
	if hit.collider != null:
		hit_instance_root = Util.get_instance_root(hit.collider)

	return hit.collider == null or hit_instance_root == null or not (hit_instance_root.get_parent() is Scatter3D)


func _paint_single(pos: Vector3):
	if _is_too_close_to_placed(pos, _pattern_margin + _palette.get_configured_margin()):
		return

	var instance = _create_pattern_instance()
	_add_painted_instance(instance, pos)


func _paint_forest(center: Vector3, normal: Vector3, ray_dir: Vector3, patterns: Array):
	var amount := _palette.get_forest_amount()
	if amount <= 0:
		return

	var radius := _palette.get_forest_diameter() * 0.5
	if radius <= 0.0:
		return

	var normal_dir := normal.normalized()
	if normal_dir.is_zero_approx():
		normal_dir = Vector3.UP
	var camera_dir := ray_dir.normalized()
	if camera_dir.is_zero_approx():
		camera_dir = Vector3.DOWN

	var tangent := normal_dir.cross(Vector3.FORWARD)
	if tangent.is_zero_approx():
		tangent = normal_dir.cross(Vector3.RIGHT)
	tangent = tangent.normalized()
	var bitangent := normal_dir.cross(tangent).normalized()

	var space_state := _node.get_world_3d().direct_space_state
	var attempts := max(amount * FOREST_MAX_ATTEMPT_MULTIPLIER, amount)
	var placed_count := 0
	var margin := _palette.get_configured_margin()
	if margin <= 0.0:
		margin = _get_even_distribution_margin(radius, amount)

	if not _is_too_close_to_placed(center, margin):
		var center_instance = patterns.pick_random().instantiate()
		_add_painted_instance(center_instance, center)
		placed_count += 1

	for _i in range(attempts):
		if placed_count >= amount:
			break

		var angle := randf_range(-PI, PI)
		var distance := sqrt(randf()) * radius
		var offset := tangent * cos(angle) * distance + bitangent * sin(angle) * distance
		var sample_center := center + offset
		var ray_length := max(radius + FOREST_RAY_PADDING, FOREST_RAY_PADDING)
		var hit := _get_forest_sample_hit(space_state, sample_center, normal_dir, camera_dir, ray_length)
		var spawn_position: Vector3 = sample_center
		if not hit.is_empty():
			spawn_position = hit.position
		if _is_too_close_to_placed(spawn_position, margin):
			continue

		var instance = patterns.pick_random().instantiate()
		_add_painted_instance(instance, spawn_position)
		placed_count += 1


func _get_forest_sample_hit(space_state: PhysicsDirectSpaceState3D, sample_center: Vector3, normal_dir: Vector3, camera_dir: Vector3, ray_length: float) -> Dictionary:
	var casts := [
		[sample_center + normal_dir * ray_length, sample_center - normal_dir * ray_length],
		[sample_center + Vector3.UP * ray_length, sample_center - Vector3.UP * ray_length],
		[sample_center - camera_dir * ray_length, sample_center + camera_dir * ray_length],
	]

	for cast in casts:
		var query := PhysicsRayQueryParameters3D.create(cast[0], cast[1], _collision_mask)
		var hit := space_state.intersect_ray(query)
		if _is_paintable_hit(hit):
			return hit

	return {}


func _is_too_close_to_placed(pos: Vector3, margin: float) -> bool:
	if margin <= 0.0:
		return false

	for instance in _placed_instances:
		if is_instance_valid(instance) and instance is Node3D:
			if instance.global_position.distance_to(pos) < margin:
				return true

	return false


func _add_painted_instance(instance: Node3D, pos: Vector3):
	_node.add_child(instance)
	instance.global_position = pos
	instance.rotate_y(randf_range(-PI, PI))
	instance.owner = get_editor_interface().get_edited_scene_root()
	_placed_instances.append(instance)


func _get_valid_patterns(patterns: Array) -> Array:
	var valid_patterns := []
	for pattern in patterns:
		if pattern != null:
			valid_patterns.append(pattern)
	return valid_patterns


func _get_forest_patterns() -> Array:
	var patterns := []
	for path in _palette.get_all_pattern_paths():
		var pattern = load(path)
		if pattern != null:
			patterns.append(pattern)

	if len(patterns) == 0:
		patterns = _get_valid_patterns(_node.get_patterns())
	if len(patterns) == 0:
		patterns = _get_valid_patterns(_selected_patterns)

	return patterns


func _get_even_distribution_margin(radius: float, amount: int) -> float:
	if amount <= 1:
		return 0.0

	var area := PI * radius * radius
	return sqrt(area / amount) * 0.35


func _erase(ray_origin: Vector3, ray_dir: Vector3):
	var ray_end := ray_origin + ray_dir * _editor_camera.far
	var hits := RenderingServer.instances_cull_ray(ray_origin, ray_end, _node.get_world_3d().scenario)

	if len(hits) > 0:
		var instance = null
		for hit_object_id in hits:
			var hit = instance_from_id(hit_object_id)
			if hit is Node3D:
				instance = get_scatter_child_instance(hit, _node)
				if instance != null:
					break
		
		#print("Hits: ", len(hits), ", instance: ", instance)
		if instance != null:
			assert(instance.get_parent() == _node)
			instance.get_parent().remove_child(instance)
			_removed_instances.append(instance)


func _on_action_completed(action: int):
	if action == ACTION_PAINT:
		if len(_placed_instances) == 0:
			return
		# TODO This will creep memory until the scene is closed...
		# Because in Godot, undo/redo of node creation/deletion is done by NOT deleting them.
		# To stay in line with this, I have to do the same...
		var ur = get_undo_redo()
		ur.create_action("Paint scenes")
		for instance in _placed_instances:
			# This is what allows nodes to be freed
			ur.add_do_reference(instance)
		_disable_undo = true
		ur.add_do_method(self, "_redo_paint", _node.get_path(), _placed_instances.duplicate(false))
		ur.add_undo_method(self, "_undo_paint", _node.get_path(), _placed_instances.duplicate(false))
		ur.commit_action()
		_disable_undo = false
		_placed_instances.clear()
		
	elif action == ACTION_ERASE:
		if len(_removed_instances) == 0:
			return
		var ur = get_undo_redo()
		ur.create_action("Erase painted scenes")
		for instance in _removed_instances:
			ur.add_undo_reference(instance)
		_disable_undo = true
		ur.add_do_method(self, "_redo_erase", _node.get_path(), _removed_instances.duplicate(false))
		ur.add_undo_method(self, "_undo_erase", _node.get_path(), _removed_instances.duplicate(false))
		ur.commit_action()
		_disable_undo = false
		_removed_instances.clear()


#func resnap_instances():
#	pass


func _redo_paint(parent_path, instances_data):
	if _disable_undo:
		return
	var parent = get_node(parent_path)
	for instance in instances_data:
		parent.add_child(instance)


func _undo_paint(parent_path, instances_data):
	if _disable_undo:
		return
	var parent = get_node(parent_path)
	for instance in instances_data:
		parent.remove_child(instance)


func _redo_erase(parent_path, instances_data):
	if _disable_undo:
		return
	var parent = get_node(parent_path)
	for instance in instances_data:
		instance.get_parent().remove_child(instance)


func _undo_erase(parent_path, instances_data):
	if _disable_undo:
		return
	var parent = get_node(parent_path)
	for instance in instances_data:
		parent.add_child(instance)


# Goes up the tree from the given node and finds the first Scatter layer,
# then return the immediate child of it from which the node is child of
static func get_scatter_child_instance(node, scatter_root):
	var parent = node
	while parent != null:
		parent = node.get_parent()
		if parent != null and parent == scatter_root:
			return node
		node = parent
	return null


func _set_selected_patterns(patterns):
	if _selected_patterns != patterns:
		_selected_patterns = patterns
		var largest_aabb = AABB()
		for pattern in patterns:
			var temp = pattern.instantiate()
			# TODO This causes errors because of accessing `global_transform` outside the tree... Oo
			# See https://github.com/godotengine/godot/issues/30445
			largest_aabb = largest_aabb.merge(Util.get_scene_aabb(temp))
			temp.free()
		_pattern_margin = largest_aabb.size.length() * 0.4
		_logger.debug(str("Pattern margin is ", _pattern_margin))


func _create_pattern_instance():
	return _selected_patterns.pick_random().instantiate()


func _on_Palette_patterns_selected(pattern_paths):
	var scenes = []
	for file in pattern_paths:
		scenes.append(load(file))
	_set_selected_patterns(scenes)


func _on_Palette_pattern_added(path):
	if not _verify_scene(path):
		return
	# TODO Duh, may not work if the file was moved or renamed... I'm tired of this
	var ur = get_undo_redo()
	ur.create_action("Add scatter pattern")
	ur.add_do_method(self, "_add_pattern", path)
	ur.add_undo_method(self, "_remove_pattern", path)
	ur.commit_action()


func _on_Palette_patterns_removed(paths):
	var ur = get_undo_redo()
	ur.create_action("Remove scatter pattern")
	for path in paths:
		ur.add_do_method(self, "_remove_pattern", path)
		ur.add_undo_method(self, "_add_pattern", path)
	ur.commit_action()


func _add_pattern(path):
	_logger.debug(str("Adding pattern ", path))
	_node.add_pattern(path)
	_palette.add_pattern(path)


func _remove_pattern(path):
	_logger.debug(str("Removing pattern ", path))
	_node.remove_pattern(path)
	_palette.remove_pattern(path)


func _verify_scene(fpath):
	# Check it can be loaded
	var scene = load(fpath)
	if scene == null:
		_show_error(tr("Could not load the scene. See the console for more info."))
		return false
	
	# Check it's not already in the list
	if _node.has_pattern(fpath):
		_palette.select_pattern(fpath)
		_show_error(tr("The selected scene is already in the palette"))
		return false
	
	# Check it's not the current scene itself
	if Util.is_self_or_parent_scene(fpath, _node):
		_show_error("The selected scene can't be added recursively")
		return false
	
	# Check it inherits Node3D
#	var scene_state = scene.get_state()
#	var root_type = scene_state.get_node_type(0)
	# Aaaah screw this
	var scene_instance = scene.instantiate()
	if not (scene_instance is Node3D):
		_show_error(tr("The selected scene is not a Node3D, it can't be painted in a 3D scene."))
		scene_instance.free()
		return false
	scene_instance.free()
	
	return true


func _show_error(msg):
	_error_dialog.dialog_text = msg
	_error_dialog.popup_centered_minsize()
