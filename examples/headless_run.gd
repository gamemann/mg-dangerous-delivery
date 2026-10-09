extends Node

## The game, headless: documents, the road, the weather, the money, and trucks really driven.
##
##   godot --headless --path . res://examples/headless_run.tscn
##
## Counts sections entered against sections finished AND the checks, because a script error
## aborts the section it is in and the section counter alone is satisfied by that.

const DdGame := preload("res://game/dd_game.gd")
const DdRoute := preload("res://game/dd_route.gd")
const DdRouteDoc := preload("res://game/dd_route_doc.gd")
const DdWeather := preload("res://game/dd_weather.gd")
const DdTrucks := preload("res://game/dd_trucks.gd")
const DdTruck := preload("res://game/dd_truck.gd")
const DdBank := preload("res://game/dd_bank.gd")
const DdTrip := preload("res://game/dd_trip.gd")
const DdProgress := preload("res://game/dd_progress.gd")
const DdTerrain := preload("res://game/dd_terrain.gd")

const SECTIONS := 17
const CHECKS := 91

var _passed := 0
var _failed := 0
var _failures: PackedStringArray = PackedStringArray()
var _entered := 0
var _finished := 0
var game: DdGame = null
var progress: DdProgress = null
var _earned: Array = []


func _ready() -> void:
	print("dangerous delivery, headless")
	_test_documents()
	_test_road()
	_test_mountain()
	_test_weather()
	_test_trucks()
	_test_bank()
	_test_sql()

	game = DdGame.new()
	game.draws = false
	game.config.start_hold_seconds = 0.3
	game.config.respawn_seconds = 0.3
	game.config.seed_value = 77
	add_child(game)
	progress = DdProgress.new()
	add_child(progress)
	var _p := progress.setup(game, "", false)
	progress.earned.connect(func(key: StringName, title: String, _points: int) -> void: _earned.append([key, title]))

	_test_unlocking()
	await _test_a_delivery()
	await _test_a_fall()
	_test_solo()
	await _test_rock()
	_test_refusals()
	_test_pay()
	_test_ice_and_debris()
	await _test_a_trailer()
	await _test_the_client_settings()

	print("")
	print("%d sections entered, %d finished" % [_entered, _finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _entered != SECTIONS or _finished != SECTIONS:
		push_error("%d of %d sections finished, %d declared." % [_finished, _entered, SECTIONS])
		code = 1

	if _passed + _failed != CHECKS:
		push_error("%d checks ran, %d declared." % [_passed + _failed, CHECKS])
		code = 1

	get_tree().quit(code)


func _doc(segments: Array, extra: Dictionary = {}) -> Dictionary:
	var d := {"format": 1, "kind": "route", "id": "t", "segments": segments}
	d.merge(extra, true)
	return d


func _test_documents() -> void:
	_section("route documents")
	var dir := DirAccess.open("res://routes")
	var files := dir.get_files() if dir != null else PackedStringArray()
	var accepted := 0

	for f in files:
		if f.get_extension() == "json" and DdRouteDoc.normalise(JSON.parse_string(FileAccess.get_file_as_string("res://routes/" + f))).ok:
			accepted += 1

	_check(accepted == 5, "every shipped route is accepted", "%d" % accepted)
	_check(not DdRouteDoc.normalise(_doc([{"length": 10}], {"format": 2})).ok, "a newer format is refused")
	_check(not DdRouteDoc.normalise(_doc([{"length": 20, "turn": 90}])).ok, "a bend no truck can take is refused")
	_check(not DdRouteDoc.normalise(_doc([{"length": 20, "climb": 10}])).ok, "a climb too steep is refused")
	_check(not DdRouteDoc.normalise(_doc([{"length": 20, "zone": "nowhere"}])).ok, "a zone that is not declared is refused")
	_check(not DdRouteDoc.normalise(_doc([{"length": 20, "wall": "up"}])).ok, "a wall that is not a side is refused")
	var good := DdRouteDoc.normalise(_doc([{"length": 20}, {"length": 30, "checkpoint": true}, {"length": 10}]))
	_check(good.ok and good.value["stages"] == 2 and good.value["segments"][0]["turn"] is float,
		"an accepted one is normalised: stages counted, numbers floats")
	_finished_section()


func _test_road() -> void:
	_section("the road")
	var doc: Dictionary = DdRouteDoc.normalise(JSON.parse_string(FileAccess.get_file_as_string("res://routes/dd_snowline.json"))).value
	var road := DdRoute.new()
	add_child(road)
	var _b := road.build(doc)
	_check(absf(road.length() - DdRouteDoc.length_of(doc)) < 0.01, "its length is the document's", "%.2f" % road.length())
	_check(road.stages() == int(doc["stages"]), "and its stages", "%d" % road.stages())
	var probe := road.transform_at(300.0, 0.0).origin
	_check(absf(road.distance_at(probe) - 300.0) < 2.5, "a point on the road is found where it was put", "%.1f" % road.distance_at(probe))
	_check(road.stage_of(road.checkpoints[0] + 1.0) == 1 and road.stage_of(road.checkpoints[0] - 1.0) == 0,
		"a checkpoint counts from the line on")

	# The lower leg of the first hairpin, with the upper leg beside it: the hint keeps the truck
	# on its own leg.
	var low_d := 120.0
	var low := road.transform_at(low_d, 0.0).origin
	var near := road.nearest_index(low, road.index_at_distance(low_d))
	_check(absf(road.distances[near] - low_d) < 4.0, "the hint keeps a truck on its own leg of a switchback")

	var rocks := 0
	for seg: Dictionary in doc["segments"]:
		rocks += int(seg["boulders"])
	_check(road.boulder_sites.size() == rocks, "every boulder the document asks for has a site", "%d" % road.boulder_sites.size())
	road.queue_free()
	_finished_section()


## The mountain under every route ([DdTerrain]). Drawn only, so nothing a truck does can find
## it poking through the road: these are the only things that can.
func _test_mountain() -> void:
	_section("the mountain")
	var through: Array = []
	var under_pads: Array = []
	var cliffs := [0, 0]
	var overhangs: Array = []
	var crowded: Array = []
	var same := true

	for file in ["dd_foothills", "dd_river_cut", "dd_snowline", "dd_wind_ridge", "dd_devils_spine"]:
		var doc: Dictionary = DdRouteDoc.normalise(JSON.parse_string(FileAccess.get_file_as_string("res://routes/%s.json" % file))).value
		var road := DdRoute.new()
		road.draws = false
		add_child(road)
		var _b := road.build(doc)
		var ground := road.make_terrain()
		var segments: Array = doc["segments"]

		for i in road.points.size() - 1:
			var seg: Dictionary = segments[road.segment_of[i]]
			var half := float(seg["width"]) * 0.5
			var p := road.points[i]
			var right := DdRoute.right_of(road.yaws[i])
			var forward := DdRoute.forward_of(road.yaws[i])
			var slab_bottom := p.y - absf(tan(deg_to_rad(float(seg["bank"])))) * half - DdRoute.SLAB

			# Across the whole road and half a metre past each edge, twice between samples: the
			# drawn surface is what is asked, triangles and all, not the grid's vertices.
			for along: float in [0.0, 1.0]:
				var lateral := -half - 0.5
				while lateral <= half + 0.5:
					var at := p + right * lateral + forward * along
					var h := ground.height_at(at.x, at.z)
					if h > slab_bottom:
						through.append("%s @%.0f m lateral %.1f: ground %.2f over %.2f" % [file, road.distances[i], lateral, h, slab_bottom])
					lateral += 0.5

			# Behind the middle of a long wall the mountain stands higher than the wall's top,
			# so the top of the cliff meets ground rather than sky.
			var wall := str(seg["wall"])
			var lo := maxi(i - 12, 0)
			var hi := mini(i + 12, road.points.size() - 1)
			if road.segment_of[lo] == road.segment_of[i] and road.segment_of[hi] == road.segment_of[i]:
				for side: float in [-1.0, 1.0]:
					if wall == "both" or (wall == "left" and side < 0.0) or (wall == "right" and side > 0.0):
						var behind := p + right * side * (half + DdTerrain.CAP + 4.0)
						cliffs[0] += 1
						if ground.height_at(behind.x, behind.z) >= p.y + DdRoute.WALL_HEIGHT:
							cliffs[1] += 1

						# The cliff's top runs back CAP metres: none of it over any road.
						var back := 1.0
						while back <= DdTerrain.CAP:
							var cap := p + right * side * (half + back)
							var j := ground.sample_near(cap.x, cap.z)
							var flat := Vector2(cap.x - road.points[j].x, cap.z - road.points[j].z).length()
							var jhalf := float(segments[road.segment_of[j]]["width"]) * 0.5
							if flat < jhalf + 0.5:
								overhangs.append("%s @%.0f m over the road at %.0f m" % [file, road.distances[i], road.distances[j]])
							back += 3.0

		for pad: Transform3D in [road.transform_at(0.0, 0.0), road.transform_at(road.length(), 0.0)]:
			var far := -1.0 if pad == road.transform_at(0.0, 0.0) else 1.0
			for x in range(-16, 17, 4):
				for z in range(0, 41, 4):
					var at := pad.origin + pad.basis.x * float(x) + pad.basis.z * (-far * float(z))
					if ground.height_at(at.x, at.z) > pad.origin.y - DdRoute.SLAB:
						under_pads.append("%s pad at %s" % [file, at])

		for spot: Dictionary in ground.scatter():
			var at: Vector3 = spot["at"]
			var j := ground.sample_near(at.x, at.z)
			var flat := Vector2(at.x - road.points[j].x, at.z - road.points[j].z).length()
			if flat < float(segments[road.segment_of[j]]["width"]) * 0.5 + DdTerrain.BAND:
				crowded.append("%s %s by the road at %.0f m" % [file, at, road.distances[j]])

		if file == "dd_snowline":
			same = road.make_terrain().heights == ground.heights

		road.free()

	_check(through.is_empty(), "the mountain never rises through a road, on any route", "%d: %s" % [through.size(), ", ".join(through.slice(0, 3))])
	_check(under_pads.is_empty(), "nor through the lot or the depot", "%d: %s" % [under_pads.size(), ", ".join(under_pads.slice(0, 3))])
	_check(cliffs[0] > 50 and cliffs[1] >= cliffs[0] * 9 / 10, "behind nine cliffs in ten it stands above the wall's top", "%d of %d" % [cliffs[1], cliffs[0]])
	_check(overhangs.is_empty(), "and no cliff's top hangs over another stretch of road", "%d: %s" % [overhangs.size(), ", ".join(overhangs.slice(0, 3))])
	_check(crowded.is_empty() and same, "its trees keep off the road, and every machine raises the same mountain", "%d: %s" % [crowded.size(), ", ".join(crowded.slice(0, 3))])
	_finished_section()


func _test_weather() -> void:
	_section("the weather")
	var zone := {"snow": 0.5, "rain": 0.5, "wind": 0.5}
	var a := DdWeather.at(9, "r|z", zone, 12345, 60)
	var b := DdWeather.at(9, "r|z", zone, 12345, 60)
	_check(a == b, "the same seed, zone and tick give the same sky")

	var skies := {}
	for period in 40:
		skies[int(DdWeather.at(9, "r|z", zone, int(period * DdWeather.PERIOD_SECONDS * 60.0), 60)["sky"])] = true
	_check(skies.size() == 3, "over forty periods a mixed zone is clear, wet and snowy", str(skies.keys()))
	_check(int(DdWeather.at(9, "r|z", zone, 0, 60, 0.0)["sky"]) == DdWeather.CLEAR, "a frequency of 0 is a clear sky")
	_check(DdWeather.grip({"sky": DdWeather.SNOW}, 0.4, 0.7) == 0.4 and DdWeather.grip({"sky": DdWeather.CLEAR}, 0.4, 0.7) == 1.0,
		"snow and dry grip are the configuration's")
	var gusts := PackedFloat32Array()
	for t in 600:
		gusts.append(DdWeather.gust(9, "r|z", t * 10, 60))
	_check(is_equal_approx(gusts[0], DdWeather.gust(9, "r|z", 0, 60)) and absf(gusts[0]) <= 1.0, "a gust is a pure function of the tick, within 1")
	_finished_section()


func _test_trucks() -> void:
	_section("trucks and upgrades")
	var trucks := DdTrucks.new()
	_check(trucks.order.size() == 5 and trucks.starter() == &"box_truck", "five trucks, and the free one is the starter")
	var plain := trucks.tunables_for(&"hauler")
	var tuned := trucks.tunables_for(&"hauler", {"engine": 2, "tyres": 1})
	_check(tuned.engine_force > plain.engine_force * 1.2 and tuned.friction_slip > plain.friction_slip, "upgrades raise the engine and the grip")
	_check(trucks.upgrade_cost(&"box_truck", "engine", 0) == 300, "the free truck's upgrades are not free", "%d" % trucks.upgrade_cost(&"box_truck", "engine", 0))
	_check(trucks.upgrade_cost(&"hauler", "engine", 3) == -1, "past the last level there is nothing to buy")
	var _o := trucks.apply_overrides({"hauler": {"price": 5000}, "tanker": {"name": "Tanker", "price": 7000, "pay": 1.9}})
	_check(int(trucks.get_truck(&"hauler")["price"]) == 5000 and trucks.order.has(&"tanker"), "an owner's file changes a price and adds a truck")

	var truck := DdTruck.new()
	var made := truck.configure(&"hauler", trucks.get_truck(&"hauler"), trucks.tunables_for(&"hauler"), false)
	_check(made.ok and truck.wheel_count() == 4, "a truck is built from the model's own wheels", "%d" % truck.wheel_count())
	truck.free()
	_finished_section()


func _test_bank() -> void:
	_section("the bank")
	var path := "user://test_delivery_accounts.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var bank := DdBank.new()
	bank.store = DdBank.JsonStore.new(path)
	bank.starter_truck = &"box_truck"
	add_child(bank)
	_check(bank.money(&"p") == 0 and bank.owns(&"p", &"box_truck"), "a new player has the starter and nothing else")
	_check(not bank.spend(&"p", 10, "x").ok, "nobody spends money they do not have")
	var _c := bank.credit(&"p", 2000, "test")
	_check(bank.buy_truck(&"p", &"flatbed", 1500).ok and bank.money(&"p") == 500, "a truck costs its price")
	_check(not bank.buy_truck(&"p", &"flatbed", 1500).ok, "and is not bought twice")
	_check(bank.buy_upgrade(&"p", &"flatbed", "engine", 300).ok and bank.upgrade_level(&"p", &"flatbed", "engine") == 1, "an upgrade is a level")
	_check(not bank.select_truck(&"p", &"bulk").ok, "nobody drives a truck they do not own")

	var again := DdBank.new()
	again.store = DdBank.JsonStore.new(path)
	add_child(again)
	_check(again.money(&"p") == 200 and again.owns(&"p", &"flatbed") and again.upgrade_level(&"p", &"flatbed", "engine") == 1,
		"all of it is there after a restart", "%d" % again.money(&"p"))
	bank.queue_free()
	again.queue_free()
	_finished_section()


class FakeDriver:
	extends RefCounted
	var which: int = 0
	var statements: Array = []
	var rows: Array = []
	func dialect() -> int:
		return which
	func execute(sql: String, params: Array) -> DotResult:
		statements.append({"sql": sql, "params": params})
		return DotResult.success(true)
	func query(sql: String, params: Array) -> DotResult:
		statements.append({"sql": sql, "params": params})
		return DotResult.success(rows)


func _test_sql() -> void:
	_section("the bank in a database")
	var lite := FakeDriver.new()
	var store := DdBank.SqlStore.new(lite)
	var saved := store.save_account("u1", {"name": "Ann", "money": 900, "deliveries": 3, "trucks": ["box_truck"]})
	_check(saved.ok and str(lite.statements[0]["sql"]).begins_with("CREATE TABLE IF NOT EXISTS delivery_accounts"), "the table is made first")
	_check(str(lite.statements[1]["sql"]).contains("ON CONFLICT(player_key)") and lite.statements[1]["params"][2] == 900,
		"SQLite upserts, money as a column")
	var pg := FakeDriver.new()
	pg.which = DdBank.SqlStore.POSTGRES
	var _p := DdBank.SqlStore.new(pg).save_account("u1", {"money": 1})
	_check(str(pg.statements[1]["sql"]).contains("$6") and str(pg.statements[1]["sql"]).contains("EXCLUDED"), "PostgreSQL numbers its parameters")
	var my := FakeDriver.new()
	my.which = DdBank.SqlStore.MYSQL
	var _m := DdBank.SqlStore.new(my).save_account("u1", {"money": 1})
	_check(str(my.statements[1]["sql"]).contains("ON DUPLICATE KEY UPDATE"), "MySQL says it its own way")
	lite.rows = [{"player_key": "u1", "display_name": "Ann", "money": 1234, "deliveries": 4, "data": JSON.stringify({"trucks": ["box_truck", "hauler"]})}]
	var row := store.load_account("u1")
	_check(int(row["money"]) == 1234 and (row["trucks"] as Array).has("hauler"), "a row by column comes back as the account, the column winning")
	lite.rows = [["u1", "Ann", 77, 1, "{}"]]
	_check(int(store.load_account("u1")["money"]) == 77, "and so does a row in column order")
	_finished_section()


func _test_unlocking() -> void:
	_section("levels open in order")
	var _me := game.join(&"p1", "Player One")
	_check(game.route_order.size() == 5 and game.route_order[0] == &"dd_foothills", "the routes are in level order")
	_check(game.is_unlocked(&"p1", &"dd_foothills") and not game.is_unlocked(&"p1", &"dd_river_cut"), "level 1 is open and level 2 is not")
	_check(not game.start_trip(&"p1", &"dd_snowline").ok, "a locked route cannot be started")
	var view := game.garage_view(&"p1")
	_check((view["routes"] as Array).size() == 5 and bool(view["routes"][1]["locked"]), "the garage shows which are locked")
	_finished_section()


func _test_a_delivery() -> void:
	_section("a delivery, driven")
	var started := game.start_trip(&"p1", &"dd_foothills")
	var me: DdGame.Driver = game.drivers[&"p1"]
	_check(started.ok and me.on_road(), "a trip sets off")
	_check((me.trip as DdTrip).state == DdTrip.State.HOLD, "held at the start first")
	await _seconds(1.2)
	_check((me.trip as DdTrip).state == DdTrip.State.DRIVING and (me.truck as DdTruck).wheels_on_ground() == 4,
		"then driving, on all four wheels", "%s %d" % [(me.trip as DdTrip).state_name(), (me.truck as DdTruck).wheels_on_ground()])

	# To the last checkpoint by skipping, then a stand-in drives the last stretch for real.
	var stages: int = (me.trip as DdTrip).stages
	for i in stages - 1:
		var _s := game.skip(&"p1")
	_check((me.trip as DdTrip).stage == stages - 1 and (me.trip as DdTrip).skips == stages - 1, "skipping counts every stage it skips")
	me.assisted = true
	me.idle = 999.0
	me.autopilot = DotVehicleDriver.new()
	me.autopilot.target_speed = 11.0
	me.autopilot.set_route(game._global_points(&"dd_foothills", (me.trip as DdTrip).distance))
	var paid := [-1]
	game.delivered.connect(func(key: StringName, _r: StringName, pay: int) -> void:
		if key == &"p1":
			paid[0] = pay)
	var until := Time.get_ticks_msec() + 40000
	while paid[0] < 0 and Time.get_ticks_msec() < until:
		await get_tree().physics_frame
	_check(paid[0] > 0, "the stand-in reaches the depot and it pays", "%d after %.0f m" % [paid[0], (me.trip as DdTrip).distance])
	_check(game.bank.money(&"p1") == paid[0] and game.bank.has_delivered(&"p1", &"dd_foothills"), "the pay is in the bank and the route is marked")
	_check(game.is_unlocked(&"p1", &"dd_river_cut"), "and level 2 is open")
	await get_tree().process_frame
	var numbers := progress.session_values(&"p1")
	_check(numbers.get_value(DdProgress.DELIVERIES) == 1.0 and numbers.get_value(DdProgress.EARNED) == float(paid[0]),
		"dot-stats counts the delivery and what it paid", str(numbers.to_dictionary()))
	_check(_earned.has([&"p1", "First Load"]), "and the first one is an achievement", str(_earned))
	me.assisted = false
	me.autopilot = null
	game.end_trip(&"p1")
	_check(not me.on_road(), "back to the garage, and the truck is gone")
	_finished_section()


func _test_a_fall() -> void:
	_section("over the edge")
	var _s := game.start_trip(&"p1", &"dd_river_cut")
	var me: DdGame.Driver = game.drivers[&"p1"]
	await _seconds(0.6)
	var road: DdRoute = game.routes[&"dd_river_cut"]
	var why := [""]
	game.fell.connect(func(key: StringName, reason: String) -> void:
		if key == &"p1":
			why[0] = reason)
	# Thirty metres off the drop side (the right: River Cut's cliff is on the left).
	var at := road.transform_at(200.0, 0.0)
	at.origin += road.position + at.basis.x * 30.0
	(me.truck as DdTruck).place(at)
	var until := Time.get_ticks_msec() + 8000
	while why[0] == "" and Time.get_ticks_msec() < until:
		await get_tree().physics_frame
	var trip: DdTrip = me.trip
	_check(why[0] == "fell", "a truck off the road falls", why[0])
	_check(trip.falls == 1 and is_equal_approx(trip.cargo, 1.0 - game.config.fall_cargo_loss), "a fall costs the configured share of the load", "%.2f" % trip.cargo)
	await _seconds(0.8)
	_check(trip.state == DdTrip.State.DRIVING and absf(road.distance_at((me.truck as Node3D).global_position - road.position) - road.checkpoint_distance(trip.stage)) < 3.0,
		"and it is put back on its checkpoint")
	_check(trip.pay_now(game.config) < _clean_offer(trip), "a fall loses the clean-run bonus")
	_check(progress.session_values(&"p1").get_value(DdProgress.FALLS) == 1.0, "and is counted")
	_finished_section()


func _clean_offer(trip: DdTrip) -> int:
	var copy := DdTrip.new()
	copy.base_pay = trip.base_pay
	copy.level = trip.level
	copy.truck_pay = trip.truck_pay
	copy.chaos_units = trip.chaos_units
	return copy.pay_now(game.config)


func _test_solo() -> void:
	_section("solo")
	var _two := game.join(&"p2", "Player Two")
	var _s := game.start_trip(&"p2", &"dd_foothills")
	var one: DdGame.Driver = game.drivers[&"p1"]
	var two: DdGame.Driver = game.drivers[&"p2"]
	one.ghost_until = 0.0
	two.ghost_until = 0.0
	game._refresh_exceptions()
	var t1 := one.truck as PhysicsBody3D
	var t2 := two.truck as PhysicsBody3D
	_check(not t1.get_collision_exceptions().has(t2), "two trucks collide")
	var _on := game.set_solo(&"p2", true)
	_check(t1.get_collision_exceptions().has(t2) and t2.get_collision_exceptions().has(t1), "not once one of them is solo, both ways")
	_check(not game.sees(two, one) and not game.sees(one, two), "and neither sees the other")
	game.config.solo_hidden_from_others = false
	_check(game.sees(one, two) and not game.sees(two, one), "unless the server shows solo players to others")
	game.config.solo_hidden_from_others = true
	var _off := game.set_solo(&"p2", false)
	_check(not t1.get_collision_exceptions().has(t2), "back off, they collide again")
	game.config.allow_solo = false
	_check(not game.set_solo(&"p2", true).ok, "a server can refuse solo")
	game.config.allow_solo = true
	_finished_section()


func _test_rock() -> void:
	_section("falling rock")
	var two: DdGame.Driver = game.drivers[&"p2"]
	var trip: DdTrip = two.trip
	var road: DdRoute = game.routes[&"dd_foothills"]
	var site: Dictionary = road.boulder_sites[0]
	trip.distance = float(site["d"]) - 20.0
	var before := trip.chaos_units
	game._drop_boulder(&"dd_foothills", road, site, 2.0)
	_check(game.boulders.size() == 1, "a boulder comes off the cliff")
	_check(is_equal_approx(trip.chaos_units - before, game.config.boulder_chaos) and trip.boulders == 1, "the trip beside it is paid for it")
	var body: RigidBody3D = game.boulders.keys()[0]
	var start_y := body.global_position.y
	await _seconds(0.5)
	# Measured before a second one is dropped on the same spot: two rocks made in one place
	# shove each other apart, and the first version of this check watched one go UP.
	_check(body.global_position.y < start_y - 0.5, "it falls", "%.1f -> %.1f" % [start_y, body.global_position.y])
	# The world measured the truck where it really is in the meantime; put it back by the site.
	trip.distance = float(site["d"]) - 20.0
	game._drop_boulder(&"dd_foothills", road, site, 2.0)
	_check(is_equal_approx(trip.chaos_units - before, game.config.boulder_chaos) and trip.boulders == 2, "but it is paid once per stretch of cliff")
	_finished_section()


func _test_refusals() -> void:
	_section("what a server can turn off")
	game.config.allow_skip = false
	_check(not game.skip(&"p2").ok, "skipping")
	game.config.allow_skip = true
	game.config.allow_restart = false
	_check(not game.restart(&"p2").ok, "restarting")
	game.config.allow_restart = true
	_check(game.restart(&"p2").ok and (game.drivers[&"p2"].trip as DdTrip).stage == 0, "and restarting goes back to the lot")
	_check(game.force_weather("snow").ok and int(game.weather_at(&"dd_foothills", 50.0)["sky"]) == DdWeather.SNOW, "an operator can make it snow")
	_check(not game.force_weather("hail").ok, "but not hail")
	var _clear := game.force_weather("")
	_finished_section()


func _test_pay() -> void:
	_section("what a trip pays")
	var trip := DdTrip.new()
	trip.base_pay = 400.0
	trip.level = 3
	trip.truck_pay = 1.6
	trip.chaos_units = 0.5
	trip.cargo = 0.8
	var c := game.config
	var expected := 400.0 * (1.0 + c.level_pay_step * 2.0) * 1.6 * (1.0 + c.chaos_pay * 0.5) * 0.8 * (1.0 + c.clean_run_bonus)
	_check(trip.pay_now(c) == int(round(expected)), "level, truck, chaos, cargo and a clean run, multiplied", "%d vs %.1f" % [trip.pay_now(c), expected])
	trip.cargo = 0.0
	_check(trip.pay_now(c) > 0, "a wrecked load still pays the floor")
	trip.cargo = 1.0
	trip.skips = 1
	_check(trip.pay_now(c) < int(round(expected / 0.8)), "a skip costs")
	_check(trip.meet("z", {"sky": DdWeather.SNOW, "wind": true}, 0.5, 0.25, 0.3) and not trip.meet("z", {"sky": DdWeather.SNOW, "wind": true}, 0.5, 0.25, 0.3),
		"a zone's weather is paid once")
	_finished_section()


func _test_ice_and_debris() -> void:
	_section("black ice and fallen rock")
	var road: DdRoute = game.routes[&"dd_snowline"]
	_check(road.ice.size() == 3 and road.debris.size() == 1, "the document's patches and piles are laid", "%d ice, %d debris" % [road.ice.size(), road.debris.size()])
	var patch: Dictionary = road.ice[0]
	var on := road.transform_at(float(patch["d"]), 0.5).origin + road.transform_at(float(patch["d"]), 0.0).basis.x * float(patch["lateral"])
	_check(road.on_ice(on) and not road.on_ice(road.transform_at(float(patch["d"]) + 40.0, 0.5).origin), "a truck on a patch is on ice, and one past it is not")
	var pile: Dictionary = road.debris[0]
	var lane := 0.0
	var waypoints := road.route_points(0.0, 8.0)
	for p in waypoints:
		var d := road.distance_at(p)
		if absf(d - float(pile["d"])) < 8.0:
			lane = road.lateral_at(p)
	_check(lane != 0.0 and signf(lane) != signf(float(pile["lateral"])), "a stand-in's route goes round a pile, in the other lane", "%.1f vs %.1f" % [lane, float(pile["lateral"])])
	var fresh := DdRoute.new()
	add_child(fresh)
	var _b := fresh.build(road.doc)
	_check(fresh.ice == road.ice and fresh.debris == road.debris, "and every machine lays them in the same places")
	fresh.queue_free()
	_finished_section()


func _test_a_trailer() -> void:
	_section("an eighteen-wheeler")
	var _j := game.join(&"semi", "Semi Driver")
	var _c := game.bank.credit(&"semi", 100000, "test")
	_check(game.buy_truck(&"semi", &"semi").ok, "the Semi can be bought")
	var _s := game.start_trip(&"semi", &"dd_foothills")
	var me: DdGame.Driver = game.drivers[&"semi"]
	var trailer = me.trailer
	_check(trailer != null and trailer.joint != null, "it comes with a trailer, hitched")
	me.assisted = true
	me.idle = 999.0
	me.autopilot = DotVehicleDriver.new()
	me.autopilot.target_speed = 10.0
	me.autopilot.set_route(game._global_points(&"dd_foothills", 4.0))
	await _seconds(8.0)
	var truck := me.truck as Node3D
	var gap := truck.global_position.distance_to(trailer.global_position)
	_check((me.trip as DdTrip).distance > 30.0 and gap < 9.0, "the trailer follows it up the road (%.0f m along, %.1f m behind)" % [(me.trip as DdTrip).distance, gap])
	var _r := game.respawn(&"semi")
	await _seconds(0.8)
	_check(absf(trailer.angle_to(truck)) < 10.0 and truck.global_position.distance_to(trailer.global_position) < 9.0,
		"and is put back straight behind it after a respawn (%.1f degrees)" % trailer.angle_to(truck))
	game.end_trip(&"semi")
	await get_tree().process_frame
	_check(me.trailer == null and not is_instance_valid(trailer), "and goes with the truck")
	game.leave(&"semi")
	_finished_section()


# --- Harness -----------------------------------------------------------------

func _seconds(s: float) -> void:
	var until := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().physics_frame


## A real offline client, booted: its settings are read by its camera, and the lot's
## SETTINGS button opens them (Escape is the lot's own key here).
func _test_the_client_settings() -> void:
	_section("the client's settings are read, and the lot opens them")
	var client: Node = (load("res://game/dd_client.gd") as GDScript).new()
	add_child(client)

	for i in 6:
		await get_tree().process_frame

	var settings: Variant = client.get("settings")
	var camera: Camera3D = client.get("camera")
	_check(
		settings != null and camera != null and bool(settings.describe().get("camera_bound", false)) \
			and is_equal_approx(camera.fov, float(settings.settings.get_int(&"field_of_view", 0))),
		"the client's settings are read by its camera",
		str(settings.describe()) if settings != null else "no settings"
	)
	var garage: Node = client.get("garage")
	var button := garage.find_child("Settings", true, false) as Button if garage != null else null
	if button != null:
		button.pressed.emit()
	_check(button != null and settings != null and settings.is_open(), "and the lot's SETTINGS button opens them")

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished_section()


func _section(name: String) -> void:
	_entered += 1
	print("")
	print(name)


func _finished_section() -> void:
	_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s  (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)
