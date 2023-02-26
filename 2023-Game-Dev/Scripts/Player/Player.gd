extends CharacterBody3D

const WALK_SPEED: float = 7.0
const SPRINT_MULTIPLIER: float = 2.0
const CROUCH_MULTIPLIER: float = 0.5
const TERMINAL_GRAVITATIONAL_VELOCITY := -53.0

const CROUCH_TRANSITION_SPEED: float = 0.1
const COLLIDER_REGULAR_HEIGHT: float = 1.8
const COLLIDER_CROUCH_HEIGHT: float = 0.9
const HEAD_CROUCH_HEIGHT := 0.9
const HEAD_STANDING_HEIGHT := 1.8

const MOUSE_SENSITIVITY: float = 0.002
const CAMERA_UPPER_CLAMP: float = 90.0 # These two are later converted to radians.
const CAMERA_LOWER_CLAMP: float = -90.0

const AIR_ACCELERATION: float = 10.0
const REGULAR_ACCELERATION: float = 20.0
const JUMP_POWER: float = 7.5
const GRAVITY: float = 45.0

# Camera.
var mouse_rotation := Vector3.ZERO
var camera_upper_clamp_rad: float # These two are the ones used to clamp the vertical look direction.
var camera_lower_clamp_rad: float # They get their values in radians in _ready().
var camera_position_offset: Vector3

# Movement.
var gravity_vector := Vector3()
var movement := Vector3() # Final movement direction and magnitude for one tick.
var horizontal_velocity := Vector3() # Horizontal velocity, determined by walk, crouch and sprint speeds.
var original_horizontal_velocity := Vector3() # Used for preserving momentum when transitioning between different movement states.
var input_dir := Vector3() # Input direction.
var way_facing # Used instead of basis.
var current_collider_height: float = 1.8 # Used for shrinking the collider when crouching.

# Movement states.
enum MovementStates {IN_AIR, ON_GROUND, SWIMMING, NO_CLIP}
var current_movement_state := MovementStates.IN_AIR

# Movement flags.
var is_grounded: bool = false
var can_jump: bool = false
var is_momentum_preserved: bool = false
var is_head_bonked: bool = false
var offset_velocity := Vector3.ZERO

# Input flags.
var request_sprinting: bool = false
var request_crouching: bool = false
var request_jump: bool = false

# Camera 
@onready var cam_root := $CamRoot
@onready var camera := $CamRoot/Camera
@onready var collider = $CollisionShape3D


func _ready():

	camera.current = true
	
	# Convert these two to radians because Godot likes it, I suppose.
	camera_upper_clamp_rad = deg_to_rad(CAMERA_UPPER_CLAMP)
	camera_lower_clamp_rad = deg_to_rad(CAMERA_LOWER_CLAMP)
	
	# Camera position is calculated in global space,
	# so we get the offset from the actual body by doing this.
	camera_position_offset = cam_root.global_position - global_position
	
	# Keep the mouse positioned at screen centre.
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _unhandled_input(event: InputEvent) -> void:
	
	if event is InputEventMouseButton:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	elif event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	

	input_dir = Vector3.ZERO
	way_facing = cam_root.rotation.y
	
	input_dir += -global_transform.basis.x.rotated(Vector3(0, 1 ,0), way_facing) * (Input.get_action_strength("move_left") - Input.get_action_strength("move_right"))
	input_dir += -global_transform.basis.z.rotated(Vector3(0, 1, 0), way_facing) * (Input.get_action_strength("move_forwards") - Input.get_action_strength("move_backwards"))
	
	# Ensure we aren't faster when moving diagonally.
	input_dir = input_dir.normalized()

	if event is InputEventMouseMotion:
			var relative_mouse_motion: Vector2 = event.relative
			process_camera_rotation(relative_mouse_motion)

	# These requests influence check_movement_flags(), which determines
	# the outcome of process_movement().
	if Input.is_action_pressed("sprint"):
		request_sprinting = true
	else:
		request_sprinting = false
	
	if Input.is_action_pressed("crouch"):
		request_crouching = true
	else:
		request_crouching = false
	
	if Input.is_action_pressed("jump"):
		request_jump = true
	else:
		request_jump = false

func _process(delta):
	process_camera_position()

func check_movement_state() -> void:
	# Checks the current movement state of the player 
	if is_on_floor():
		current_movement_state = MovementStates.ON_GROUND
	else:
		current_movement_state = MovementStates.IN_AIR

func process_movement_state(delta) -> void:
	match current_movement_state:
		MovementStates.ON_GROUND:
			ground_move(delta)
		MovementStates.IN_AIR:
			air_move(delta)

