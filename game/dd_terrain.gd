extends RefCounted

## The ground a route is cut into: one heightfield under the whole route, rising into a
## mountain behind every cliff and falling away under every drop to the water. Drawn only.
##
## [b]A heightfield, not ribbons.[/b] A hillside built per segment, the first way this was
## tried, overlapped the road wherever the road turned toward it, because a ribbon has no idea
## where the rest of the road is. A grid whose every vertex asks "how far am I from the road,
## and on which side" can be told, as a rule, never to rise through it.
##
## [b]The rule that keeps it off the road is a band, not a test.[/b] Every vertex within
## [constant BAND] metres of a road edge (any sample's, not only its nearest one, because a
## switchback puts the road beside itself at another height) is held below that sample's slab.
## [constant BAND] is wider than a cell's diagonal, so a triangle with any vertex outside the
## band has all of its points outside the road: the slope from the trench up to the mountain
## can only ever happen behind the wall, never over the tarmac. The obvious alternative, letting
## the mountain start at the wall's foot, interpolates a vertex on the road with one behind the
## wall and puts a sheet of hillside across the lane.
##
## [b]The same on every machine.[/b] Heights are arithmetic over the route's samples and
## [DdWeather.unit] of the route id — not [method @GlobalScope.hash], whose djb2 differs only
## in its low bits for neighbouring keys (Decision 2) and would put the same bump in every cell.
## A server never builds it: it has nobody to show a mountain to, and nothing collides with it.
## The road's own trimesh stays the only thing a truck stands on.

const DdWeather := preload("dd_weather.gd")

const CHANNEL := "delivery.terrain"

## Metres between grid vertices. 5 m is a mountain's grain and keeps a route under 40k
## vertices; at 2.5 m the build took four times as long for detail the fog hides.
const CELL := 5.0

## How far the grid runs past the road on every side. Routes are [code]DdGame.ROUTE_GAP[/code]
## (160 m) apart, so a neighbour's grid can overlap this one's edge but stops 50 m short of its
## road; where two overlap both are falling to the water and whichever is higher is the hill.
## At 80 m, the most that never overlaps, the last 35 m had to drop sixty metres and every route
## stood in the lake on a dark cliff of its own.
const MARGIN := 110.0

## Within this many metres of a road edge the ground is held under the road. Must exceed a
## cell's diagonal ([constant CELL] * 1.414 = 7.07); see the class description for why.
const BAND := 8.0

## How far under the slab's underside the ground is held inside [constant BAND].
const CLEARANCE := 1.0

## How far the mountain climbs above the cliff's top, approached over [constant RISE_RUN], and
## where it starts to come down again on its far side: a ridge behind the road rather than a
## plateau, which from above read as the road cut in a trench through a table.
const RISE := 55.0
const RISE_RUN := 22.0
const RIDGE_FROM := 45.0
const RIDGE_TO := 105.0

## How far under the drop's rock slope the ground runs, so the slope covers it near the road
## and the two never fight over the same pixels.
const DROP_UNDER := 1.0

## The last metres of the grid fall to the water, so a route is a massif in a lake rather than
## a block cut off square at its edge.
const FALLOFF := 60.0

## How far the bank under the lot and the depot runs before it meets the ground.
const EMBANKMENT := 40.0

## How far back the cliff's top runs to meet the hillside, and how much it climbs doing so.
## Built by [DdRoute] with the wall, because it belongs to the wall's edge, not to the grid.
const CAP := 13.0
const CAP_RISE := 0.6

## Above this (route-local) the ground keeps its snow whatever the weather.
const SNOW_FROM := 112.0
const SNOW_FULL := 140.0

const ROCK := Color(0.4, 0.36, 0.31)
const GRASS := Color(0.27, 0.32, 0.19)
const SHORE := Color(0.33, 0.31, 0.27)

## Samples apart for two samples to be on different stretches of road (80 m): the two legs of
## a 95 m hairpin, measured at its apex, are each about 24 samples away.
const LEG := 40

## Samples either side over which one zone's weather gives way to the next's.
const ZONE_BLEND := 10

