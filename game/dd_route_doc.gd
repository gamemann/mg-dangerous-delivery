extends RefCounted

## What a route IS: a document a server reads, checks, and sends whole to every client.
##
## [b]A road is written the way somebody would describe it out loud[/b] — "two hundred metres
## straight and climbing, then a hard right round the cliff" — as a list of segments, each a
## length, a turn and a climb from where the last one ended. Not a list of points: a point
## list is what a tool writes, and the brief is that a server owner writes their own maps.
## Moving one bend moves everything after it, which is what a person editing a road means.
##
## [codeblock]
## {
##   "format": 1, "kind": "route", "id": "dd_foothills", "name": "Foothills",
##   "author": "you", "blurb": "One line.", "level": 1, "pay": 400, "width": 7.5,
##   "zones": {"pass": {"name": "The Pass", "snow": 0.8, "rain": 0.0, "wind": 0.3}},
##   "segments": [
##     {"length": 80},
##     {"length": 120, "turn": -60, "climb": 12, "wall": "left", "zone": "pass"},
##     {"length": 60, "checkpoint": true, "boulders": 2, "width": 6.0, "rail": "none"}
##   ]
## }
## [/codeblock]
##
## Every length is metres, every angle degrees (positive turns right), and a segment's
## `climb` is its whole rise (negative descends). `wall` is the cliff side: "left", "right",
## "both" or "none"; the other side is the drop. `rail` is a low barrier on a side; the
## default is none, because a mountain road with rails is not this game.

const FORMAT := 1

const WALLS := ["none", "left", "right", "both"]

## The most a segment may turn per metre, in degrees. A tighter bend than a truck can
## take is a road nobody can drive, and the validator is the place to say so.
const MAX_TURN_PER_METRE := 2.2

## The steepest a segment may climb, as rise over run. Fifteen percent is steep for a road
## and a loaded truck still makes it.
const MAX_GRADE := 0.18


## Checks [param doc] and returns it normalised (every optional field filled, every number a
## float) or the reason it is refused. A refused document is never half-played.
static func normalise(doc: Variant) -> DotResult:
	if not (doc is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "A route is a JSON object.")

	var d: Dictionary = doc

	if int(d.get("format", 0)) != FORMAT:
		return DotResult.fail(DotError.CODE_INVALID, "format is %s; this game reads %d." % [d.get("format"), FORMAT])

	if str(d.get("kind", "")) != "route":
		return DotResult.fail(DotError.CODE_INVALID, "kind is '%s'; a route says \"route\"." % d.get("kind", ""))

	var id := str(d.get("id", ""))

	if id == "" or not id.is_valid_identifier():
		return DotResult.fail(DotError.CODE_INVALID, "id '%s' is not a plain identifier." % id)

	var width := float(d.get("width", 7.5))

	if width < 4.0 or width > 30.0:
		return DotResult.fail(DotError.CODE_INVALID, "width %.1f is outside 4 to 30 metres." % width)

	var zones: Dictionary = {}
	var raw_zones: Variant = d.get("zones", {})

	if not (raw_zones is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "zones is an object of zone id to weather.")

	for zone_id: Variant in raw_zones:
		var z: Variant = raw_zones[zone_id]

		if not (z is Dictionary):
			return DotResult.fail(DotError.CODE_INVALID, "zone '%s' is not an object." % zone_id)

		var zone := {
			"name": str((z as Dictionary).get("name", zone_id)),
			"snow": clampf(float((z as Dictionary).get("snow", 0.0)), 0.0, 1.0),
			"rain": clampf(float((z as Dictionary).get("rain", 0.0)), 0.0, 1.0),
			"wind": clampf(float((z as Dictionary).get("wind", 0.0)), 0.0, 1.0),
		}
		zones[str(zone_id)] = zone

	var raw_segments: Variant = d.get("segments", [])

	if not (raw_segments is Array) or (raw_segments as Array).is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "A route needs at least one segment.")

	var segments: Array = []
	var checkpoints := 0

	for i in (raw_segments as Array).size():
		var s: Variant = raw_segments[i]

		if not (s is Dictionary):
			return DotResult.fail(DotError.CODE_INVALID, "segment %d is not an object." % i)

		var seg: Dictionary = s
		var length := float(seg.get("length", 0.0))

		if length < 2.0 or length > 2000.0:
			return DotResult.fail(DotError.CODE_INVALID, "segment %d: length %.1f is outside 2 to 2000 metres." % [i, length])

		var turn := float(seg.get("turn", 0.0))

		if absf(turn) / length > MAX_TURN_PER_METRE:
			return DotResult.fail(DotError.CODE_INVALID,
				"segment %d turns %.0f degrees in %.0f metres; a truck cannot take that." % [i, turn, length])

		var climb := float(seg.get("climb", 0.0))

		if absf(climb) / length > MAX_GRADE:
			return DotResult.fail(DotError.CODE_INVALID,
				"segment %d climbs %.0f metres in %.0f; the most is %.0f%%." % [i, climb, length, MAX_GRADE * 100.0])

		var wall := str(seg.get("wall", "none"))
		var rail := str(seg.get("rail", "none"))

		if not WALLS.has(wall) or not WALLS.has(rail):
			return DotResult.fail(DotError.CODE_INVALID, "segment %d: wall and rail are one of %s." % [i, WALLS])

		var zone := str(seg.get("zone", ""))

		if zone != "" and not zones.has(zone):
			return DotResult.fail(DotError.CODE_INVALID, "segment %d names zone '%s', which is not in zones." % [i, zone])

		var seg_width := float(seg.get("width", width))

		if seg_width < 4.0 or seg_width > 30.0:
			return DotResult.fail(DotError.CODE_INVALID, "segment %d: width %.1f is outside 4 to 30 metres." % [i, seg_width])

		var checkpoint := bool(seg.get("checkpoint", false))

		if checkpoint:
			checkpoints += 1

		segments.append({
			"length": length, "turn": turn, "climb": climb, "width": seg_width,
			"wall": wall, "rail": rail, "zone": zone, "checkpoint": checkpoint,
			"boulders": clampi(int(seg.get("boulders", 0)), 0, 32),
			"bank": clampf(float(seg.get("bank", 0.0)), -12.0, 12.0),
		})

	return DotResult.success({
		"format": FORMAT,
		"kind": "route",
		"id": id,
		"name": str(d.get("name", id)),
		"author": str(d.get("author", "")),
		"blurb": str(d.get("blurb", "")),
		"level": clampi(int(d.get("level", 1)), 1, 99),
		"pay": float(maxi(int(d.get("pay", 300)), 0)),
		"width": width,
		"cargo": str(d.get("cargo", "crates")),
		"zones": zones,
		"segments": segments,
		"stages": checkpoints + 1,
	})


## How long the road is, in metres, without building it.
static func length_of(doc: Dictionary) -> float:
	var total := 0.0

	for seg: Dictionary in doc.get("segments", []):
		total += float(seg["length"])

	return total
