extends Node3D

## A route document, built: the road, the cliff it is cut into, the drop on the other side,
## the checkpoints, the lot and the depot — and every question the game asks about where a
## truck is along it.
##
## [b]The same build on every machine.[/b] A server sends the document; each client builds
## this from it, so the road a client's camera sees and the road the server's trucks are
## driving on are the same arithmetic over the same numbers. Nothing here is random: what
## changes from trip to trip (weather, rock) is [DdWeather]'s and [DdGame]'s, not the road's.
##
## [b]The road is sampled every [constant STEP] metres and every query is over the
## samples.[/b] A centreline that is a sequence of arcs has a closed form, and the closed
## form is what a person writes a bug in; samples are what the mesh is built from anyway, so
## asking them is asking the road that is actually there.

const DdRouteDoc := preload("dd_route_doc.gd")
const DdWeather := preload("dd_weather.gd")
const DdPaths := preload("dd_paths.gd")

## How far out the drop's slope runs to the water. Drawn only: nothing stands on it.
const DROP_OUT := 38.0

const TREES := ["tree_pineTallA", "tree_pineDefaultA", "tree_pineRoundA", "tree_cone_dark", "tree_cone"]
const ROCKS := ["rock_largeA", "rock_largeC", "rock_tallB", "rock_tallE", "stone_largeB"]

const CHANNEL := "delivery.route"

## Metres between samples.
const STEP := 2.0

## How high the cliff rises over the road.
const WALL_HEIGHT := 16.0

## How far the drop's face is drawn below the road edge. Drawn only: nothing stands on it.
const SKIRT_DEPTH := 60.0

## How thick the road slab is under its surface.
const SLAB := 1.2

## A rail's height.
const RAIL_HEIGHT := 0.9

## The flat pad at each end, metres. The lot is where a trip starts; the depot where it ends.
const PAD_SIZE := Vector2(36.0, 44.0)

var doc: Dictionary = {}

## Whether the scenery is built: off on a server, which has nobody to show a pine tree to.
var draws: bool = true

## The samples: position, heading (yaw, radians), distance along, segment index.
var points: PackedVector3Array = PackedVector3Array()
var yaws: PackedFloat32Array = PackedFloat32Array()
var distances: PackedFloat32Array = PackedFloat32Array()
var segment_of: PackedInt32Array = PackedInt32Array()

## Distance along the road of each checkpoint, in order. The finish is [method length].
var checkpoints: PackedFloat32Array = PackedFloat32Array()

## Where rock can come down: [code]{"d": float, "side": -1 left / +1 right}[/code].
var boulder_sites: Array = []

## Black ice: [code]{"d": float, "lateral": float, "length": float, "width": float}[/code], in
## the road's own frame. Placed from a hash of the route and the patch, so every machine lays
## the same ones.
var ice: Array = []

## Fallen rock on the road: [code]{"d", "lateral", "size"}[/code]. Solid; a truck goes round.
var debris: Array = []

## Zone id -> the StandardMaterial3D every road surface in it shares, so weather recolours a
## zone with one assignment.
var zone_materials: Dictionary = {}

var _body: StaticBody3D = null
var _faces: PackedVector3Array = PackedVector3Array()
var _lowest_y: float = 0.0


func id() -> StringName:
	return StringName(str(doc.get("id", "")))


## Builds the route. [param p_doc] must already be normalised ([method DdRouteDoc.normalise]).
func build(p_doc: Dictionary) -> DotResult:
	clear()
	doc = p_doc
	_sample()
	_build_geometry()
	DotLog.debug(CHANNEL, "route built", {
		"id": String(id()), "length": "%.0f m" % length(), "samples": points.size(),
		"checkpoints": checkpoints.size(), "boulder_sites": boulder_sites.size(),
	})
	return DotResult.success(self)


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	points = PackedVector3Array()
	yaws = PackedFloat32Array()
	distances = PackedFloat32Array()
	segment_of = PackedInt32Array()
	checkpoints = PackedFloat32Array()
	boulder_sites = []
	ice = []
	debris = []
	zone_materials = {}
	_body = null
	doc = {}