## Zones a route's terrain can tell apart for weather; a route with more paints the rest with
## the last one. Five routes use at most four.
const MAX_ZONES := 8

var origin: Vector2 = Vector2.ZERO
var nx: int = 0
var nz: int = 0

## Per vertex, row-major (x fastest).
var heights: PackedFloat32Array = PackedFloat32Array()
var normals: PackedVector3Array = PackedVector3Array()
## The road sample nearest each vertex, horizontally.
var nearest: PackedInt32Array = PackedInt32Array()
## Metres beyond the nearest sample's road edge; negative over the road.
var beyond: PackedFloat32Array = PackedFloat32Array()
## Zone id -> index into the shader's per-zone arrays.
var zone_index: Dictionary = {}
var water_y: float = 0.0

var _id: String = ""
var _sample_zone: PackedInt32Array = PackedInt32Array()
var _points: PackedVector3Array = PackedVector3Array()
## The nearest sample on another stretch of road: more than [constant LEG] samples from
## [member nearest]'s, or -1.
var second: PackedInt32Array = PackedInt32Array()
var _yaws: PackedFloat32Array = PackedFloat32Array()
var _half: PackedFloat32Array = PackedFloat32Array()
var _cliff_left: PackedFloat32Array = PackedFloat32Array()
var _cliff_right: PackedFloat32Array = PackedFloat32Array()
var _wall_height: float = 0.0
var _slab: float = 0.0
var _drop_slope: float = 0.0
var _noise_cache: Dictionary = {}


