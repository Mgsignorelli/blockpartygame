extends CharacterBody3D

# @export makes these editable in the Inspector
@export var mouse_sensitivity = 0.015
@export var camera_arm_distance = 3.0  # How far camera sits behind player
@export var camera_orbit_height = 1.4  # Height of camera pivot above player origin
@export var speed = 5.0
@export var turn_speed = 10.0
@export var jump_velocity = 4.5
@export var break_distance = 8.0  # How far player can break blocks (in blocks)

# Block names — must match item names in your MeshLibrary exactly.
# Used to decide what fill block to place depending on depth.
@export var dirt_block_name: String = "BlockDirt"
@export var surface_block_name: String = "BlockDirtWithGrass"
@export var snow_block_name: String = "BlockDirtWithSnow"

# GridMap Y at or below this value is considered "underground" → place Dirt.
# Tune this in the Inspector to match your world's surface level.
@export var underground_y_threshold: int = -1
# At or above snow_line_y_threshold → place BlockDirtWithSnow.
# These should match floor_y and (floor_y + snow_height) from your terrain script. 
@export var snow_line_y_threshold: int = 5

# Add your GridMap node into this slot in the inspector
@export var terrain: GridMap

# Internal variables used for animation states
var jumping = false
var last_floor = true
var breaking_block = false
var placing_block = false
var broken_cells: Array[Vector3i] = []  # Tracks all previously destroyed cell positions

# @onready assigns this when the node enters the scene tree
# SpringArm3D keeps the camera at a set distance and prevents wall clipping
@onready var camera_arm = $SpringArm3D
@onready var camera = $SpringArm3D/Camera3D
@onready var animation = $AnimationTree
@onready var animation_state = $AnimationTree.get("parameters/playback")

# _ready() runs ONCE when the node and its children are initialized
func _ready():
		# Hide the player and stop them from doing anything
	# Like keeping an actor backstage until the set is built
	visible = false
	set_physics_process(false)

	# Wait for the terrain to say it's finished
	# This pauses _ready() here until the signal fires — like waiting for a green light
	await terrain.terrain_ready

	# Terrain is done — put the player on stage!
	# Position them in the safe zone, slightly above the floor so they don't clip
	global_position = Vector3(0, 2, 0)
	visible = true
	set_physics_process(true)
	
	# Capture mouse: hides cursor and locks it to window
	# This allows unlimited mouse movement for camera rotation
	# (otherwise mouse would stop at screen edges)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	# Set the initial position of the camera
	camera_arm.spring_length = camera_arm_distance
	camera_arm.global_position = global_position + Vector3(0, camera_orbit_height, 0)
	
	# Top-level makes the camera arm ignore parent's rotation
	# So when the player turns, the camera doesn't turn with them
	camera_arm.set_as_top_level(true)

# _physics_process() runs at a fixed rate (60 FPS by default), synced with physics
# Use for movement, physics, and gameplay logic
func _physics_process(delta):
	# Keep camera centered on player (top-level nodes don't follow parent automatically)
	camera_arm.global_position = global_position + Vector3(0, camera_orbit_height, 0)

	if not is_on_floor():
		velocity += get_gravity() * delta

	var forward = -camera_arm.global_transform.basis.z
	forward.y = 0
	forward = forward.normalized()
	
	if Input.is_action_pressed("forwards"):
		velocity.x = forward.x * speed
		velocity.z = forward.z * speed
		face_direction(forward, delta)
		animation.set("parameters/IWR/blend_position", 1.0)
		
	elif Input.is_action_pressed("backwards"):
		velocity.x = -forward.x * speed / 3.0
		velocity.z = -forward.z * speed / 3.0
		face_direction(forward, delta)
		animation.set("parameters/IWR/blend_position", -0.3)
		
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
		animation.set("parameters/IWR/blend_position", 0.0)

	move_and_slide()

	# We jumped
	if is_on_floor() and Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity
		jumping = true
		animation.set("parameters/conditions/grounded", false)

	animation.set("parameters/conditions/jumping", jumping)

	# We landed
	if is_on_floor() and not last_floor:
		jumping = false
		animation.set("parameters/conditions/grounded", true)

	# We fell
	if not is_on_floor() and not jumping:
		animation_state.travel("JumpAir")
		animation.set("parameters/conditions/grounded", false)

	last_floor = is_on_floor()
	
	# Block breaking - trigger animation for one frame
	if Input.is_action_just_pressed("break_block"):
		attempt_break_block(delta)
		breaking_block = true
		animation.set("parameters/conditions/breaking_block", true)
	elif breaking_block:
		# Reset the condition in the next frame
		animation.set("parameters/conditions/breaking_block", false)
		breaking_block = false

	# Block placing - trigger animation for one frame
	if Input.is_action_just_pressed("place_block"):
		attempt_place_block()
		placing_block = true
		animation.set("parameters/conditions/placing_block", true)
	elif placing_block:
		# Reset the condition in the next frame
		animation.set("parameters/conditions/placing_block", false)
		placing_block = false