# --- Sampling ----------------------------------------------------------------

func _sample() -> void:
	var at := Vector3.ZERO
	var yaw := 0.0
	var d := 0.0

	points.append(at)
	yaws.append(yaw)
	distances.append(0.0)
	segment_of.append(0)
	_lowest_y = 0.0

	var segments: Array = doc["segments"]

	for index in segments.size():
		var seg: Dictionary = segments[index]
		var length_m: float = seg["length"]
		var steps := maxi(int(ceil(length_m / STEP)), 1)
		var step_len := length_m / float(steps)
		# Positive turns right, which is a falling yaw: a heading of 0 faces -Z and right is +X.
		var turn_step := -deg_to_rad(float(seg["turn"])) / float(steps)
		var climb_step := float(seg["climb"]) / float(steps)

		for _i in steps:
			# Half the turn before the step and half after: the midpoint rule, so a long arc
			# ends where its closed form says rather than drifting outward a step at a time.
			yaw += turn_step * 0.5
			at += forward_of(yaw) * step_len
			at.y += climb_step
			yaw += turn_step * 0.5
			d += step_len
			points.append(at)
			yaws.append(yaw)
			distances.append(d)
			segment_of.append(index)
			_lowest_y = minf(_lowest_y, at.y)

		if bool(seg["checkpoint"]) and index < segments.size() - 1:
			checkpoints.append(d)

		_place_hazards(index, seg, d - length_m, length_m)

		var rocks := int(seg["boulders"])

		if rocks > 0:
			var side := -1 if str(seg["wall"]) in ["left", "both", "none"] else 1
			var start := d - length_m

			for r in rocks:
				boulder_sites.append({"d": start + length_m * (float(r) + 0.5) / float(rocks), "side": side, "index": boulder_sites.size()})


## Ice and debris along one segment, spaced evenly and moved by a hash so they are not in a
## line. Debris takes one lane and leaves the other, always: a pile across the whole road is a
## road nobody can drive, and the validator has no way to know it.
func _place_hazards(index: int, seg: Dictionary, start: float, length_m: float) -> void:
	var width: float = seg["width"]
	var id_text := str(doc.get("id", ""))

	for k in int(seg["ice"]):
		var roll := DdWeather.unit("%s|ice|%d|%d" % [id_text, index, k])
		ice.append({
			"d": start + length_m * (float(k) + 0.25 + roll * 0.5) / float(int(seg["ice"])),
			"lateral": (roll - 0.5) * width * 0.4, "length": 8.0 + roll * 6.0, "width": width * 0.55,
		})

	for k in int(seg["debris"]):
		var roll := DdWeather.unit("%s|debris|%d|%d" % [id_text, index, k])
		var side := -1.0 if roll < 0.5 else 1.0
		debris.append({
			"d": start + length_m * (float(k) + 0.5) / float(int(seg["debris"])),
			"lateral": side * width * 0.27, "size": Vector3(width * 0.36, 1.1 + roll, 2.5 + roll * 2.0),
		})


## Whether [param position] (route-local) is on a patch of black ice.
func on_ice(position: Vector3, hint: int = -1) -> bool:
	if ice.is_empty():
		return false

	var d := distance_at(position, hint)
	var lateral := lateral_at(position, hint)

	for patch: Dictionary in ice:
		if absf(d - float(patch["d"])) <= float(patch["length"]) * 0.5 \
				and absf(lateral - float(patch["lateral"])) <= float(patch["width"]) * 0.5:
			return true

	return false