## Builds the heightfield for [param route] (a built [DdRoute], untyped so the two scripts do
## not preload each other). [param pads] is [code][{"centre": Vector3, "basis": Basis}][/code]
## for the lot and the depot, [param pad_half] their half extents.
func compute(route: Variant, wall_height: float, slab: float, drop_slope: float, p_water_y: float, pads: Array, pad_half: Vector2) -> void:
	var points: PackedVector3Array = route.points
	var yaws: PackedFloat32Array = route.yaws
	var segment_of: PackedInt32Array = route.segment_of
	var segments: Array = route.doc["segments"]
	_id = str(route.doc.get("id", ""))
	_points = points
	water_y = p_water_y
	_noise_cache = {}
	var n := points.size()

	if n < 2:
		return

	var started := Time.get_ticks_usec()

	# Per sample: half width, how far a bank drops the low edge, and how much of a cliff stands
	# on each side. The cliff is smoothed along the road so the mountain tapers in and out over
	# the first and last 24 m of a wall rather than standing up in a vertical sheet — and it
	# tapers INSIDE the wall's stretch (eroded, then smoothed), never past it. Dilated instead,
	# the mountain began twenty metres before its wall, on what was still the drop side: a
	# hillside in the picture with no collision under it, which a truck would fall through.
	var half := PackedFloat32Array()
	var bank_drop := PackedFloat32Array()
	var raw_left := PackedFloat32Array()
	var raw_right := PackedFloat32Array()
	half.resize(n)
	bank_drop.resize(n)
	raw_left.resize(n)
	raw_right.resize(n)
	zone_index = {"": 0}
	_sample_zone.resize(n)

	for i in n:
		var seg: Dictionary = segments[segment_of[i]]
		half[i] = float(seg["width"]) * 0.5
		bank_drop[i] = absf(tan(deg_to_rad(float(seg["bank"])))) * half[i]
		var wall := str(seg["wall"])
		raw_left[i] = 1.0 if wall == "left" or wall == "both" else 0.0
		raw_right[i] = 1.0 if wall == "right" or wall == "both" else 0.0
		var zone := str(seg["zone"])

		if not zone_index.has(zone):
			zone_index[zone] = mini(zone_index.size(), MAX_ZONES - 1)

		_sample_zone[i] = int(zone_index[zone])

	var cliff_left := _smooth(_erode(raw_left, 6), 6)
	var cliff_right := _smooth(_erode(raw_right, 6), 6)

	# The grid: every sample and both pads, plus the margin.
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)

	for p in points:
		lo = lo.min(Vector2(p.x, p.z))
		hi = hi.max(Vector2(p.x, p.z))

	for pad: Dictionary in pads:
		var c: Vector3 = pad["centre"]
		var r := pad_half.length()
		lo = lo.min(Vector2(c.x - r, c.z - r))
		hi = hi.max(Vector2(c.x + r, c.z + r))

	origin = lo - Vector2(MARGIN, MARGIN)
	nx = int(ceil((hi.x - lo.x + MARGIN * 2.0) / CELL)) + 1
	nz = int(ceil((hi.y - lo.y + MARGIN * 2.0) / CELL)) + 1
	var count := nx * nz

	_nearest_samples(points)
	_second_samples(points)

	# What the ground wants to be: the nearest sample's cliff side climbs, its drop side falls
	# under the drop's rock slope to the water.
	heights.resize(count)
	beyond.resize(count)

	_yaws = yaws
	_half = half
	_cliff_left = cliff_left
	_cliff_right = cliff_right
	_wall_height = wall_height
	_slab = slab
	_drop_slope = drop_slope

	for k in count:
		var v := Vector2(origin.x + float(k % nx) * CELL, origin.y + float(k / nx) * CELL)
		var near := _wish(nearest[k], v)
		beyond[k] = near.y
		heights[k] = near.x

		# Blended with the nearest OTHER stretch of road, by inverse distance cubed. Between two
		# legs of a switchback the lower one's cliff faces the upper one's drop, and on its own
		# the lower one's mountain stood fifty metres high right beside the upper road's edge: a
		# hillside where a driver should see a drop. Blended, the ground runs from one road to
		# the other, and each road's own wish is what holds at its edge.
		if second[k] >= 0:
			var other := _wish(second[k], v)
			var w_near := 1.0 / pow(maxf(near.y + _half[nearest[k]], 1.0), 3.0)
			var w_other := 1.0 / pow(maxf(other.y + _half[second[k]], 1.0), 3.0)
			heights[k] = (near.x * w_near + other.x * w_other) / (w_near + w_other)

	# Where two stretches of road meet in the grid (either leg of a switchback) their wishes
	# disagree by tens of metres across one cell. Smoothed before the band is applied, so the
	# smoothing never drags the band's trench up out from under the road.
	for _pass in 3:
		_blur()

	for k in count:
		var x := origin.x + float(k % nx) * CELL
		var z := origin.y + float(k / nx) * CELL
		# Rough ground, and rougher the further from the road: near the cliff it would show as
		# a ragged wall top.
		var amp := clampf((beyond[k] - BAND) / 20.0, 0.0, 1.0)
		heights[k] += amp * (_noise(x, z, 26.0, 1) * 7.0 + _noise(x, z, 75.0, 2) * 14.0)
		# Down to the water at the edge of the grid.
		var gx := k % nx
		var gz := k / nx
		var edge := float(mini(mini(gx, nx - 1 - gx), mini(gz, nz - 1 - gz))) * CELL
		heights[k] = lerpf(water_y - 8.0, heights[k], smoothstep(0.0, FALLOFF, edge))

	# The lot and the depot stand on ground: a bank under each, out to EMBANKMENT metres. The
	# mountain gives way past the road's ends, and without this both pads stood on nothing at
	# the edge of the lake, a slab in the air seen from every hairpin above them.
	for pad: Dictionary in pads:
		_bank_up_pad(pad["centre"], pad["basis"], pad_half, (pad["centre"] as Vector3).y - slab - CLEARANCE)

	# The band, last: nothing above may undo it.
	for i in n:
		_hold_under(Vector2(points[i].x, points[i].z), half[i] + BAND, points[i].y - bank_drop[i] - slab - CLEARANCE)

	for pad: Dictionary in pads:
		_hold_under_pad(pad["centre"], pad["basis"], pad_half + Vector2(BAND, BAND), (pad["centre"] as Vector3).y - slab - CLEARANCE)

	_normals()
	DotLog.debug(CHANNEL, "terrain built", {"route": _id, "grid": "%dx%d" % [nx, nz], "ms": (Time.get_ticks_usec() - started) / 1000})


