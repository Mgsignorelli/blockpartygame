# Builds terrain with hills AND valleys — continuous ground that rises and falls.
# Uses noise to make everything look organic and natural, like real terrain.
# Valleys are always escapable — the walls never jump more than 1 block,
# so the player can always climb out.
# Different block types are used depending on height and position:
# — Underground blocks are plain dirt
# — Surface blocks near floor level get grass
# — Surface blocks high up get snow, like a mountain top
# Only places blocks that are actually visible — no wasted buried blocks.
# The seed means the same number always makes the same pattern.
# There's always a safe area in the middle so the player starts on flat ground!
# Attach it to a GridMap node.
extends GridMap

# The magic number that controls the random pattern
# Same seed = same floor every time, like a saved world in Minecraft
@export var seed_number: int = 12345

# How many blocks wide the floor is (left to right)
@export var floor_width: int = 256
# How many blocks deep the floor is (front to back)
@export var floor_depth: int = 256

# Which level to put the floor on (-1 means one layer underground, like a basement)
@export var floor_y: int = -1

# --- Block names ---
# The three types of block we'll use from the MeshLibrary
# Underground blocks that are buried under other blocks
@export var dirt_name: String = "BlockDirt"
# The top block for areas near floor level — like a grassy field
@export var grass_name: String = "BlockDirtWithGrass"
# The top block for high-up areas — like a snowy mountain peak
@export var snow_name: String = "BlockDirtWithSnow"

# How high above the floor (y = 0) before snow appears instead of grass
# Blocks at this height or above get snow on top
# Think of it like a snow line on a mountain — below it's green, above it's white
@export var snow_height: int = 6

# --- Hill settings ---

# The tallest a hill can be in blocks
# Hills will range from 1 block at the edges up to this many at the peak
@export var max_hill_height: int = 8

# Controls how big the hills are across the ground
# Low numbers = wide rolling hills, high numbers = narrow pointy hills
@export_range(0.01, 0.2, 0.005) var hill_noise_scale: float = 0.03

# How bumpy and irregular the hill shapes are
# More octaves = crinklier slopes, fewer = smoother rounded hills
@export_range(1, 6) var hill_noise_octaves: int = 4

# How much of the floor has hills on it
# 0.0 = hills everywhere, higher = fewer hills
# Only noise values above this threshold become hills
@export_range(-1.0, 1.0, 0.05) var hill_threshold: float = 0.2

# --- Valley settings ---

# The deepest a valley can be in blocks
# Valleys will range from 1 block deep at the edges to this at the bottom
@export var max_valley_depth: int = 6

# Controls how big the valleys are across the ground
# Low numbers = wide sweeping valleys, high numbers = narrow pits
@export_range(0.01, 0.2, 0.005) var valley_noise_scale: float = 0.03

# How bumpy and irregular the valley shapes are
@export_range(1, 6) var valley_noise_octaves: int = 4

# How much of the floor has valleys in it
# 0.0 = valleys everywhere, higher = fewer valleys
# Only noise values above this threshold become valleys
@export_range(-1.0, 1.0, 0.05) var valley_threshold: float = 0.3

# --- Safe zone ---

# How big the safe zone in the middle is (5 means a 5x5 square)
# This area always has blocks and stays flat — no hills or valleys
@export var safe_zone_size: int = 5

# --- Performance ---

# How many columns to process before pausing to let a frame render
# Higher = faster generation but more stuttery, lower = smoother but slower
# Think of it like laying bricks — you take a break every so often so you don't collapse
@export var columns_per_frame: int = 512

# Noise generator for the hills — decides where terrain rises up
var hill_noise: FastNoiseLite = FastNoiseLite.new()
# Noise generator for the valleys — decides where terrain dips down
# A separate noise so valleys and hills get their own shapes
var valley_noise: FastNoiseLite = FastNoiseLite.new()

# A dictionary that stores the height of every block position
# Positive numbers = hill (above floor), negative = valley (below floor), 0 = flat floor
# We calculate this FIRST, then fix the valleys, then place all the blocks
# Think of it like drawing a blueprint before building
var height_map: Dictionary = {}

# The four directions we check for neighbours — up, down, left, right
# Defined once here so we don't recreate this list thousands of times
const NEIGHBOURS = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