static func forward_of(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


static func right_of(yaw: float) -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


# --- Queries -----------------------------------------------------------------

func length() -> float:
	return distances[distances.size() - 1] if not distances.is_empty() else 0.0


func stages() -> int:
	return checkpoints.size() + 1


## The sample nearest [param position] horizontally, searched around [param hint] first.
##
## [b]Around a hint, because a switchback puts the road beside itself.[/b] The nearest sample
## to a truck on the lower leg of a hairpin can be on the upper leg ten metres above it; a
## truck's own last index, searched near first and in three dimensions, is the road it is on.
func nearest_index(position: Vector3, hint: int = -1) -> int:
	if points.is_empty():
		return 0

	var lo := 0
	var hi := points.size() - 1

	if hint >= 0:
		lo = maxi(hint - 30, 0)
		hi = mini(hint + 30, points.size() - 1)

	var best := lo
	var best_d := INF

	for i in range(lo, hi + 1):
		var dist := points[i].distance_squared_to(position)

		if dist < best_d:
			best_d = dist
			best = i

	# A hint that put the truck at the window's edge is a truck that has moved further than
	# the window in one call — a respawn or a teleport. Ask the whole road.
	if hint >= 0 and (best == lo and lo > 0 or best == hi and hi < points.size() - 1):
		return nearest_index(position, -1)

	return best


## Distance along the road of [param position]: its nearest sample, projected.
func distance_at(position: Vector3, hint: int = -1) -> float:
	var i := nearest_index(position, hint)
	var along := forward_of(yaws[i]).dot(position - points[i])
	return clampf(distances[i] + along, 0.0, length())


## Signed metres right of the centreline.
func lateral_at(position: Vector3, hint: int = -1) -> float:
	var i := nearest_index(position, hint)
	return right_of(yaws[i]).dot(position - points[i])


func index_at_distance(d: float) -> int:
	var i := distances.bsearch(clampf(d, 0.0, length()))
	return clampi(i, 0, points.size() - 1)


## Where a truck is put at distance [param d]: on the centreline, facing along the road,
## [param lift] metres up so its wheels settle onto it rather than start inside it.
func transform_at(d: float, lift: float = 1.0) -> Transform3D:
	var i := index_at_distance(d)
	var basis := Basis(Vector3.UP, yaws[i])
	return Transform3D(basis, points[i] + Vector3(0.0, lift, 0.0))


func segment_at(d: float) -> Dictionary:
	return (doc["segments"] as Array)[segment_of[index_at_distance(d)]]


func zone_at(d: float) -> String:
	return str(segment_at(d).get("zone", ""))


func width_at(d: float) -> float:
	return float(segment_at(d)["width"])


## How many checkpoints lie at or before [param d].
func stage_of(d: float) -> int:
	var n := 0

	for c in checkpoints:
		if d >= c:
			n += 1

	return n


## The checkpoint a truck that has reached [param stage] is put back on: the start for 0.
func checkpoint_distance(stage: int) -> float:
	if stage <= 0 or checkpoints.is_empty():
		return 4.0

	return checkpoints[mini(stage, checkpoints.size()) - 1] + 2.0


## Road height at the sample nearest [param position]; what "fallen off" is measured from.
func road_height_at(position: Vector3, hint: int = -1) -> float:
	return points[nearest_index(position, hint)].y


func lowest_point() -> float:
	return _lowest_y


## Waypoints for [DotVehicleDriver], every [param spacing] metres from [param from_d].
func route_points(from_d: float = 0.0, spacing: float = 8.0) -> PackedVector3Array:
	var out := PackedVector3Array()
	var d := from_d

	while d < length():
		var i := index_at_distance(d)
		var p := points[i]

		# Into the other lane round a pile of debris: a stand-in on the centreline drives into
		# every pile, because a pile takes one lane and reaches nearly to the line.
		for pile: Dictionary in debris:
			if absf(float(pile["d"]) - d) < 16.0:
				p -= right_of(yaws[i]) * signf(float(pile["lateral"])) * width_at(d) * 0.26

		out.append(p)
		d += spacing

	out.append(points[points.size() - 1] + forward_of(yaws[yaws.size() - 1]) * 12.0)
	return out


func describe() -> Dictionary:
	return {
		"id": String(id()), "name": str(doc.get("name", "")), "level": int(doc.get("level", 1)),
		"length": "%.0f m" % length(), "stages": stages(), "rise": "%.0f m" % (points[points.size() - 1].y if not points.is_empty() else 0.0),
		"boulder_sites": boulder_sites.size(), "zones": (doc.get("zones", {}) as Dictionary).keys(),
	}


# --- Geometry ----------------------------------------------------------------

func _build_geometry() -> void:
	_body = StaticBody3D.new()
	_body.name = "Road"
	add_child(_body)

	# A member, not a local passed down: a PackedVector3Array is copied on write, so the
	# faces appended in _quad went into a copy and the road had no collision at all — the
	# first truck fell through it from the start line.
	_faces = PackedVector3Array()
	var segments: Array = doc["segments"]

	# One mesh per segment, so a zone's material is the segment's and weather recolours a
	# zone by changing one material rather than rebuilding.
	var seg_start := 0

	for index in segments.size():
		var seg_end := seg_start

		while seg_end + 1 < points.size() and segment_of[seg_end + 1] == index:
			seg_end += 1

		_build_segment(index, seg_start, seg_end)
		seg_start = seg_end

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(_faces)
	shape.backface_collision = true
	var collider := CollisionShape3D.new()
	collider.shape = shape
	_body.add_child(collider)

	_build_pad(transform_at(0.0, 0.0), true)
	_build_pad(transform_at(length(), 0.0), false)

	for i in checkpoints.size():
		_build_gate(checkpoints[i], "%d" % (i + 1))

	_build_gate(length() - 1.0, "DEPOT")

	if draws:
		_build_scenery()
	_build_ice()
	_build_debris()
	_build_water()


func _edge(i: int, side: float, width: float, bank_deg: float) -> Vector3:
	# Banking raises the outside edge: positive bank tilts the road down to the right.
	var rise := -side * tan(deg_to_rad(bank_deg)) * width * 0.5
	return points[i] + right_of(yaws[i]) * side * width * 0.5 + Vector3(0.0, rise, 0.0)


func _build_segment(index: int, from_i: int, to_i: int) -> void:
	var seg: Dictionary = doc["segments"][index]
	var width: float = seg["width"]
	var bank: float = seg["bank"]
	var road := SurfaceTool.new()
	var rock := SurfaceTool.new()
	road.begin(Mesh.PRIMITIVE_TRIANGLES)
	rock.begin(Mesh.PRIMITIVE_TRIANGLES)


	var wall := str(seg["wall"])
	var rail := str(seg["rail"])

	for i in range(from_i, to_i):
		var l0 := _edge(i, -1.0, width, bank)
		var r0 := _edge(i, 1.0, width, bank)
		var l1 := _edge(i + 1, -1.0, width, bank)
		var r1 := _edge(i + 1, 1.0, width, bank)
		var down := Vector3(0.0, -SLAB, 0.0)

		# The surface, and the slab's two sides and underside, all solid: a wheel that slips
		# over the edge should catch the edge on the way down, not fall through it.
		_quad(road, true, l0, r0, r1, l1, true)
		_quad(rock, true, l1 + down, r1 + down, r0 + down, l0 + down, true)
		_quad(rock, true, l0 + down, l0, l1, l1 + down, true)
		_quad(rock, true, r1 + down, r1, r0, r0 + down, true)

		# The cliff. Solid, because driving into it is how a truck stays on the road.
		var up := Vector3(0.0, WALL_HEIGHT, 0.0)

		if wall == "left" or wall == "both":
			_quad(rock, true, l1, l1 + up, l0 + up, l0, true)
		if wall == "right" or wall == "both":
			_quad(rock, true, r0, r0 + up, r1 + up, r1, true)

		# The drop's face: drawn below an open edge so the road reads as a ledge, and NOT
		# collided — nothing stands on a cliff face, and a truck going over should fall.
		var deep := Vector3(0.0, -SKIRT_DEPTH, 0.0)

		# The drop: a rock slope down to the water rather than a sheer sheet, so the road reads
		# as cut into a mountainside and a truck going over has something to tumble down.
		if wall != "left" and wall != "both":
			var out0 := -right_of(yaws[i]) * DROP_OUT
			var out1 := -right_of(yaws[i + 1]) * DROP_OUT
			_quad(rock, false, l0 + down, l0 + deep + out0, l1 + deep + out1, l1 + down, false)
		if wall != "right" and wall != "both":
			var out0 := right_of(yaws[i]) * DROP_OUT
			var out1 := right_of(yaws[i + 1]) * DROP_OUT
			_quad(rock, false, r1 + down, r1 + deep + out1, r0 + deep + out0, r0 + down, false)

		var rail_up := Vector3(0.0, RAIL_HEIGHT, 0.0)

		if rail == "left" or rail == "both":
			_quad(rock, true, l0, l0 + rail_up, l1 + rail_up, l1, true)
		if rail == "right" or rail == "both":
			_quad(rock, true, r1, r1 + rail_up, r0 + rail_up, r0, true)

		_dash(road, i)

	road.generate_normals()
	rock.generate_normals()


	var road_mesh := MeshInstance3D.new()
	road_mesh.name = "Road%d" % index
	road_mesh.mesh = road.commit()
	road_mesh.material_override = _zone_material(str(seg["zone"]))
	add_child(road_mesh)

	var rock_mesh := MeshInstance3D.new()
	rock_mesh.name = "Rock%d" % index
	rock_mesh.mesh = rock.commit()
	rock_mesh.material_override = _rock_material()
	add_child(rock_mesh)




## The centre line, dashed: three metres on, three off, a hair above the surface.
func _dash(road: SurfaceTool, i: int) -> void:
	if int(distances[i] / 3.0) % 2 == 1:
		return

	var half := 0.08
	var lift := Vector3(0.0, 0.02, 0.0)
	var a := points[i] + lift
	var b := points[i + 1] + lift
	var ra := right_of(yaws[i]) * half
	var rb := right_of(yaws[i + 1]) * half
	road.set_color(Color(0.95, 0.85, 0.3))
	for v in [a - ra, b + rb, a + ra, a - ra, b - rb, b + rb]:
		road.add_vertex(v)
	road.set_color(Color(1, 1, 1))


func _quad(st: SurfaceTool, collides: bool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, _solid: bool, tint: Color = Color(1, 1, 1)) -> void:
	st.set_color(tint)
	# Wound a-c-b: Godot's front face is clockwise seen from the front, and the quads above are
	# written counter-clockwise. The first render showed the road's own surface culled and the
	# cream underside of the slab through it.
	for v in [a, c, b, a, d, c]:
		st.add_vertex(v)

	if collides:
		_faces.append_array(PackedVector3Array([a, b, c, a, c, d]))


func _zone_material(zone: String) -> StandardMaterial3D:
	if zone_materials.has(zone):
		return zone_materials[zone]

	var material := StandardMaterial3D.new()
	material.albedo_color = ASPHALT
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.9
	material.albedo_texture = _noise(0.4, 0.25)
	material.uv1_triplanar = true
	material.uv1_scale = Vector3(0.25, 0.25, 0.25)
	zone_materials[zone] = material
	return material


var _rock: StandardMaterial3D = null



func _rock_material() -> StandardMaterial3D:
	if _rock == null:
		_rock = StandardMaterial3D.new()
		# Darker than a rock's real colour: under the filmic tonemap and a clear sky the first
		# renders read every slope as snow.
		_rock.albedo_color = Color(0.4, 0.36, 0.31)

		_rock.roughness = 1.0
		_rock.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Noise, projected from all three axes, so a cliff reads as rock at any angle without a
		# UV anybody had to lay out. Generated, so the game carries no texture for it.
		_rock.albedo_texture = _noise(0.035, 0.55)
		_rock.uv1_triplanar = true
		_rock.uv1_scale = Vector3(0.12, 0.12, 0.12)

	return _rock


## A tiling grey noise: [param frequency] is the grain, [param contrast] how far it strays
## from mid-grey. Multiplied with a material's colour.
static func _noise(frequency: float, contrast: float) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.frequency = frequency
	noise.fractal_octaves = 4
	var texture := NoiseTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.seamless = true
	texture.noise = noise
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0 - contrast, 1.0 - contrast, 1.0 - contrast))
	ramp.set_color(1, Color(1, 1, 1))
	texture.color_ramp = ramp
	return texture