func attempt_break_block(delta):
	# Cast a ray from the center of the screen
	var viewport_size = get_viewport().get_visible_rect().size
	var screen_center = viewport_size / 2.0
	
	# Get ray origin and direction from camera
	var ray_origin = camera.project_ray_origin(screen_center)
	var ray_direction = camera.project_ray_normal(screen_center)
	var ray_end = ray_origin + ray_direction * break_distance
	
	# Set up physics raycast
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = [self]  # Don't hit the player itself!
	
	# Perform the raycast
	var result = space_state.intersect_ray(query)
	
	# If we hit something
	if result:
		var hit_position = result.position
		
		# Check if we're within break distance of the player
		var distance_to_player = global_position.distance_to(hit_position)
		if distance_to_player > break_distance:
			return
			
		# Rotate player to face the block horizontally
		var direction_to_block = (hit_position - global_position)
		rotation.y = atan2(direction_to_block.x, direction_to_block.z)
		
		# Move forward along the ray to get inside the block
		var adjusted_position = hit_position + ray_direction * 0.5
		
		# Convert world position to GridMap cell coordinates
		var cell_pos = terrain.local_to_map(terrain.to_local(adjusted_position))
		
		# Check if there's actually a block at this position
		var item = terrain.get_cell_item(cell_pos)
		if item != GridMap.INVALID_CELL_ITEM:
			# Record this cell as destroyed so fills never reclaim it
			broken_cells.append(cell_pos)

			# Fill adjacent empty cells BEFORE removing the block,
			# so the player is never left standing over a void.
			fill_adjacent_blocks(cell_pos)
			
			# Now remove the block
			terrain.set_cell_item(cell_pos, GridMap.INVALID_CELL_ITEM)


# Fills any empty cells that are orthogonally adjacent to `broken_cell`.
#
# Rules enforced here:
#   1. Only cells directly next to the broken block are considered (the 6
#      face-neighbours: ±X, ±Y, ±Z).
#   2. The broken cell itself is never filled — it must become empty.
#   3. A cell is only filled if it is currently empty (INVALID_CELL_ITEM),
#      so existing blocks are never overwritten.
#   4. Cells at or below `underground_y_threshold` receive a Dirt block;
#      cells above receive the surface block. Both are resolved by name from
#      the MeshLibrary so you can rename them freely in the Inspector.
func fill_adjacent_blocks(broken_cell: Vector3i) -> void:
	var dirt_id: int = terrain.mesh_library.find_item_by_name(dirt_block_name)
	var surface_id: int = terrain.mesh_library.find_item_by_name(surface_block_name)
	for item_id in terrain.mesh_library.get_item_list():
		print("  id=", item_id, " name='", terrain.mesh_library.get_item_name(item_id), "'")

	if dirt_id == -1:
		push_error("fill_adjacent_blocks: MeshLibrary has no item named '%s' — check dirt_block_name in the Inspector" % dirt_block_name)
	if surface_id == -1:
		push_error("fill_adjacent_blocks: MeshLibrary has no item named '%s' — check surface_block_name in the Inspector" % surface_block_name)
	if dirt_id == -1 or surface_id == -1:
		return


	var neighbours = [
		# Face neighbours (6)
		Vector3i( 1,  0,  0),
		Vector3i(-1,  0,  0),
		Vector3i( 0,  1,  0),
		Vector3i( 0, -1,  0),
		Vector3i( 0,  0,  1),
		Vector3i( 0,  0, -1),
		# Edge diagonals (12)
		Vector3i( 1,  1,  0),
		Vector3i(-1,  1,  0),
		Vector3i( 1, -1,  0),
		Vector3i(-1, -1,  0),
		Vector3i( 1,  0,  1),
		Vector3i(-1,  0,  1),
		Vector3i( 1,  0, -1),
		Vector3i(-1,  0, -1),
		Vector3i( 0,  1,  1),
		Vector3i( 0, -1,  1),
		Vector3i( 0,  1, -1),
		Vector3i( 0, -1, -1),
	]

	for offset in neighbours:
		var candidate: Vector3i = broken_cell + offset

		# Rule 2: never fill a cell the player has already destroyed
		if candidate in broken_cells:
			continue

		# Rule 3: only fill empty cells — never overwrite existing terrain
		if terrain.get_cell_item(candidate) != GridMap.INVALID_CELL_ITEM:
			continue

		# Rule 5: only fill cells that are underground — i.e. there is at least
		# one solid block somewhere above this candidate in the same column.
		# If nothing is above it, it's open air and should stay empty.
		var is_underground = false
		var check = Vector3i(candidate.x, candidate.y + 1, candidate.z)
		while check.y <= broken_cell.y + 64:
			if terrain.get_cell_item(check) != GridMap.INVALID_CELL_ITEM:
				is_underground = true
				break
			check.y += 1
		if not is_underground:
			continue

		# Rule 4: depth decides the block type
		var block_id: int = dirt_id if candidate.y <= underground_y_threshold else surface_id
		terrain.set_cell_item(candidate, block_id)