## Height of the drawn surface at route-local [param x], [param z]: the same two triangles a
## cell is drawn as, so something put here stands exactly on what is seen.
func height_at(x: float, z: float) -> float:
	var fx := clampf((x - origin.x) / CELL, 0.0, float(nx - 1) - 0.0001)
	var fz := clampf((z - origin.y) / CELL, 0.0, float(nz - 1) - 0.0001)
	var gx := int(fx)
	var gz := int(fz)
	fx -= float(gx)
	fz -= float(gz)
	var a := heights[gz * nx + gx]
	var b := heights[gz * nx + gx + 1]
	var c := heights[(gz + 1) * nx + gx + 1]
	var d := heights[(gz + 1) * nx + gx]

	# Split along a-c, as _mesh() does.
	if fx >= fz:
		return a + fx * (b - a) + fz * (c - b)

	return a + fz * (d - a) + fx * (c - d)


## The road sample nearest route-local [param x], [param z], horizontally: the candidates of the
## four vertices around it, each walked along the road to its own best. What a suite asks to
## find which stretch of road a point of the mountain belongs to.
func sample_near(x: float, z: float) -> int:
	var gx := clampi(int(floor((x - origin.x) / CELL)), 0, nx - 2)
	var gz := clampi(int(floor((z - origin.y) / CELL)), 0, nz - 2)
	var best := -1
	var best_d := INF

	for k: int in [gz * nx + gx, gz * nx + gx + 1, (gz + 1) * nx + gx, (gz + 1) * nx + gx + 1]:
		var start := nearest[k]

		for i in range(maxi(start - 12, 0), mini(start + 12, _points.size() - 1) + 1):
			var dx := _points[i].x - x
			var dz := _points[i].z - z
			var d := dx * dx + dz * dz

			if d < best_d:
				best_d = d
				best = i

	return best


func vertex_at(k: int) -> Vector3:
	return Vector3(origin.x + float(k % nx) * CELL, heights[k], origin.y + float(k / nx) * CELL)


## The node that draws it: one mesh, one material whose per-zone snow and wet [method paint]
## sets.
func make_node(grain: Texture2D) -> MeshInstance3D:
	var vertices := PackedVector3Array()
	var colours := PackedColorArray()
	var zones := PackedVector2Array()
	var blends := PackedVector2Array()
	var indices := PackedInt32Array()
	var count := nx * nz
	vertices.resize(count)
	colours.resize(count)
	zones.resize(count)
	blends.resize(count)

	for k in count:
		var v := vertex_at(k)
		vertices[k] = v
		var up := normals[k].y
		var ground := ROCK.lerp(GRASS, smoothstep(0.78, 0.9, up))
		ground = SHORE.lerp(ground, smoothstep(water_y + 1.0, water_y + 6.0, v.y))
		# Alpha is not transparency here: the shader reads it as snow that never melts.
		ground.a = smoothstep(SNOW_FROM, SNOW_FULL, v.y)
		colours[k] = ground
		# Two zones and how far between them: the weather changes over 40 m of road rather than
		# along the one line where the nearest sample changes segment, which from above was a
		# straight white edge across the mountain.
		var i := nearest[k]
		var lo := maxi(i - ZONE_BLEND, 0)
		var hi := mini(i + ZONE_BLEND, _sample_zone.size() - 1)
		var into := 0

		for j in range(lo, hi + 1):
			if _sample_zone[j] == _sample_zone[hi]:
				into += 1

		zones[k] = Vector2(float(_sample_zone[lo]), float(_sample_zone[hi]))
		blends[k] = Vector2(float(into) / float(hi - lo + 1) if _sample_zone[lo] != _sample_zone[hi] else 0.0, 0.0)

	indices.resize((nx - 1) * (nz - 1) * 6)
	var w := 0

	for gz in nz - 1:
		for gx in nx - 1:
			var a := gz * nx + gx
			var b := a + 1
			var c := a + nx + 1
			var d := a + nx
			# Clockwise from above, which is Godot's front face; height_at splits the same way.
			indices[w] = a
			indices[w + 1] = b
			indices[w + 2] = c
			indices[w + 3] = a
			indices[w + 4] = c
			indices[w + 5] = d
			w += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_TEX_UV] = blends
	arrays[Mesh.ARRAY_TEX_UV2] = zones
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := ShaderMaterial.new()
	material.shader = _shader()
	material.set_shader_parameter("grain", grain)
	material.set_shader_parameter("zone_snow", _zeros())
	material.set_shader_parameter("zone_wet", _zeros())

	var node := MeshInstance3D.new()
	node.name = "Terrain"
	node.mesh = mesh
	node.material_override = material
	# The cliffs and the trucks cast the shadows that matter; the mountain's own were a fifth of a
	# software-rendered frame, and its normals already shade it.
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