const ASPHALT := Color(0.34, 0.34, 0.36)
const SNOW := Color(0.92, 0.94, 0.98)
const WET := Color(0.16, 0.17, 0.2)


## Colours a zone's road for its weather: white under snow, dark and glossy in rain.
func paint_zone(zone: String, snowy: bool, rainy: bool) -> void:
	var material: StandardMaterial3D = zone_materials.get(zone, null)

	if material == null:
		return

	material.albedo_color = SNOW if snowy else (WET if rainy else ASPHALT)
	material.roughness = 0.35 if rainy and not snowy else 0.9


func _build_pad(at: Transform3D, is_lot: bool) -> void:
	var pad := CSGBox3D.new()
	pad.name = "Lot" if is_lot else "Depot"
	pad.size = Vector3(PAD_SIZE.x, SLAB, PAD_SIZE.y)
	pad.use_collision = true
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.32, 0.33, 0.35) if is_lot else Color(0.25, 0.4, 0.3)
	pad.material = material
	add_child(pad)
	# The lot sits behind the start, the depot past the finish, both flush with the road.
	var along := -PAD_SIZE.y * 0.5 + 2.0 if is_lot else PAD_SIZE.y * 0.5 - 2.0
	pad.global_transform = Transform3D(at.basis, at.origin + at.basis * Vector3(0.0, -SLAB * 0.5, -along))


