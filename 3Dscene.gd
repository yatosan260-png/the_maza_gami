tool
extends Spatial

# ---------------------------------------------------------------------------
# This script builds the level around the (procedurally placed) maze walls:
#   1. Gives every wall real collision so the player can no longer walk
#      through them.
#   2. Generates a proper floor (with collision) sized to fit the maze.
#   3. Applies a grungy, horror-appropriate material to the walls & floor.
#   4. Tweaks the environment (fog / ambient light / background) for mood.
#
# Everything here runs only in-game (Engine.is_editor_hint() guards it),
# so it never interferes with the "Maze Gen 3D" editor plugin/dock.
# ---------------------------------------------------------------------------

export var wall_tile_scale = 3.0
export var floor_tile_scale = 8.0
export var wall_color = Color(0.32, 0.30, 0.29)
export var floor_color = Color(0.10, 0.09, 0.085)
export var floor_margin = 2.0
export var floor_thickness = 0.4

# Minimum world-space thickness (in meters) any wall's collision box is
# allowed to have. The visual wall meshes are paper-thin (as little as
# ~0.1m), and a thin *concave* trimesh collider is basically one-sided in
# Godot's physics -- a fast-moving KinematicBody (the player) can dip a
# little way into it before a collision is even registered, which is what
# let the player clip halfway into walls and get stuck. Building a solid
# BoxShape instead, padded up to this thickness, fixes that completely.
const WALL_COLLISION_MIN_THICKNESS = 0.18

# Keys must keep at least this much clearance (meters) from any wall
# collision box, measured from the key's own pivot. This is verified with
# a real physics query at spawn time, so keys can never end up embedded in
# or clipping through a wall regardless of exactly how the maze geometry
# was authored.
const KEY_WALL_CLEARANCE = 0.45

# --- Gameplay: 30s timer -> snake, keys, win/lose screens ------------------
export (PackedScene) var game_hud_scene = preload("res://ui/GameHUD.tscn")
export (PackedScene) var game_over_scene = preload("res://ui/GameOverScreen.tscn")
export (PackedScene) var victory_scene = preload("res://ui/VictoryScreen.tscn")
export (PackedScene) var snake_scene = preload("res://enemies/snake/Snake.tscn")
export (PackedScene) var key_scene = preload("res://items/key/Key.tscn")

func _ready():
	randomize()
	if Engine.is_editor_hint():
		return
	_setup_level()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# Re-apply the saved graphics/volume settings now that this scene's
	# lights and WorldEnvironment actually exist.
	Settings.apply_settings()
	_setup_gameplay()

# Used by the "Maze Gen 3D" editor dock to (re)build the maze in the editor.
func _generate():
	$maze.create_maze()
	yield(get_tree().create_timer(5.0), "timeout")
	$maze.randomly_move_walls()

func _setup_level():
	var wall_material = _create_horror_material(wall_color, wall_tile_scale)
	var floor_material = _create_horror_material(floor_color, floor_tile_scale)

	var bounds = _fix_up_walls($maze, wall_material)
	_create_floor(bounds, floor_material)
	_style_location_markers()
	_setup_atmosphere()

# Adds solid collision + a material to every wall MeshInstance under "maze",
# and returns the world-space AABB that encloses them all (used to size the
# floor automatically, whatever the maze's size ends up being).
func _fix_up_walls(maze_node: Node, material: Material) -> AABB:
	var bounds := AABB()
	var first := true

	for wall in maze_node.get_children():
		if not (wall is MeshInstance):
			continue

		wall.set_surface_material(0, material)

		var local_aabb = wall.get_aabb()
		var gt = wall.global_transform
		for i in range(8):
			var corner = gt.xform(local_aabb.get_endpoint(i))
			if first:
				bounds = AABB(corner, Vector3())
				first = false
			else:
				bounds = bounds.expand(corner)

		# Only add collision if we haven't already built one for this wall
		# (keeps this idempotent if _setup_level ever runs twice).
		if not wall.has_meta("solid_collision_added"):
			_add_wall_collision(wall, local_aabb, gt)
			wall.set_meta("solid_collision_added", true)

	return bounds