func ground_move(delta):
	#cancel_momentum()
	
	offset_velocity = Vector3.ZERO
	is_momentum_preserved = false
	
	# Change gravity direction so we stick to slopes if moving down them.
	# Also multiply gravity by some small value when on the ground so that we will still
	# stick to the ground, but won't immediately fall fast if we go off a slope.
	gravity_vector = -get_floor_normal() #* (GRAVITY * 0.1)
	
	if request_sprinting:
		horizontal_velocity = horizontal_velocity.lerp(
				input_dir * (WALK_SPEED * SPRINT_MULTIPLIER),
				REGULAR_ACCELERATION * delta) # TODO: is delta frame-independent?
	else:
		horizontal_velocity = horizontal_velocity.lerp(
				input_dir * WALK_SPEED,
				REGULAR_ACCELERATION * delta)
	if request_crouching:
		horizontal_velocity = horizontal_velocity * CROUCH_MULTIPLIER
	
	if request_jump:
		# print("Requested Jump")
		jump()
	
	# Movement vector calculated from horizontal direction and gravity.
	movement.z = horizontal_velocity.z + gravity_vector.z
	movement.x = horizontal_velocity.x + gravity_vector.x
	
	# Limit gravity vector by terminal velocity.
	if gravity_vector.y < TERMINAL_GRAVITATIONAL_VELOCITY:
		gravity_vector.y = TERMINAL_GRAVITATIONAL_VELOCITY
	else:
		movement.y = gravity_vector.y
	
	# Final velocity calculated from movement.
	set_velocity(movement)
	
	# Actually move the player.
	move_and_slide()
	
func air_move(delta):
	gravity_vector += Vector3.DOWN * GRAVITY * (delta / 2) # Fall to the ground.
	
	# Makes the player slow down or speed up, depending on what they hit.
	var fr_fr = get_real_velocity()
	horizontal_velocity.x = fr_fr.x
	horizontal_velocity.z = fr_fr.z
	
	
	# Get the velocity over ground from when we jumped / became airborne.
	if not is_momentum_preserved:
		original_horizontal_velocity = horizontal_velocity
		is_momentum_preserved = true
	
	offset_velocity = input_dir / 2
	
	horizontal_velocity = horizontal_velocity + offset_velocity
	
	if original_horizontal_velocity.length() <= WALK_SPEED:
		horizontal_velocity = clamp_vector(horizontal_velocity, WALK_SPEED)
	else:
		horizontal_velocity = clamp_vector(horizontal_velocity, original_horizontal_velocity.length())
	
	# Reduce or increase horizontal velocity in case we hit something.
	
	
	# Crouch sliding.
	
	# Movement vector calculated from horizontal direction and gravity.
	movement.z = horizontal_velocity.z + gravity_vector.z
	movement.x = horizontal_velocity.x + gravity_vector.x
	
	# Limit gravity vector by terminal velocity.
	if gravity_vector.y < TERMINAL_GRAVITATIONAL_VELOCITY:
		gravity_vector.y = TERMINAL_GRAVITATIONAL_VELOCITY
	else:
		movement.y = gravity_vector.y
	
	print(movement)
	
	# Final velocity calculated from movement.
	set_velocity(movement)
	
	# Actually move the player.
	move_and_slide()

func jump():
	gravity_vector = Vector3.UP * JUMP_POWER

func process_camera_rotation(relative_mouse_motion) -> void:
	# Horizontal mouse look.
	mouse_rotation.y -= relative_mouse_motion.x * MOUSE_SENSITIVITY
	# Vertical mouse look.
	mouse_rotation.x = clampf(mouse_rotation.x - (relative_mouse_motion.y * MOUSE_SENSITIVITY),
			camera_lower_clamp_rad,
			camera_upper_clamp_rad)
	
	# Rotate head independently of body.
	# This camera also determines the local direction of WASD.
	cam_root.rotation.x = mouse_rotation.x
	cam_root.rotation.y = mouse_rotation.y

func process_camera_position() -> void:
	# TODO: global and local target positions?
	
	#var camera_position = Vector3.ZERO
	
	#camera.global_position = camera_position.lerp(camera_target_position, delta)
	
	cam_root.global_position = global_position + camera_position_offset
	
#	if request_crouching:
#		camera.global_position = camera.global_position.lerp(Vector3(0, 1, 0), CROUCH_TRANSITION_SPEED)
#	else:
#		camera.global_position = camera.global_position.lerp(Vector3(0, 2, 0), CROUCH_TRANSITION_SPEED)

func handle_crouching() -> void:
	
	# Change colliders when crouching TODO explain
	# Head movement is 
	if request_crouching or is_head_bonked:
		current_collider_height -= CROUCH_TRANSITION_SPEED
		#head.translation = head.translation.linear_interpolate(Vector3(0, 1.25, 0), CROUCH_TRANSITION_SPEED)
	else:
		current_collider_height += CROUCH_TRANSITION_SPEED
		#head.translation = head.translation.linear_interpolate(Vector3(0, 1.8, 0), CROUCH_TRANSITION_SPEED)
	
	# Crouch and regular height determine the shortest and highest we can stand, respectively.
	current_collider_height = clamp(current_collider_height, COLLIDER_CROUCH_HEIGHT, COLLIDER_REGULAR_HEIGHT)
	
	collider.shape.size = Vector3(0.3, current_collider_height, 0.3)
	
# Used instead of clamp() so that the vector in question is limited
# to a circle instead of a square.

func _physics_process(delta):
	check_movement_state()
	process_movement_state(delta)

# Used instead of clamp() so that the vector in question is limited
# to a circle instead of a square.
func clamp_vector(vector: Vector3, clamp_length: float) -> Vector3:
	if vector.length() <= clamp_length:
		return vector
	return vector * (clamp_length / vector.length())