## Two posts and a banner across the road.
func _build_gate(d: float, label: String) -> void:
	var at := transform_at(d, 0.0)
	var width := width_at(d)
	var gate := Node3D.new()
	gate.name = "Gate_%s" % label
	add_child(gate)
	gate.global_transform = at

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.75, 0.1)
	material.emission_enabled = true
	material.emission = Color(0.5, 0.35, 0.0)

	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.4, 6.0, 0.4)
		post.mesh = box
		post.material_override = material
		post.position = Vector3(side * (width * 0.5 + 0.6), 3.0, 0.0)
		gate.add_child(post)

	var banner := MeshInstance3D.new()
	var bar := BoxMesh.new()
	bar.size = Vector3(width + 1.6, 0.9, 0.2)
	banner.mesh = bar
	banner.material_override = material
	banner.position = Vector3(0.0, 6.2, 0.0)
	gate.add_child(banner)

	var text := Label3D.new()
	text.text = label
	text.font_size = 96
	text.pixel_size = 0.01
	text.modulate = Color(0.1, 0.1, 0.1)
	text.position = Vector3(0.0, 6.2, 0.15)
	text.rotation.y = PI
	gate.add_child(text)


## Pines on the mountainside above every cliff and rocks down every drop, as one MultiMesh per
## model: a route has a hundred or more, and a node each is a browser's frame budget gone.
## Placed from a hash of the route and the sample, so every client sees the same mountain.
func _build_scenery() -> void:
	var placements := {}
	var id_text := str(doc.get("id", ""))
	var i := 3

	while i < points.size() - 3:
		var seg: Dictionary = doc["segments"][segment_of[i]]
		var wall := str(seg["wall"])
		var width: float = seg["width"]
		var roll := DdWeather.unit("%s|tree|%d" % [id_text, i])

		for side: float in [-1.0, 1.0]:
			var cliff: bool = wall == "both" or (wall == "left" and side < 0.0) or (wall == "right" and side > 0.0)
			var out: Vector3 = right_of(yaws[i]) * side
			var edge: Vector3 = points[i] + out * width * 0.5

			# On the drop only: pines growing out of the slope below the road, and rock further
			# down. A mountainside above each cliff was tried and taken out: built per segment, it
			# overlapped the road wherever the road turned toward it, drawn from both sides it
			# was a dark slab across the sky, and drawn from one its trees floated.
			if cliff:
				continue

			var down := 4.0 + roll * 44.0
			var at: Vector3 = edge + out * (down / SKIRT_DEPTH * DROP_OUT) + Vector3(0, -SLAB - down, 0)

			if roll < 0.55:
				_place(placements, TREES[int(roll * 997.0) % TREES.size()], at, roll * TAU, 3.4 + roll * 2.0)
			elif roll > 0.82:
				_place(placements, ROCKS[int(roll * 991.0) % ROCKS.size()], at, roll * TAU, 4.0 + roll * 6.0)

		i += 4

	for model: String in placements:
		var mesh := _scenery_mesh(model)

		if mesh == null:
			continue

		var list: Array = placements[model]
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = mesh
		multi.instance_count = list.size()

		for k in list.size():
			multi.set_instance_transform(k, list[k])

		var node := MultiMeshInstance3D.new()
		node.name = "Scenery_%s" % model
		node.multimesh = multi

		# Rocks in the cliff's own rock: Kenney's pale grey read as ice under this sun.
		if ROCKS.has(model):
			node.material_override = _rock_material()
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)