# Builds a solid, axis-aligned StaticBody + BoxShape that exactly covers a
# wall's real world-space footprint (padded on its thin axis so it can
# never be tunneled through). A box primitive is used instead of
# wall.create_trimesh_collision() because a concave/trimesh shape is
# effectively one-sided in Godot's physics engine -- it let the player's
# KinematicBody clip partway into thin walls and get stuck. The body is
# parented under the maze node (which sits at the origin with no scale),
# positioned in world space, so it works correctly no matter what
# transform the wall mesh itself ends up with.
func _add_wall_collision(wall: MeshInstance, local_aabb: AABB, gt: Transform) -> void:
	var corner_a = gt.xform(local_aabb.position)
	var corner_b = gt.xform(local_aabb.position + local_aabb.size)
	var world_min = Vector3(min(corner_a.x, corner_b.x), min(corner_a.y, corner_b.y), min(corner_a.z, corner_b.z))
	var world_max = Vector3(max(corner_a.x, corner_b.x), max(corner_a.y, corner_b.y), max(corner_a.z, corner_b.z))
	var center = (world_min + world_max) * 0.5
	var half_extents = (world_max - world_min) * 0.5

	# Whichever horizontal axis is thinner is the wall's "through" axis --
	# pad only that one so the wall doesn't visually get any thicker than
	# it needs to be, but is always solid enough to stop the player.
	var min_half_thickness = WALL_COLLISION_MIN_THICKNESS * 0.5
	if half_extents.x < half_extents.z:
		half_extents.x = max(half_extents.x, min_half_thickness)
	else:
		half_extents.z = max(half_extents.z, min_half_thickness)

	var body := StaticBody.new()
	body.name = "WallCollision"
	body.add_to_group("maze_walls")

	var box := BoxShape.new()
	box.extents = half_extents
	var shape := CollisionShape.new()
	shape.shape = box
	body.add_child(shape)

	wall.add_child(body)
	# Cancel out the wall's own (possibly non-uniform) scale/position so
	# the box we just sized in world space lands exactly where intended.
	body.global_transform = Transform(Basis(), center)

# Builds a floor (visual mesh + collision) that covers the maze's footprint.
func _create_floor(bounds: AABB, material: Material):
	if get_node_or_null("Floor"):
		get_node("Floor").queue_free()

	# Fallback size in case no walls were found for some reason.
	var min_x = -floor_margin
	var min_z = -floor_margin
	var max_x = 10.0 + floor_margin
	var max_z = 10.0 + floor_margin

	if bounds.size.length() > 0:
		min_x = bounds.position.x - floor_margin
		min_z = bounds.position.z - floor_margin
		max_x = bounds.position.x + bounds.size.x + floor_margin
		max_z = bounds.position.z + bounds.size.z + floor_margin

	var size_x = max_x - min_x
	var size_z = max_z - min_z
	var center_x = (min_x + max_x) * 0.5
	var center_z = (min_z + max_z) * 0.5

	# The player spawns right around y = 0, so the floor's top surface
	# should sit exactly at y = 0.
	var floor_top_y := 0.0

	var floor_body := StaticBody.new()
	floor_body.name = "Floor"
	floor_body.translation = Vector3(center_x, floor_top_y - floor_thickness * 0.5, center_z)

	var box_shape := BoxShape.new()
	box_shape.extents = Vector3(size_x * 0.5, floor_thickness * 0.5, size_z * 0.5)
	var collision_shape := CollisionShape.new()
	collision_shape.shape = box_shape
	floor_body.add_child(collision_shape)

	var cube_mesh := CubeMesh.new()
	cube_mesh.size = Vector3(size_x, floor_thickness, size_z)
	var mesh_instance := MeshInstance.new()
	mesh_instance.mesh = cube_mesh
	mesh_instance.set_surface_material(0, material)
	floor_body.add_child(mesh_instance)

	add_child(floor_body)

# Gives the start/exit marker spheres a subtle glow so they read as
# gameplay markers rather than stray geometry.
func _style_location_markers():
	var markers = get_tree().get_nodes_in_group("locations")
	for i in range(markers.size()):
		var marker = markers[i]
		if not (marker is MeshInstance):
			continue
		var mat = SpatialMaterial.new()
		mat.flags_unshaded = false
		mat.albedo_color = Color(0.15, 0.15, 0.15)
		if i == 0:
			mat.emission_enabled = true
			mat.emission = Color(0.2, 0.9, 0.4)
			mat.emission_energy = 1.5
		else:
			mat.emission_enabled = true
			mat.emission = Color(0.9, 0.15, 0.15)
			mat.emission_energy = 1.5
		marker.set_surface_material(0, mat)