## Snow and rain on one zone's ground, as [method DdRoute.paint_zone] does the road.
func paint(node: MeshInstance3D, zone: String, snowy: bool, rainy: bool) -> void:
	if node == null or not zone_index.has(zone):
		return

	var material := node.material_override as ShaderMaterial
	var snow: PackedFloat32Array = material.get_shader_parameter("zone_snow")
	var wet: PackedFloat32Array = material.get_shader_parameter("zone_wet")
	# The road's "" stretch is how forced weather reaches every zone (DdGame._refresh_weather):
	# here "" is only the ground nearest the unnamed road, so it paints just that.
	var at := int(zone_index[zone])
	snow[at] = 1.0 if snowy else 0.0
	wet[at] = 1.0 if rainy and not snowy else 0.0
	material.set_shader_parameter("zone_snow", snow)
	material.set_shader_parameter("zone_wet", wet)


## Where a pine or a rock stands on the mountain: [code][{"at": Vector3, "roll": float,
## "rock": bool}][/code]. One candidate per 3x3 cells, from [DdWeather.unit] of the route and the
## block, so every client grows the same forest; each one stands at [method height_at] of its
## own position, sunk a little so a trunk on a slope does not show daylight on its low side.
func scatter() -> Array:
	var out: Array = []
	var gz := 1

	while gz < nz - 2:
		var gx := 1

		while gx < nx - 2:
			var roll := DdWeather.unit("%s|ground|%d|%d" % [_id, gx, gz])
			var jitter := DdWeather.unit("%s|ground-at|%d|%d" % [_id, gx, gz])
			var x := origin.x + (float(gx) + 0.2 + roll * 1.6) * CELL
			var z := origin.y + (float(gz) + 0.2 + jitter * 1.6) * CELL
			var fx := clampi(int(round((x - origin.x) / CELL)), 0, nx - 1)
			var fz := clampi(int(round((z - origin.y) / CELL)), 0, nz - 1)
			var k := fz * nx + fx
			var y := height_at(x, z)

			# Well clear of the road and the band's trench, above the shore, below the snow,
			# and on ground a tree could stand on.
			if beyond[k] > BAND + 6.0 and y > water_y + 3.0 and y < SNOW_FROM and normals[k].y > 0.72:
				var rock := roll > 0.8 or normals[k].y < 0.8
				if roll < 0.62 or rock:
					out.append({"at": Vector3(x, y - 0.6, z), "roll": roll, "rock": rock})

			gx += 3

		gz += 3

	return out


# --- Building ----------------------------------------------------------------

## The sample nearest every vertex, by two raster sweeps that hand each vertex its neighbours'
## candidates (a chamfer pass): every vertex against every sample is 25 million distances a
## route and seconds of loading; this is eight a vertex.
func _nearest_samples(points: PackedVector3Array) -> void:
	var count := nx * nz
	nearest.resize(count)
	nearest.fill(-1)
	var best := PackedFloat32Array()
	best.resize(count)
	best.fill(INF)

	for i in points.size():
		var cx := int(round((points[i].x - origin.x) / CELL))
		var cz := int(round((points[i].z - origin.y) / CELL))

		for dz in range(-1, 2):
			for dx in range(-1, 2):
				_offer(cx + dx, cz + dz, i, points, best)

	for _round in 2:
		for gz in nz:
			for gx in nx:
				_take_from(gx, gz, gx - 1, gz, points, best)
				_take_from(gx, gz, gx - 1, gz - 1, points, best)
				_take_from(gx, gz, gx, gz - 1, points, best)
				_take_from(gx, gz, gx + 1, gz - 1, points, best)

		for gz in range(nz - 1, -1, -1):
			for gx in range(nx - 1, -1, -1):
				_take_from(gx, gz, gx + 1, gz, points, best)
				_take_from(gx, gz, gx + 1, gz + 1, points, best)
				_take_from(gx, gz, gx, gz + 1, points, best)
				_take_from(gx, gz, gx - 1, gz + 1, points, best)