func _place(placements: Dictionary, model: String, at: Vector3, turn: float, size: float) -> void:
	if not placements.has(model):
		placements[model] = []

	(placements[model] as Array).append(Transform3D(Basis(Vector3.UP, turn).scaled(Vector3.ONE * size), at))


static var _scenery_meshes: Dictionary = {}


## The first mesh in a Kenney model, with its materials: what a MultiMesh draws.
static func _scenery_mesh(model: String) -> Mesh:
	if _scenery_meshes.has(model):
		return _scenery_meshes[model]

	var path := DdPaths.rebase("res://assets/kenney/nature/%s.glb" % model)
	var mesh: Mesh = null

	if ResourceLoader.exists(path):
		var scene := (load(path) as PackedScene).instantiate()
		var found := scene.find_children("*", "MeshInstance3D", true, false)

		if not found.is_empty():
			mesh = (found[0] as MeshInstance3D).mesh

		scene.free()

	_scenery_meshes[model] = mesh
	return mesh


## Black ice: a glossy pale sheet a hair above the road. Drawn so it can be seen, because ice
## that cannot be seen is a fall that cannot be avoided, which is not a hazard but a lottery.
func _build_ice() -> void:
	if ice.is_empty():
		return

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.72, 0.84, 0.95, 0.75)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 0.05
	material.metallic = 0.3

	for patch: Dictionary in ice:
		var at := transform_at(float(patch["d"]), 0.03)
		var sheet := MeshInstance3D.new()
		sheet.name = "Ice"
		var plane := PlaneMesh.new()
		plane.size = Vector2(float(patch["width"]), float(patch["length"]))
		sheet.mesh = plane
		sheet.material_override = material
		add_child(sheet)
		sheet.transform = Transform3D(at.basis, at.origin + at.basis.x * float(patch["lateral"]))