# Procedurally generates a grungy, desaturated material (no external
# texture files needed) suitable for a horror-game corridor.
func _create_horror_material(base_color: Color, tile_scale: float) -> SpatialMaterial:
	var albedo_noise_source := OpenSimplexNoise.new()
	albedo_noise_source.seed = randi()
	albedo_noise_source.period = 18.0
	albedo_noise_source.octaves = 4
	albedo_noise_source.persistence = 0.55

	var albedo_noise := NoiseTexture.new()
	albedo_noise.noise = albedo_noise_source
	albedo_noise.width = 128
	albedo_noise.height = 128
	albedo_noise.seamless = true

	var ao_noise_source := OpenSimplexNoise.new()
	ao_noise_source.seed = randi()
	ao_noise_source.period = 6.0
	ao_noise_source.octaves = 3

	var ao_noise := NoiseTexture.new()
	ao_noise.noise = ao_noise_source
	ao_noise.width = 128
	ao_noise.height = 128
	ao_noise.seamless = true

	var mat := SpatialMaterial.new()
	mat.albedo_color = base_color
	mat.albedo_texture = albedo_noise
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.ao_enabled = true
	mat.ao_texture = ao_noise
	mat.ao_light_affect = 0.7
	# Triplanar mapping means every wall/floor box looks correctly textured
	# no matter its size or aspect ratio, without needing manual UVs.
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3(tile_scale, tile_scale, tile_scale)

	# A faint fresnel/rim highlight makes edges and corners catch light and
	# read clearly against the dark background and fog, so the player can
	# actually see where a wall is before walking into it, without making
	# the level look flatly lit or losing the horror mood.
	mat.rim_enabled = true
	mat.rim = 0.12
	mat.rim_tint = 0.45

	return mat

# Darkens/fogs the environment so the maze reads as an eerie, enclosed
# space instead of an open, brightly lit grid.
func _setup_atmosphere():
	var world_env = get_node_or_null("WorldEnvironment")
	if world_env and world_env.environment:
		var env: Environment = world_env.environment
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.015, 0.015, 0.02)
		# Brighter ambient light than before -- the walls need to be
		# readable at a glance, not just atmospheric. Fog now starts a bit
		# farther out so the corridor directly around the player stays
		# clear instead of hazing over the very walls they need to dodge.
		env.ambient_light_color = Color(0.035, 0.04, 0.055)
		env.ambient_light_energy = 0.22
		env.fog_enabled = true
		env.fog_color = Color(0.02, 0.02, 0.03)
		env.fog_depth_enabled = true
		env.fog_depth_begin = 5.0
		env.fog_depth_end = 22.0
		env.fog_depth_curve = 1.5

		var light = world_env.get_node_or_null("DirectionalLight")
		if light:
			light.light_energy = 0.12
			light.light_color = Color(0.45, 0.48, 0.55)

# ---------------------------------------------------------------------------
# Gameplay: HUD, the 3 keys, and the snake that spawns after the 40-second
# countdown. Key positions are selected from the actual walkable maze
# component instead of fixed/random coordinates.
# ---------------------------------------------------------------------------
func _setup_gameplay():
	add_child(game_hud_scene.instance())

	var game_over_screen = game_over_scene.instance()
	add_child(game_over_screen)

	var victory_screen = victory_scene.instance()
	add_child(victory_screen)

	GameState.connect("snake_spawn_requested", self, "_spawn_snake")
	GameState.connect("player_died", game_over_screen, "show_game_over")
	GameState.connect("player_won", victory_screen, "show_victory")

	_spawn_keys()
	GameState.start_game()

func _cell_center(cell_x, cell_z) -> Vector3:
	var cs = $maze.cell_size
	return Vector3((cell_x + 0.5) * cs, 0.0, (cell_z + 0.5) * cs)