## What sample [param i] wants the ground at [param v] to be, and how far beyond its edge [param v]
## is: [code]Vector2(height, beyond)[/code]. The cliff side climbs to a ridge and comes down
## behind it; the drop side falls under the drop's rock slope to the water.
func _wish(i: int, v: Vector2) -> Vector2:
	var p := _points[i]
	var n := _points.size()
	var offset := v - Vector2(p.x, p.z)
	var right := Vector2(cos(_yaws[i]), -sin(_yaws[i]))
	var e := offset.length() - _half[i]
	var c := _cliff_right[i] if offset.dot(right) > 0.0 else _cliff_left[i]

	# Past either end of the road the mountain gives way: otherwise the first wall's mountain ran
	# on behind the lot to the edge of the grid and stood there as a block.
	var forward := Vector2(-sin(_yaws[i]), -cos(_yaws[i]))
	var out_of_ends := 0.0
	if i == 0:
		out_of_ends = -offset.dot(forward)
	elif i == n - 1:
		out_of_ends = offset.dot(forward)
	c *= 1.0 - smoothstep(0.0, 45.0, out_of_ends)

	var past := maxf(e, 0.0)
	var drop_h := maxf(p.y - _slab - DROP_UNDER - past * _drop_slope, water_y - 8.0)
	var ridge := p.y + _wall_height + RISE * (1.0 - exp(-past / RISE_RUN))
	var valley := maxf(p.y - 35.0, water_y - 8.0)
	var cliff_h := lerpf(ridge, valley, smoothstep(RIDGE_FROM, RIDGE_TO, past))
	return Vector2(lerpf(drop_h, cliff_h, c), e)


## The nearest sample on another stretch of road, by the same sweeps: a vertex takes its
## neighbours' nearest and second, and keeps one only if it is LEG samples from its own nearest.
func _second_samples(points: PackedVector3Array) -> void:
	var count := nx * nz
	second.resize(count)
	second.fill(-1)
	var best := PackedFloat32Array()
	best.resize(count)
	best.fill(INF)

	for gz in nz:
		for gx in nx:
			for o: Vector2i in BEFORE:
				_second_from(gx, gz, gx + o.x, gz + o.y, points, best)

	for gz in range(nz - 1, -1, -1):
		for gx in range(nx - 1, -1, -1):
			for o: Vector2i in BEFORE:
				_second_from(gx, gz, gx - o.x, gz - o.y, points, best)


const BEFORE: Array[Vector2i] = [Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]


func _second_from(gx: int, gz: int, ox: int, oz: int, points: PackedVector3Array, best: PackedFloat32Array) -> void:
	if ox < 0 or oz < 0 or ox >= nx or oz >= nz:
		return

	var k := gz * nx + gx
	var own := nearest[k]
	var x := origin.x + float(gx) * CELL
	var z := origin.y + float(gz) * CELL

	for i: int in [nearest[oz * nx + ox], second[oz * nx + ox]]:
		if i < 0 or absi(i - own) <= LEG:
			continue

		var dx := x - points[i].x
		var dz := z - points[i].z
		var d := dx * dx + dz * dz

		if d < best[k]:
			best[k] = d
			second[k] = i


func _take_from(gx: int, gz: int, ox: int, oz: int, points: PackedVector3Array, best: PackedFloat32Array) -> void:
	if ox < 0 or oz < 0 or ox >= nx or oz >= nz:
		return

	var i := nearest[oz * nx + ox]

	if i >= 0:
		_offer(gx, gz, i, points, best)