## Fallen rock: solid boxes, rock-coloured, in one lane.
func _build_debris() -> void:
	for pile: Dictionary in debris:
		var at := transform_at(float(pile["d"]), 0.0)
		var size: Vector3 = pile["size"]
		var body := StaticBody3D.new()
		body.name = "Debris"
		var shape := BoxShape3D.new()
		shape.size = size
		var collider := CollisionShape3D.new()
		collider.shape = shape
		body.add_child(collider)
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mesh.mesh = box
		mesh.material_override = _rock_material()
		body.add_child(mesh)
		add_child(body)
		body.transform = Transform3D(at.basis.rotated(Vector3.UP, 0.15), at.origin + at.basis.x * float(pile["lateral"]) + Vector3(0.0, size.y * 0.5, 0.0))


func _build_water() -> void:
	var water := MeshInstance3D.new()
	water.name = "Water"
	var plane := PlaneMesh.new()
	plane.size = Vector2(6000.0, 6000.0)
	water.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.1, 0.24, 0.3)
	# Matte enough not to be a mirror: a glossy plane under a bright sky IS the sky.
	material.roughness = 0.55
	water.material_override = material
	water.position = Vector3(points[points.size() / 2].x, _lowest_y - SKIRT_DEPTH, points[points.size() / 2].z)
	add_child(water)