# This runs automatically when the game starts
func _ready():
	generate_floor()

# Checks if a position is inside the safe zone in the middle
func is_in_safe_zone(x: int, z: int) -> bool:
	# Work out how far from the centre this spot is
	# For a 5x5 zone, that means -2 to 2 on both axes
	var half = safe_zone_size / 2
	return abs(x) <= half and abs(z) <= half

# Looks up a block by name and returns its index, or -1 if not found
# Also prints an error so we know what went wrong
func get_item_by_name(block_name: String) -> int:
	var item = mesh_library.find_item_by_name(block_name)
	if item == INVALID_CELL_ITEM:
		push_error("Item '%s' not found in MeshLibrary!" % block_name)
	return item

# Builds the terrain — floor with hills on top and valleys dug in
# This is an async function — it pauses every so often to let frames render
# so the game doesn't freeze during generation
func generate_floor():
	# Look up all three block types from the MeshLibrary
	var dirt_item = get_item_by_name(dirt_name)
	var grass_item = get_item_by_name(grass_name)
	var snow_item = get_item_by_name(snow_name)

	# If any of the blocks are missing, give up
	# We need all three to build the terrain properly
	if dirt_item == INVALID_CELL_ITEM or grass_item == INVALID_CELL_ITEM or snow_item == INVALID_CELL_ITEM:
		return

	# Clear our blueprint from any previous generation
	height_map.clear()

	# --- Set up the hill noise ---
	# This one decides where hills rise up and how tall they are
	hill_noise.seed = seed_number + 1000
	hill_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	hill_noise.frequency = hill_noise_scale
	hill_noise.fractal_octaves = hill_noise_octaves
	hill_noise.fractal_gain = 0.5

	# --- Set up the valley noise ---
	# This one decides where valleys dip down and how deep they are
	# We add 2000 to the seed so valleys get their own unique pattern
	valley_noise.seed = seed_number + 2000
	valley_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	valley_noise.frequency = valley_noise_scale
	valley_noise.fractal_octaves = valley_noise_octaves
	valley_noise.fractal_gain = 0.5

	# =====================================================
	# PHASE 1: Build the blueprint (height map)
	# We figure out how high or low every spot should be
	# BEFORE placing any blocks — like planning before building
	# This phase is fast (just maths, no blocks) so no need to pause
	# =====================================================

	for x in range(-floor_width / 2, floor_width / 2):
		for z in range(-floor_depth / 2, floor_depth / 2):
			var pos = Vector2i(x, z)

			# Safe zone is always flat ground — height 0
			if is_in_safe_zone(x, z):
				height_map[pos] = 0
				continue

			# --- Check for hills ---

			var hill_value = hill_noise.get_noise_2d(float(x), float(z))

			if hill_value > hill_threshold:
				# This spot is on a hill — work out how tall
				var normalised = (hill_value - hill_threshold) / (1.0 - hill_threshold)
				var height = int(normalised * max_hill_height)
				height_map[pos] = max(height, 1)
				# Hills and valleys don't overlap — if it's a hill, skip the valley check
				continue

			# --- Check for valleys ---

			var valley_value = valley_noise.get_noise_2d(float(x), float(z))

			if valley_value > valley_threshold:
				# This spot is in a valley — work out how deep
				# We store depth as a negative number (below floor level)
				var normalised = (valley_value - valley_threshold) / (1.0 - valley_threshold)
				var depth = int(normalised * max_valley_depth)
				height_map[pos] = -max(depth, 1)
				continue

			# If it's neither a hill nor a valley, it's flat floor
			height_map[pos] = 0

	# =====================================================
	# PHASE 2: Fix the valleys so the player can escape
	# The rule: no two neighbouring blocks can differ by more than 1 in height
	# We sweep across the map multiple times
	# Each sweep, if a block is too much deeper than its neighbour,
	# we pull it up so the step is only 1 block
	# Think of it like pouring sand into a pit — the sides naturally slope down
	# =====================================================

	# We need to sweep multiple times — once for each possible depth level
	# Each sweep fixes one more layer of too-steep walls
	# After max_valley_depth sweeps, even the deepest valley will have gentle slopes
	for sweep in range(max_valley_depth):
		# Track whether we changed anything this sweep
		# If nothing changed, we can stop early — everything is already fine
		var changed = false

		for pos in height_map:
			# We only need to fix valley cells (negative heights)
			# Hills are fine because the noise already makes smooth slopes
			if height_map[pos] >= 0:
				continue

			# Look at all four neighbours
			for offset in NEIGHBOURS:
				var neighbour_pos = pos + offset

				# What's the neighbour's height?
				# If the neighbour is outside the map, treat it as floor level
				# This means valley edges at the map border slope up naturally
				var neighbour_height = 0
				if neighbour_pos in height_map:
					neighbour_height = height_map[neighbour_pos]

				# The rule: this cell can be at most 1 block lower than its neighbour
				# If it's deeper than that, pull it up
				# Example: if neighbour is at 0 and we're at -3, that's a 3-block cliff
				# We'd pull ourselves up to -1 (one step below the neighbour)
				var min_allowed = neighbour_height - 1
				if height_map[pos] < min_allowed:
					height_map[pos] = min_allowed
					changed = true

		# If nothing changed this sweep, all valleys are already gentle — stop early
		if not changed:
			break

	# =====================================================
	# PHASE 3: Place only VISIBLE blocks based on our finished blueprint
	# Instead of filling every column from bottom to top with blocks,
	# we only place blocks that the player can actually see:
	# — The surface block (always visible from above)
	# — Dirt blocks that are exposed on a side (like cliff faces and valley walls)
	# Buried blocks that are completely surrounded get skipped
	# This massively cuts down the number of blocks — like only painting
	# the outside of a house instead of filling every room with paint
	# We also pause every so often to let the game render a frame
	# so it doesn't freeze during generation
	# =====================================================

	# Count how many columns we've processed so we know when to pause
	var columns_processed = 0

	for pos in height_map:
		var x = pos.x
		var z = pos.y
		var height = height_map[pos]

		# --- Place the surface block ---
		# This is the top block the player sees and walks on
		# Always placed because it's always visible from above
		var surface_y = floor_y + height
		if height >= snow_height:
			# Above the snow line — place a snowy block
			set_cell_item(Vector3i(x, surface_y, z), snow_item)
		else:
			# Below the snow line — place a grassy block
			set_cell_item(Vector3i(x, surface_y, z), grass_item)

		# --- Work out how far down we need to fill dirt ---
		# We only need dirt blocks where a side face is exposed
		# A side face is exposed when a neighbour column is SHORTER than ours
		# meaning there's air next to our dirt — like looking at a cliff from the side
		# We find the shortest neighbour — that's how far down the exposed face goes
		var lowest_neighbour = height
		for offset in NEIGHBOURS:
			var neighbour_pos = pos + offset
			if neighbour_pos in height_map:
				# Check if this neighbour is shorter than our current lowest
				lowest_neighbour = min(lowest_neighbour, height_map[neighbour_pos])
			else:
				# This neighbour is off the edge of the map — treat as fully exposed
				# We need to fill dirt all the way down because there's nothing next to us
				lowest_neighbour = -max_valley_depth

		# --- Place exposed dirt blocks ---
		# Fill from the lowest visible point up to just below the surface
		# If all neighbours are the same height or taller, this loop doesn't run
		# because there's nothing to see — all sides are buried
		# This is the big performance win — on flat ground, zero dirt blocks are placed
		# Only cliff faces, valley walls, and hill sides get dirt
		for y in range(lowest_neighbour, height):
			set_cell_item(Vector3i(x, floor_y + y, z), dirt_item)

		# --- Pause every so often so the game doesn't freeze ---
		# Like taking a tea break while building a wall
		# The game renders a frame, then we continue placing blocks
		columns_processed += 1
		if columns_processed >= columns_per_frame:
			columns_processed = 0
			await get_tree().process_frame

# Removes the entire terrain — floor, hills, AND valleys
func clear_floor():
	# Go through every spot from left to right
	for x in range(-floor_width / 2, floor_width / 2):
		# Go through every spot from front to back
		for z in range(-floor_depth / 2, floor_depth / 2):
			# Clear everything from the deepest possible valley to the tallest hill
			for y in range(-max_valley_depth, max_hill_height + 1):
				set_cell_item(Vector3i(x, floor_y + y, z), INVALID_CELL_ITEM)