func _player_start_cell() -> Vector2:
	var player = get_node_or_null("Player")
	var cs = $maze.cell_size
	if player:
		return Vector2(
			clamp(int(floor(player.global_transform.origin.x / cs)), 0, int($maze.maze_size.x) - 1),
			clamp(int(floor(player.global_transform.origin.z / cs)), 0, int($maze.maze_size.z) - 1)
		)
	return Vector2(0, 0)

# Tests the real wall collision between two adjacent cells. This prevents
# keys/snake positions from being chosen on the wrong side of a wall.
func _cells_are_connected(a: Vector2, b: Vector2) -> bool:
	var from = _cell_center(int(a.x), int(a.y)) + Vector3(0, 0.75, 0)
	var to = _cell_center(int(b.x), int(b.y)) + Vector3(0, 0.75, 0)
	var exclude = [self]
	var player = get_node_or_null("Player")
	if player:
		exclude.append(player)
	var hit = get_world().direct_space_state.intersect_ray(from, to, exclude)
	return hit.empty()

# Returns every cell that is actually reachable from the player's starting
# cell according to the generated maze's real collision walls.
func _get_reachable_cells() -> Array:
	var mx = int($maze.maze_size.x)
	var mz = int($maze.maze_size.z)
	var start = _player_start_cell()
	var queue = [start]
	var visited = {}
	var distances = {}
	var key = str(int(start.x)) + ":" + str(int(start.y))
	visited[key] = true
	distances[key] = 0
	var result = []

	while queue.size() > 0:
		var current = queue.pop_front()
		result.append(current)
		var current_key = str(int(current.x)) + ":" + str(int(current.y))
		var current_distance = distances[current_key]

		var directions = [
			Vector2(1, 0), Vector2(-1, 0),
			Vector2(0, 1), Vector2(0, -1)
		]

		for direction in directions:
			var next = current + direction
			if next.x < 0 or next.x >= mx or next.y < 0 or next.y >= mz:
				continue
			var next_key = str(int(next.x)) + ":" + str(int(next.y))
			if visited.has(next_key):
				continue
			if not _cells_are_connected(current, next):
				continue

			visited[next_key] = true
			distances[next_key] = current_distance + 1
			queue.append(next)

	return result

func _cell_graph_distance(a: Vector2, b: Vector2) -> int:
	# The maze is small, so a short BFS is safer than assuming Euclidean
	# distance means the player can actually reach the position.
	if a == b:
		return 0

	var mx = int($maze.maze_size.x)
	var mz = int($maze.maze_size.z)
	var queue = [a]
	var visited = {str(int(a.x)) + ":" + str(int(a.y)): true}
	var distances = {str(int(a.x)) + ":" + str(int(a.y)): 0}

	while queue.size() > 0:
		var current = queue.pop_front()
		var current_key = str(int(current.x)) + ":" + str(int(current.y))
		var distance = distances[current_key]

		for direction in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
			var next = current + direction
			if next.x < 0 or next.x >= mx or next.y < 0 or next.y >= mz:
				continue
			var next_key = str(int(next.x)) + ":" + str(int(next.y))
			if visited.has(next_key):
				continue
			if not _cells_are_connected(current, next):
				continue
			if next == b:
				return distance + 1
			visited[next_key] = true
			distances[next_key] = distance + 1
			queue.append(next)

	return 9999

func _spawn_keys():
	# Every new round gets a fresh randomized key layout. The candidates are
	# real reachable maze cells, then we shuffle them so restarting after a
	# death or victory does not reproduce the same three locations.
	var reachable = _get_reachable_cells()
	if reachable.size() < 3:
		return

	var start_cell = _player_start_cell()
	var candidates = []
	for cell in reachable:
		var distance = _cell_graph_distance(start_cell, cell)
		if distance >= 3 and not cell.is_equal_approx(start_cell):
			candidates.append(cell)

	if candidates.size() < 3:
		candidates = reachable.duplicate()

	# Randomize the candidate order for every scene reload/round.
	candidates.shuffle()

	var selected = []
	for cell in candidates:
		if selected.size() >= 3:
			break
		var far_enough_from_existing = true
		for chosen in selected:
			if _cell_graph_distance(cell, chosen) < 2:
				far_enough_from_existing = false
				break
		if far_enough_from_existing:
			selected.append(cell)

	# If the maze is too small to satisfy the spacing rule, fill the remaining
	# slots from the randomized candidate list.
	if selected.size() < 3:
		for cell in candidates:
			if selected.size() >= 3:
				break
			if not selected.has(cell):
				selected.append(cell)

	for cell in selected:
		var pos = _find_clear_key_position(cell)
		if pos == null:
			# Every spot we tried in this cell was too close to a wall --
			# skip it rather than ever placing a key inside geometry.
			continue
		var key_instance = key_scene.instance()
		add_child(key_instance)
		key_instance.global_transform.origin = pos