func _offer(gx: int, gz: int, i: int, points: PackedVector3Array, best: PackedFloat32Array) -> void:
	if gx < 0 or gz < 0 or gx >= nx or gz >= nz:
		return

	var k := gz * nx + gx
	var dx := origin.x + float(gx) * CELL - points[i].x
	var dz := origin.y + float(gz) * CELL - points[i].z
	var d := dx * dx + dz * dz

	if d < best[k]:
		best[k] = d
		nearest[k] = i


## Every vertex within [param radius] of [param at] to at most [param ceiling].
func _hold_under(at: Vector2, radius: float, ceiling: float) -> void:
	var x0 := maxi(int(floor((at.x - radius - origin.x) / CELL)), 0)
	var x1 := mini(int(ceil((at.x + radius - origin.x) / CELL)), nx - 1)
	var z0 := maxi(int(floor((at.y - radius - origin.y) / CELL)), 0)
	var z1 := mini(int(ceil((at.y + radius - origin.y) / CELL)), nz - 1)
	var r2 := radius * radius

	for gz in range(z0, z1 + 1):
		for gx in range(x0, x1 + 1):
			var dx := origin.x + float(gx) * CELL - at.x
			var dz := origin.y + float(gz) * CELL - at.y

			if dx * dx + dz * dz <= r2:
				var k := gz * nx + gx
				heights[k] = minf(heights[k], ceiling)


func _hold_under_pad(centre: Vector3, basis: Basis, half_size: Vector2, ceiling: float) -> void:
	var radius := half_size.length()
	var x0 := maxi(int(floor((centre.x - radius - origin.x) / CELL)), 0)
	var x1 := mini(int(ceil((centre.x + radius - origin.x) / CELL)), nx - 1)
	var z0 := maxi(int(floor((centre.z - radius - origin.y) / CELL)), 0)
	var z1 := mini(int(ceil((centre.z + radius - origin.y) / CELL)), nz - 1)

	for gz in range(z0, z1 + 1):
		for gx in range(x0, x1 + 1):
			var local := Vector3(origin.x + float(gx) * CELL, centre.y, origin.y + float(gz) * CELL) - centre

			if absf(local.dot(basis.x)) <= half_size.x and absf(local.dot(basis.z)) <= half_size.y:
				var k := gz * nx + gx
				heights[k] = minf(heights[k], ceiling)


func _bank_up_pad(centre: Vector3, basis: Basis, half_size: Vector2, top: float) -> void:
	var radius := half_size.length() + EMBANKMENT
	var x0 := maxi(int(floor((centre.x - radius - origin.x) / CELL)), 0)
	var x1 := mini(int(ceil((centre.x + radius - origin.x) / CELL)), nx - 1)
	var z0 := maxi(int(floor((centre.z - radius - origin.y) / CELL)), 0)
	var z1 := mini(int(ceil((centre.z + radius - origin.y) / CELL)), nz - 1)

	for gz in range(z0, z1 + 1):
		for gx in range(x0, x1 + 1):
			var local := Vector3(origin.x + float(gx) * CELL, centre.y, origin.y + float(gz) * CELL) - centre
			var outside := Vector2(maxf(absf(local.dot(basis.x)) - half_size.x, 0.0), maxf(absf(local.dot(basis.z)) - half_size.y, 0.0)).length()
			var k := gz * nx + gx

			# Flat to BAND past the pad (where the band holds it no higher anyway), then down at
			# about forty-five degrees.
			heights[k] = maxf(heights[k], top - maxf(outside - BAND, 0.0) * 1.1)


func _blur() -> void:
	var tmp := heights.duplicate()

	for gz in nz:
		for gx in nx:
			var k := gz * nx + gx
			tmp[k] = (heights[gz * nx + maxi(gx - 1, 0)] + heights[k] * 2.0 + heights[gz * nx + mini(gx + 1, nx - 1)]) * 0.25

	for gz in nz:
		for gx in nx:
			var k := gz * nx + gx
			heights[k] = (tmp[maxi(gz - 1, 0) * nx + gx] + tmp[k] * 2.0 + tmp[mini(gz + 1, nz - 1) * nx + gx]) * 0.25