func attempt_place_block():
	# Cast a ray from the center of the screen — same as break
	var viewport_size = get_viewport().get_visible_rect().size
	var screen_center = viewport_size / 2.0

	var ray_origin = camera.project_ray_origin(screen_center)
	var ray_direction = camera.project_ray_normal(screen_center)
	var ray_end = ray_origin + ray_direction * break_distance

	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = [self]

	var result = space_state.intersect_ray(query)
	if not result:
		return

	# The hit normal points outward from the face that was struck.
	# Stepping half a unit along it puts us in the empty cell just outside
	# the block — that's where the new block goes.
	var place_position = result.position + result.normal * 0.5
	var cell_pos = terrain.local_to_map(terrain.to_local(place_position))

	# Rotate player to face the block horizontally
	var direction_to_block = (result.position - global_position)
	rotation.y = atan2(direction_to_block.x, direction_to_block.z)

	# Don't place inside the player
	var player_cell = terrain.local_to_map(terrain.to_local(global_position))
	if cell_pos == player_cell:
		return

	# Don't place where a block already exists
	if terrain.get_cell_item(cell_pos) != GridMap.INVALID_CELL_ITEM:
		return

	var block_id = block_name_for_depth(cell_pos.y) 
	if block_id == -1: 
		return

	terrain.set_cell_item(cell_pos, block_id)

# Returns the correct MeshLibrary item ID for a given GridMap Y coordinate.
# Mirrors the same three-zone logic used by the terrain generator:
#   — At or below underground_y_threshold     → BlockDirt
#   — Above threshold, below snow line        → BlockDirtWithGrass
#   — At or above snow_line_y_threshold       → BlockDirtWithSnow
func block_name_for_depth(cell_y: int) -> int:
	var block_name: String
	if cell_y <= underground_y_threshold:
		block_name = dirt_block_name
	elif cell_y < snow_line_y_threshold:
		block_name = surface_block_name
	else:
		block_name = snow_block_name
	var id = terrain.mesh_library.find_item_by_name(block_name)
	if id == -1:
		push_error("block_id_for_depth: MeshLibrary has no item named '%s'" % block_name)
	return id

func face_direction(direction, delta):
	var target_angle = atan2(direction.x, direction.z)
	# lerp_angle smoothly interpolates between angles, handling the 360°/0° wraparound
	rotation.y = lerp_angle(rotation.y, target_angle, turn_speed * delta)

# _unhandled_input() receives input events that weren't consumed by UI elements
# Good for player controls since menus get first chance to handle input
func _unhandled_input(event):
	if event is InputEventMouseMotion:
		# Vertical look (up/down) - inverted because screen Y is opposite to 3D rotation
		camera_arm.rotation.x -= event.relative.y * mouse_sensitivity
		# Clamp vertical rotation to prevent camera flipping upside down or going underground
		# Limited to -90° (straight down) to +30° (slightly up)
		camera_arm.rotation.x = clamp(camera_arm.rotation.x, deg_to_rad(-90), deg_to_rad(30))
		
		# Horizontal look (left/right) - no clamp needed, 360° rotation is expected
		camera_arm.rotation.y -= event.relative.x * mouse_sensitivity

	# Escape key releases mouse cursor
	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
