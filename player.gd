extends CharacterBody3D

# @export makes these editable in the Inspector
@export var mouse_sensitivity = 0.015
@export var camera_arm_distance = 3.0  # How far camera sits behind player
@export var camera_orbit_height = 1.4  # Height of camera pivot above player origin
@export var speed = 5.0
@export var turn_speed = 10.0
@export var jump_velocity = 4.5

# Add your GridMap node into this slot in the inspector
@export var terrain: GridMap

# Internal variables used for animation states
var jumping = false
var last_floor = true

# @onready assigns this when the node enters the scene tree
# SpringArm3D keeps the camera at a set distance and prevents wall clipping
@onready var camera_arm = $SpringArm3D
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