func _normals() -> void:
	normals.resize(nx * nz)

	for gz in nz:
		for gx in nx:
			var l := heights[gz * nx + maxi(gx - 1, 0)]
			var r := heights[gz * nx + mini(gx + 1, nx - 1)]
			var u := heights[maxi(gz - 1, 0) * nx + gx]
			var d := heights[mini(gz + 1, nz - 1) * nx + gx]
			normals[gz * nx + gx] = Vector3(l - r, CELL * 2.0, u - d).normalized()


## Value noise in [-1, 1] on a lattice [param cell] metres apart, smoothly interpolated.
func _noise(x: float, z: float, cell: float, salt: int) -> float:
	var fx := x / cell
	var fz := z / cell
	var ix := int(floor(fx))
	var iz := int(floor(fz))
	var tx := fx - float(ix)
	var tz := fz - float(iz)
	tx = tx * tx * (3.0 - 2.0 * tx)
	tz = tz * tz * (3.0 - 2.0 * tz)
	var a := lerpf(_lattice(ix, iz, salt), _lattice(ix + 1, iz, salt), tx)
	var b := lerpf(_lattice(ix, iz + 1, salt), _lattice(ix + 1, iz + 1, salt), tx)
	return lerpf(a, b, tz)


func _lattice(ix: int, iz: int, salt: int) -> float:
	var key := Vector3i(ix, iz, salt)

	if not _noise_cache.has(key):
		_noise_cache[key] = DdWeather.unit("%s|terrain|%d|%d|%d" % [_id, salt, ix, iz]) * 2.0 - 1.0

	return _noise_cache[key]


## Each value the least within [param reach] samples: a wall's stretch, shrunk from both ends.
## The road's own two ends are not a wall ending, so they do not shrink it.
static func _erode(values: PackedFloat32Array, reach: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(values.size())

	for i in values.size():
		var m := 1.0

		for j in range(maxi(i - reach, 0), mini(i + reach, values.size() - 1) + 1):
			m = minf(m, values[j])

		out[i] = m

	return out


static func _smooth(values: PackedFloat32Array, reach: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(values.size())

	for i in values.size():
		var sum := 0.0
		var lo := maxi(i - reach, 0)
		var hi := mini(i + reach, values.size() - 1)

		for j in range(lo, hi + 1):
			sum += values[j]

		out[i] = sum / float(hi - lo + 1)

	return out


static func _zeros() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(MAX_ZONES)
	return out


static var _terrain_shader: Shader = null


static func _shader() -> Shader:
	if _terrain_shader == null:
		_terrain_shader = Shader.new()
		_terrain_shader.code = SHADER

	return _terrain_shader


## Rock on the steep, grass on the gentle, snow on the flat where the zone is snowing or the
## ground is high. Never writes ALPHA: writing it at all moves a surface into the transparent
## pass (docs/gdscript-hazards.md), and a mountain sorted per surface draws behind its road.
const SHADER := """
shader_type spatial;
render_mode cull_back;

uniform float zone_snow[8];
uniform float zone_wet[8];
uniform sampler2D grain : repeat_enable, filter_linear_mipmap;

varying float weather_snow;
varying float weather_wet;
varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	int a = clamp(int(UV2.x + 0.5), 0, 7);
	int b = clamp(int(UV2.y + 0.5), 0, 7);
	weather_snow = mix(zone_snow[a], zone_snow[b], UV.x);
	weather_wet = mix(zone_wet[a], zone_wet[b], UV.x);
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float g = texture(grain, world_pos.xz * 0.013).r * texture(grain, world_pos.xz * 0.07 + world_pos.y * 0.05).r;
	vec3 ground = COLOR.rgb * (0.6 + 0.55 * g);
	float lie = smoothstep(0.6, 0.82, world_normal.y);
	// A ragged edge where the weather or the snowline gives out, not a line.
	float cover = smoothstep(0.35, 0.65, max(weather_snow, COLOR.a) + (g - 0.45) * 0.5);
	float snow = cover * lie;
	float wet = weather_wet;
	ALBEDO = mix(ground * (1.0 - 0.35 * wet), vec3(0.88, 0.9, 0.95) * (0.9 + 0.1 * g), snow);
	ROUGHNESS = mix(1.0, 0.55, wet * (1.0 - snow));
}
"""