# Finds a spot inside the given maze cell that is verified, via a real
# physics query, to be clear of every wall's collision box. Starts at the
# cell's exact center and, if that happens to be too close to a wall,
# searches a small ring of nearby offsets before giving up. This means keys
# can never visually end up embedded in or overlapping a wall, regardless
# of how the maze's wall geometry was generated.
func _find_clear_key_position(cell: Vector2):
	var center = _cell_center(int(cell.x), int(cell.y))
	center.y = 0.28

	if _is_clear_of_walls(center, KEY_WALL_CLEARANCE):
		return center

	var cs = $maze.cell_size
	var step = cs * 0.2
	for radius_steps in range(1, 4):
		var r = step * radius_steps
		var offsets = [
			Vector3(r, 0, 0), Vector3(-r, 0, 0),
			Vector3(0, 0, r), Vector3(0, 0, -r),
			Vector3(r, 0, r), Vector3(-r, 0, r),
			Vector3(r, 0, -r), Vector3(-r, 0, -r)
		]
		for offset in offsets:
			var candidate = center + offset
			if _is_clear_of_walls(candidate, KEY_WALL_CLEARANCE):
				return candidate

	return null

# True if a sphere of the given radius at `pos` does not overlap any of the
# maze's wall collision boxes (the "maze_walls" group, added in
# _add_wall_collision). Ignores everything else (floor, player, items).
func _is_clear_of_walls(pos: Vector3, radius: float) -> bool:
	var space_state = get_world().direct_space_state
	var query = PhysicsShapeQueryParameters.new()
	var shape = SphereShape.new()
	shape.radius = radius
	query.set_shape(shape)
	query.transform = Transform(Basis(), pos)
	query.collide_with_bodies = true
	query.collide_with_areas = false

	var results = space_state.intersect_shape(query, 8)
	for result in results:
		var collider = result.get("collider")
		if collider and collider.is_in_group("maze_walls"):
			return false
	return true

func _spawn_snake():
	if get_node_or_null("Snake"):
		return

	var snake = snake_scene.instance()
	snake.name = "Snake"
	add_child(snake)

	var reachable = _get_reachable_cells()
	var player_cell = _player_start_cell()

	# Spawn well away from the player. Prefer a location roughly 7-10 maze
	# steps away so the snake is visible but never appears right beside the
	# player when the 40-second countdown ends.
	var preferred = []
	for cell in reachable:
		var distance = _cell_graph_distance(player_cell, cell)
		if distance >= 7 and distance <= 11:
			preferred.append(cell)

	if preferred.empty():
		for cell in reachable:
			if _cell_graph_distance(player_cell, cell) >= 6:
				preferred.append(cell)

	var best_cell = null
	if not preferred.empty():
		preferred.shuffle()
		best_cell = preferred[0]
	else:
		# Final fallback: use the farthest reachable cell.
		var best_distance = -1
		for cell in reachable:
			var distance = _cell_graph_distance(player_cell, cell)
			if distance > best_distance:
				best_distance = distance
				best_cell = cell

	if best_cell == null:
		best_cell = Vector2(int($maze.maze_size.x / 2), int($maze.maze_size.z / 2))

	var spawn_pos = _cell_center(int(best_cell.x), int(best_cell.y))
	spawn_pos.y = 0.18
	snake.global_transform.origin = spawn_pos

	# Let the player clearly see where the snake spawned before the chase begins.
	snake.set_physics_process(false)
	yield(get_tree().create_timer(0.9), "timeout")
	if is_instance_valid(snake) and not GameState.is_round_over():
		snake.set_physics_process(true)
