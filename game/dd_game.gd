extends Node3D

## The mountain: every route this server has, every truck on them, and every rule a haul is
## played under. Headless — what a player sees is [DdClient]'s.
##
## [b]One world holds every route at once, laid side by side.[/b] The brief asked for a big
## map whose corners have their own weather, and for levels that get harder. Both are this:
## each route is a level (its document's `level`), each is a corner of the one world with its
## own zones, and a player picks which to drive from the garage. A server owner's new route
## is a file in `routes/` and a new corner of the map at the next boot.
##
## [b]Server-authoritative, and trucks are not predicted[/b] — dot-vehicle's decision, for its
## reason: two machines diverge on a rigid body within seconds, and a correction on something
## being steered reads worse than latency. What every machine computes for itself is what is a
## pure function: the road (from the document) and the weather (from the seed and the tick).
##
## [b]A player is their truck.[/b] Nobody walks: you are in the garage, or you are on a road.
## So there is no seat handover, and a driver is a record here rather than a body.

const DdConfig := preload("dd_config.gd")
const DdRoute := preload("dd_route.gd")
const DdRouteDoc := preload("dd_route_doc.gd")
const DdTruck := preload("dd_truck.gd")
const DdTrucks := preload("dd_trucks.gd")
const DdTrip := preload("dd_trip.gd")
const DdBank := preload("dd_bank.gd")
const DdWeather := preload("dd_weather.gd")
const DdPaths := preload("dd_paths.gd")

const CHANNEL := "delivery.game"

## The netcode's numbers, which are the game's: a module and a client both read them here, so
## the two ends cannot quantise positions against different ranges.
const NET_SNAPSHOT_RATE := 30

## Metres from the origin a replicated position may be. Every route is laid out inside it;
## [method build_routes] warns about one that is not.
const NET_WORLD_EXTENT := 4096.0
const SERVICE := &"delivery.game"

## Metres between routes when they are laid side by side.
const ROUTE_GAP := 160.0

## Seconds a truck that was just put down passes through other trucks, so two put on one
## checkpoint do not explode apart.
const GHOST_SECONDS := 3.0

signal trip_started(key: StringName, route_id: StringName)
signal stage_reached(key: StringName, stage: int)
signal fell(key: StringName, why: String)
signal put_back(key: StringName)
signal delivered(key: StringName, route_id: StringName, pay: int)
signal trip_ended(key: StringName)
signal solo_changed(key: StringName, on: bool)
signal boulder_dropped(route_id: StringName, at: Vector3)
## A boulder body exists, and one went: the bridge replicates the first and forgets the second.
signal boulder_made(body: RigidBody3D)
signal boulder_gone(body: RigidBody3D)
signal weather_changed(route_id: StringName, zone: String, weather: Dictionary)
signal driver_joined(key: StringName)
signal driver_left(key: StringName)

## One person (or stand-in) on the server.
class Driver:
	extends RefCounted
	var key: StringName = &""
	var name: String = ""
	var is_bot: bool = false
	var solo: bool = false
	var truck: Node = null
	var trip: RefCounted = null
	var command: DotVehicleCommand = DotVehicleCommand.new()
	var autopilot: DotVehicleDriver = null
	var ghost_until: float = 0.0
	## Seconds a stand-in waits at the depot before its next trip.
	var idle: float = 0.0

	func on_road() -> bool:
		return truck != null and trip != null


@export var authoritative: bool = true

## Whether this world draws. Off on a headless server.
@export var draws: bool = true

## Whether this world ticks itself from the physics frame. Off when a server module ticks it.
@export var self_tick: bool = true

## Whether this world registers itself under [constant SERVICE].
@export var register_service: bool = true

var config: DdConfig = null
var trucks: DdTrucks = null
var bank: DdBank = null

## route id -> normalised document, and the ones refused with why.
var documents: Dictionary = {}
var refused: Dictionary = {}

## route id -> DdRoute (in the tree, offset).
var routes: Dictionary = {}

## Route ids by level then name: the garage's order.
var route_order: Array[StringName] = []

## key -> Driver.
var drivers: Dictionary = {}

var tick_rate: int = 60
var tick: int = 0
var seed_value: int = 1

## "route|zone" -> weather Dictionary, as of the last tick.
var weather: Dictionary = {}

## Weather every zone has regardless of the draw: an operator's `dd_weather snow`, or a
## screenshot's. Empty lets the draw decide. Sent to clients like the seed, because the draw
## alone would no longer say what the sky is.
var forced_weather: Dictionary = {}

## Live boulders: RigidBody3D -> {"route", "born"}.
var boulders: Dictionary = {}

## "route|site" -> times it has come down, for the next roll's hash.
var _site_falls: Dictionary = {}

## "route|site" -> seconds until it may come down again.
var _site_cooldown: Dictionary = {}

var _now: float = 0.0


## Made here rather than in _ready, so whoever builds the world can set its rules before it
## is in the tree: the first suite to try wrote to a null config.
func _init() -> void:
	config = DdConfig.new()


func _ready() -> void:
	# Over whatever was set before: a file, the environment and the command line only change
	# what they name.
	var _loaded := config.load_layered("user://cfg/delivery.json")

	tick_rate = Engine.physics_ticks_per_second
	seed_value = config.seed_value if config.seed_value != 0 else int(Time.get_unix_time_from_system())

	if trucks == null:
		trucks = DdTrucks.new()
		var _over := trucks.load_overrides("user://cfg/delivery_trucks.json")

	if bank == null:
		bank = DdBank.new()
		bank.name = "Bank"
		add_child(bank)

	bank.starting_money = config.starting_money
	bank.starter_truck = trucks.starter()

	_apply_gravity()

	if authoritative:
		var _read := load_directory(DdPaths.rebase("res://%s" % config.route_directory) if not config.route_directory.begins_with("res://") and not config.route_directory.begins_with("user://") else config.route_directory)
		build_routes()

	if register_service:
		DotRegistry.register(SERVICE, self)

	set_physics_process(self_tick)
	DotLog.info(CHANNEL, "the mountain is ready", {"routes": routes.size(), "refused": refused.size()})


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


func _apply_gravity() -> void:
	var space := get_world_3d().space if is_inside_tree() and get_world_3d() != null else RID()

	if space.is_valid():
		PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY, config.gravity)


# --- Routes ------------------------------------------------------------------

## Reads every `.json` in [param directory]. Returns how many were accepted.
func load_directory(directory: String) -> int:
	var dir := DirAccess.open(directory)

	if dir == null:
		DotLog.warn(CHANNEL, "no route directory", {"path": directory})
		return 0

	var accepted := 0

	for file in dir.get_files():
		if file.get_extension() != "json":
			continue

		var path := directory.path_join(file)
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		var normal := DdRouteDoc.normalise(parsed)

		if not normal.ok:
			refused[file] = normal.error.message
			DotLog.warn(CHANNEL, "a route was refused", {"file": file, "why": normal.error.message})
			continue

		var doc: Dictionary = normal.value

		if not config.route_ids.is_empty() and not config.route_ids.has(str(doc["id"])):
			continue

		documents[StringName(str(doc["id"]))] = doc
		accepted += 1

	return accepted


## Builds every document as a route, side by side along +X. Rebuilds from scratch.
func build_routes() -> void:
	for id: StringName in routes:
		(routes[id] as Node).queue_free()

	routes.clear()
	route_order.clear()

	var ids: Array = documents.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool:
		var la := int(documents[a]["level"])
		var lb := int(documents[b]["level"])
		return la < lb if la != lb else String(a) < String(b))

	var next_x := 0.0

	for id: StringName in ids:
		var route := DdRoute.new()
		route.name = "Route_%s" % String(id)
		add_child(route)
		var _built := route.build(documents[id])
		var lo := INF
		var hi := -INF

		for p in route.points:
			lo = minf(lo, p.x)
			hi = maxf(hi, p.x)

		lo = minf(lo, -DdRoute.PAD_SIZE.x * 0.5)
		hi = maxf(hi, DdRoute.PAD_SIZE.x * 0.5)
		route.position = Vector3(next_x - lo, 0.0, 0.0)
		next_x += (hi - lo) + ROUTE_GAP
		routes[id] = route
		route_order.append(id)

		if next_x > NET_WORLD_EXTENT:
			DotLog.warn(CHANNEL, "a route lies outside what the netcode can place", {"route": String(id), "x": next_x})

	_refresh_weather(true)


## The documents as a client is sent them, in the garage's order.
func documents_in_order() -> Array:
	var out: Array = []

	for id in route_order:
		out.append(documents[id])

	return out


## Builds the routes a server sent. Client side.
func adopt_documents(docs: Array) -> void:
	documents.clear()

	for doc: Variant in docs:
		var normal := DdRouteDoc.normalise(doc)

		if normal.ok:
			documents[StringName(str(normal.value["id"]))] = normal.value

	build_routes()


func route(id: StringName) -> DdRoute:
	return routes.get(id, null)


## Whether [param key] may drive [param route_id]: the lowest level always, and each level
## after one of the level below it has been delivered (DdConfig.levels_unlock_in_order).
func is_unlocked(key: StringName, route_id: StringName) -> bool:
	if not documents.has(route_id):
		return false

	if not config.levels_unlock_in_order:
		return true

	var level := int(documents[route_id]["level"])
	var lowest := 999

	for id: StringName in documents:
		lowest = mini(lowest, int(documents[id]["level"]))

	if level <= lowest:
		return true

	for id: StringName in documents:
		if int(documents[id]["level"]) < level and bank.has_delivered(key, id):
			# Any route one level down, or any below that if a level is missing.
			if int(documents[id]["level"]) >= level - 1:
				return true

	return false


# --- Drivers -----------------------------------------------------------------

func join(key: StringName, name_text: String, is_bot: bool = false) -> Driver:
	if drivers.has(key):
		return drivers[key]

	var driver := Driver.new()
	driver.key = key
	driver.name = name_text
	driver.is_bot = is_bot
	drivers[key] = driver
	var _acct := bank.account(key, name_text)

	if is_bot:
		driver.autopilot = DotVehicleDriver.new()
		driver.autopilot.target_speed = 11.0
		driver.autopilot.waypoint_radius = 7.0

	driver_joined.emit(key)
	return driver


func leave(key: StringName) -> void:
	var driver: Driver = drivers.get(key, null)

	if driver == null:
		return

	_remove_truck(driver)
	drivers.erase(key)
	driver_left.emit(key)


## Sets off on [param route_id] in the player's selected truck.
func start_trip(key: StringName, route_id: StringName) -> DotResult:
	var driver: Driver = drivers.get(key, null)

	if driver == null:
		return DotResult.fail(DotError.CODE_STATE, "Nobody by that key.")

	if not routes.has(route_id):
		return DotResult.fail(DotError.CODE_INVALID, "No route '%s'." % route_id)

	if not is_unlocked(key, route_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Deliver a level %d route first." % (int(documents[route_id]["level"]) - 1))

	var truck_id := StringName(str(bank.account(key)["truck"]))

	if trucks.get_truck(truck_id).is_empty():
		truck_id = trucks.starter()

	_remove_truck(driver)

	var truck := DdTruck.new()
	truck.owner_key = key
	var made := truck.configure(truck_id, trucks.get_truck(truck_id), trucks.tunables_for(truck_id, bank.upgrades_of(key, truck_id)), draws)

	if not made.ok:
		truck.free()
		return made

	truck.name = "Truck_%s" % String(key)
	add_child(truck)
	driver.truck = truck

	var trip := DdTrip.new()
	var doc: Dictionary = documents[route_id]
	trip.route_id = route_id
	trip.truck_id = truck_id
	trip.level = int(doc["level"])
	trip.base_pay = float(doc["pay"])
	trip.truck_pay = float(trucks.get_truck(truck_id).get("pay", 1.0))
	trip.stages = (routes[route_id] as DdRoute).stages()
	trip.reset_to_start(config.start_hold_seconds)
	driver.trip = trip

	_put_at(driver, 0)
	_refresh_exceptions()

	if driver.autopilot != null:
		driver.autopilot.set_route(_global_points(route_id, 0.0))

	trip_started.emit(key, route_id)
	DotLog.info(CHANNEL, "a trip set off", {"driver": driver.name, "route": String(route_id), "truck": String(truck_id)})
	return DotResult.success(trip)


## Back to the garage: the truck goes.
func end_trip(key: StringName) -> void:
	var driver: Driver = drivers.get(key, null)

	if driver == null:
		return

	_remove_truck(driver)
	trip_ended.emit(key)


func restart(key: StringName) -> DotResult:
	var driver: Driver = drivers.get(key, null)

	if driver == null or not driver.on_road():
		return DotResult.fail(DotError.CODE_STATE, "You are not on a road.")

	if not config.allow_restart:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "This server does not allow restarting a trip.")

	var trip: DdTrip = driver.trip
	trip.reset_to_start(config.start_hold_seconds)
	_put_at(driver, 0)
	return DotResult.success(null)


## Skips to the next checkpoint, at the cost the configuration sets.
func skip(key: StringName) -> DotResult:
	var driver: Driver = drivers.get(key, null)

	if driver == null or not driver.on_road():
		return DotResult.fail(DotError.CODE_STATE, "You are not on a road.")

	if not config.allow_skip:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "This server does not allow skipping.")

	var trip: DdTrip = driver.trip

	if trip.stage >= trip.stages - 1:
		return DotResult.fail(DotError.CODE_STATE, "This is the last stage.")

	trip.stage += 1
	trip.skips += 1
	trip.state = DdTrip.State.DRIVING
	_put_at(driver, trip.stage)
	stage_reached.emit(key, trip.stage)
	return DotResult.success(trip.stage)


## Back to the last checkpoint by choice. Costs what a fall costs: otherwise a player about
## to go over would press it and lose nothing.
func respawn(key: StringName) -> DotResult:
	var driver: Driver = drivers.get(key, null)

	if driver == null or not driver.on_road():
		return DotResult.fail(DotError.CODE_STATE, "You are not on a road.")

	_fall(driver, "respawn")
	return DotResult.success(null)


func set_solo(key: StringName, on: bool) -> DotResult:
	var driver: Driver = drivers.get(key, null)

	if driver == null:
		return DotResult.fail(DotError.CODE_STATE, "Nobody by that key.")

	if on and not config.allow_solo:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "This server does not allow solo.")

	if driver.solo == on:
		return DotResult.success(on)

	driver.solo = on
	_refresh_exceptions()
	solo_changed.emit(key, on)
	return DotResult.success(on)


func set_command(key: StringName, command: DotVehicleCommand) -> void:
	var driver: Driver = drivers.get(key, null)

	if driver != null and command != null:
		driver.command = command


# --- The garage --------------------------------------------------------------

func buy_truck(key: StringName, truck_id: StringName) -> DotResult:
	var def := trucks.get_truck(truck_id)

	if def.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "No such truck.")

	return bank.buy_truck(key, truck_id, int(def.get("price", 0)))


func select_truck(key: StringName, truck_id: StringName) -> DotResult:
	return bank.select_truck(key, truck_id)


func buy_upgrade(key: StringName, truck_id: StringName, kind: String) -> DotResult:
	var level := bank.upgrade_level(key, truck_id, kind)
	return bank.buy_upgrade(key, truck_id, kind, trucks.upgrade_cost(truck_id, kind, level))


## What the garage draws for [param key]: their money, every route with whether it is open
## to them, every truck with whether they own it, and the upgrades on the truck they drive.
## The server sends exactly this; offline the client asks for it directly.
func garage_view(key: StringName) -> Dictionary:
	var acct := bank.account(key)
	var out_routes: Array = []

	for id in route_order:
		var doc: Dictionary = documents[id]
		var road: DdRoute = routes[id]
		out_routes.append({
			"id": String(id), "name": doc["name"], "level": int(doc["level"]), "blurb": doc["blurb"],
			"length": int(road.length()), "stages": road.stages(),
			"pay": int(round(float(doc["pay"]) * (1.0 + config.level_pay_step * float(int(doc["level"]) - 1)))),
			"locked": not is_unlocked(key, id), "delivered": bank.has_delivered(key, id),
		})

	var out_trucks: Array = []

	for id in trucks.order:
		var def := trucks.get_truck(id)
		out_trucks.append({
			"id": String(id), "name": def.get("name", id), "blurb": def.get("blurb", ""),
			"price": int(def.get("price", 0)), "pay": float(def.get("pay", 1.0)),
			"owned": bank.owns(key, id), "selected": str(acct["truck"]) == String(id),
		})

	var out_upgrades: Array = []
	var current := StringName(str(acct["truck"]))

	for kind: String in DdTrucks.UPGRADES:
		var level := bank.upgrade_level(key, current, kind)
		out_upgrades.append({
			"kind": kind, "name": DdTrucks.UPGRADES[kind]["name"], "level": level,
			"levels": int(DdTrucks.UPGRADES[kind]["levels"]), "cost": trucks.upgrade_cost(current, kind, level),
		})

	return {"money": int(acct["money"]), "routes": out_routes, "trucks": out_trucks, "upgrades": out_upgrades}


# --- The tick ----------------------------------------------------------------

func _physics_process(delta: float) -> void:
	step(delta)


## One tick of the world. The server's module calls it; offline, the physics frame does.
func step(delta: float) -> void:
	tick += 1
	_now += delta
	_refresh_weather(false)

	if not authoritative:
		return

	for key: StringName in drivers:
		var driver: Driver = drivers[key]

		if driver.is_bot:
			_drive_bot(driver, delta)

		if driver.on_road():
			_step_driver(driver, delta)

	_step_boulders(delta)


func _step_driver(driver: Driver, delta: float) -> void:
	var trip: DdTrip = driver.trip
	var truck: DdTruck = driver.truck
	var road: DdRoute = routes[trip.route_id]
	var local := truck.global_position - road.position

	# A ghost becomes solid only once it is clear of every other truck. A fixed time was the
	# first version, and two stand-ins put on the same start line stopped being ghosts while
	# they were still inside each other and jammed there (dedicated: 2 m in 4 s at full throttle).
	if driver.ghost_until > 0.0 and _now >= driver.ghost_until and _clear_of_others(driver):
		driver.ghost_until = 0.0
		_refresh_exceptions()

	match trip.state:
		DdTrip.State.HOLD:
			trip.wait -= delta
			truck.drive(_held(), delta)

			if trip.wait <= 0.0:
				trip.state = DdTrip.State.DRIVING

			return
		DdTrip.State.FALLEN:
			trip.wait -= delta

			if trip.wait <= 0.0:
				trip.state = DdTrip.State.DRIVING
				_put_at(driver, trip.stage)
				put_back.emit(driver.key)

			return
		DdTrip.State.DELIVERED:
			truck.drive(_held(), delta)
			return

	trip.seconds += delta
	truck.drive(driver.command, delta)

	trip.hint = road.nearest_index(local, trip.hint)
	trip.distance = road.distance_at(local, trip.hint)
	trip.furthest = maxf(trip.furthest, trip.distance)

	# Weather: grip, wind, and the chaos it is paid for.
	var zone := road.zone_at(trip.distance)
	var sky := _sky(trip.route_id, zone)
	truck.set_grip(DdWeather.grip(sky, config.snow_grip, config.rain_grip))

	if bool(sky.get("wind", false)) and config.wind_strength > 0.0:
		var side := DdRoute.right_of(road.yaws[trip.hint])
		truck.push(side, config.wind_strength * DdWeather.gust(seed_value, "%s|%s" % [trip.route_id, zone], tick, tick_rate))

	if zone != "":
		var _fresh := trip.meet(zone, sky, config.snow_chaos, config.rain_chaos, config.wind_chaos)

	# A knock: the cargo feels a change of speed the road did not ask for.
	var dv := (truck.linear_velocity - trip.last_velocity).length()
	trip.last_velocity = truck.linear_velocity

	if dv > config.knock_threshold:
		trip.cargo = maxf(trip.cargo - (dv - config.knock_threshold) * config.knock_loss_per_speed, 0.0)

	# Checkpoints.
	var reached := road.stage_of(trip.distance)

	if reached > trip.stage and trip.distance <= trip.furthest + 1.0:
		trip.stage = reached
		stage_reached.emit(driver.key, reached)

	# Off the mountain.
	if truck.global_position.y < road.position.y + road.road_height_at(local, trip.hint) - config.fall_depth:
		_fall(driver, "fell")
		return

	# On its back.
	if truck.is_flipped() and truck.linear_velocity.length() < 2.0:
		trip.flipped_for += delta

		if trip.flipped_for >= config.flipped_respawn_seconds:
			_fall(driver, "flipped")
			return
	else:
		trip.flipped_for = 0.0

	# The depot.
	if trip.distance >= road.length() - 2.0:
		_deliver(driver)


func _held() -> DotVehicleCommand:
	var held := DotVehicleCommand.new()
	held.brake = 1.0
	held.handbrake = true
	return held


func _fall(driver: Driver, why: String) -> void:
	var trip: DdTrip = driver.trip
	trip.falls += 1
	trip.cargo = maxf(trip.cargo - config.fall_cargo_loss, 0.0)
	trip.state = DdTrip.State.FALLEN
	trip.wait = config.respawn_seconds
	trip.flipped_for = 0.0
	fell.emit(driver.key, why)


func _deliver(driver: Driver) -> void:
	var trip: DdTrip = driver.trip
	trip.state = DdTrip.State.DELIVERED
	trip.paid = trip.pay_now(config)
	var road: DdRoute = routes[trip.route_id]
	bank.note_delivery(driver.key, trip.route_id, trip.paid, road.length(), trip.falls)
	delivered.emit(driver.key, trip.route_id, trip.paid)
	DotLog.info(CHANNEL, "a delivery", {
		"driver": driver.name, "route": String(trip.route_id), "paid": trip.paid,
		"cargo": "%.0f%%" % (trip.cargo * 100.0), "falls": trip.falls, "seconds": "%.0f" % trip.seconds})


## Puts a driver's truck on the checkpoint for [param stage] (0: the start), stopped, and
## lets it pass through other trucks for [constant GHOST_SECONDS].
func _put_at(driver: Driver, stage: int) -> void:
	var trip: DdTrip = driver.trip
	var road: DdRoute = routes[trip.route_id]
	var d := road.checkpoint_distance(stage)
	var at := road.transform_at(d, 0.6)
	at.origin += road.position
	(driver.truck as DdTruck).place(at)
	trip.distance = d
	trip.furthest = maxf(trip.furthest, d)
	trip.hint = road.index_at_distance(d)
	trip.last_velocity = Vector3.ZERO
	driver.ghost_until = _now + GHOST_SECONDS
	_refresh_exceptions()

	if driver.autopilot != null:
		driver.autopilot.set_route(_global_points(trip.route_id, d))


func _remove_truck(driver: Driver) -> void:
	if driver.truck != null and is_instance_valid(driver.truck):
		remove_child(driver.truck)
		driver.truck.queue_free()

	driver.truck = null
	driver.trip = null
	_refresh_exceptions()


## Which trucks pass through which: none for a solo truck, none while one is a ghost, and
## none at all when the server turned truck collisions off.
func _refresh_exceptions() -> void:
	var on_road: Array[Driver] = []

	for key: StringName in drivers:
		var driver: Driver = drivers[key]

		if driver.truck != null and is_instance_valid(driver.truck):
			on_road.append(driver)

	for i in on_road.size():
		for j in range(i + 1, on_road.size()):
			var a := on_road[i]
			var b := on_road[j]
			var collide := may_collide(a, b)
			var ta := a.truck as PhysicsBody3D
			var tb := b.truck as PhysicsBody3D

			if collide:
				ta.remove_collision_exception_with(tb)
				tb.remove_collision_exception_with(ta)
			else:
				ta.add_collision_exception_with(tb)
				tb.add_collision_exception_with(ta)


func _clear_of_others(driver: Driver) -> bool:
	var truck := driver.truck as DdTruck

	for key: StringName in drivers:
		var other: Driver = drivers[key]

		if other == driver or other.truck == null or not is_instance_valid(other.truck):
			continue

		var reach := truck.half_length + (other.truck as DdTruck).half_length + 1.0

		if truck.global_position.distance_to((other.truck as Node3D).global_position) < reach:
			return false

	return true


func may_collide(a: Driver, b: Driver) -> bool:
	return config.trucks_collide and not a.solo and not b.solo and a.ghost_until <= 0.0 and b.ghost_until <= 0.0


## Whether [param viewer] sees [param other]'s truck at all.
func sees(viewer: Driver, other: Driver) -> bool:
	if viewer == null or other == null or viewer == other:
		return true

	if viewer.solo:
		return false

	return not (other.solo and config.solo_hidden_from_others)


func _global_points(route_id: StringName, from_d: float) -> PackedVector3Array:
	var road: DdRoute = routes[route_id]
	var local := road.route_points(from_d, 8.0)
	var out := PackedVector3Array()

	for p in local:
		out.append(p + road.position)

	return out


# --- Stand-ins ---------------------------------------------------------------

func _drive_bot(driver: Driver, delta: float) -> void:
	if not driver.on_road():
		driver.idle -= delta

		if driver.idle <= 0.0 and not route_order.is_empty():
			var choices: Array[StringName] = []

			for id in route_order:
				if is_unlocked(driver.key, id):
					choices.append(id)

			var pick := choices[(tick / 7 + driver.key.hash()) % choices.size()] if not choices.is_empty() else route_order[0]
			var _started := start_trip(driver.key, pick)

		return

	var trip: DdTrip = driver.trip

	if trip.state == DdTrip.State.DELIVERED:
		driver.idle -= delta

		if driver.idle <= -4.0:
			end_trip(driver.key)
			driver.idle = 1.0

		return

	if trip.state != DdTrip.State.DRIVING or driver.autopilot == null:
		return

	var instance := (driver.truck as DdTruck).instance
	driver.command = driver.autopilot.drive(instance, delta)


# --- Weather -----------------------------------------------------------------

func _refresh_weather(force: bool) -> void:
	# Once a second is plenty: the weather holds for minutes.
	if not force and tick % maxi(tick_rate, 1) != 0:
		return

	for id: StringName in routes:
		var zones: Dictionary = documents[id].get("zones", {})

		# Forced weather paints the stretches no zone names as well.
		if force:
			var forced_sky := int(forced_weather.get("sky", DdWeather.CLEAR))
			(routes[id] as DdRoute).paint_zone("", forced_sky == DdWeather.SNOW, forced_sky == DdWeather.RAIN)

		for zone: String in zones:
			var key := "%s|%s" % [id, zone]
			var now := forced_weather.duplicate() if not forced_weather.is_empty() \
				else DdWeather.at(seed_value, key, zones[zone], tick, tick_rate, config.weather_frequency)
			var was: Dictionary = weather.get(key, {})

			if was != now:
				weather[key] = now
				(routes[id] as DdRoute).paint_zone(zone, int(now["sky"]) == DdWeather.SNOW, int(now["sky"]) == DdWeather.RAIN)
				weather_changed.emit(id, zone, now)


## Every zone to [param sky] ("clear", "rain", "snow") with or without wind; "" hands the sky
## back to the draw.
func force_weather(sky: String, wind: bool = false) -> DotResult:
	if sky == "":
		forced_weather = {}
	else:
		var index := ["clear", "rain", "snow"].find(sky)

		if index < 0:
			return DotResult.fail(DotError.CODE_INVALID, "The sky is clear, rain or snow.")

		forced_weather = {"sky": index, "wind": wind}

	_refresh_weather(true)
	return DotResult.success(forced_weather)


func weather_at(route_id: StringName, d: float) -> Dictionary:
	var road: DdRoute = routes.get(route_id, null)

	if road == null:
		return {"sky": DdWeather.CLEAR, "wind": false}

	return _sky(route_id, road.zone_at(d))


## The sky over one zone. Forced weather covers the stretches no zone names, too: an operator
## who makes it snow means everywhere.
func _sky(route_id: StringName, zone: String) -> Dictionary:
	if not forced_weather.is_empty():
		return forced_weather

	return weather.get("%s|%s" % [route_id, zone], {"sky": DdWeather.CLEAR, "wind": false})


# --- Falling rock ------------------------------------------------------------

func _step_boulders(delta: float) -> void:
	for key: String in _site_cooldown.keys():
		_site_cooldown[key] = float(_site_cooldown[key]) - delta

		if float(_site_cooldown[key]) <= 0.0:
			_site_cooldown.erase(key)

	if config.boulders_enabled:
		for k: StringName in drivers:
			var driver: Driver = drivers[k]

			if not driver.on_road() or not (driver.trip as DdTrip).is_driving():
				continue

			var trip: DdTrip = driver.trip
			var road: DdRoute = routes[trip.route_id]

			for i in road.boulder_sites.size():
				var site: Dictionary = road.boulder_sites[i]
				var ahead := float(site["d"]) - trip.distance

				if ahead < config.boulder_trigger_distance - 12.0 or ahead > config.boulder_trigger_distance:
					continue

				var site_key := "%s|%d" % [trip.route_id, i]

				if _site_cooldown.has(site_key):
					continue

				_site_cooldown[site_key] = config.boulder_cooldown_seconds
				var n := int(_site_falls.get(site_key, 0))
				_site_falls[site_key] = n + 1

				if DdWeather.unit("%d|%s|%d" % [seed_value, site_key, n]) >= config.boulder_chance:
					continue

				_drop_boulder(trip.route_id, road, site, ahead / maxf(truck_speed(driver), 4.0))

	for body: RigidBody3D in boulders.keys():
		var entry: Dictionary = boulders[body]

		if not is_instance_valid(body):
			boulders.erase(body)
			continue

		if _now - float(entry["born"]) > 14.0 or body.global_position.y < float(entry["floor"]):
			boulders.erase(body)
			boulder_gone.emit(body)
			body.queue_free()


func truck_speed(driver: Driver) -> float:
	return (driver.truck as DdTruck).linear_velocity.length() if driver.truck != null else 0.0


## A rock off the cliff at a site, thrown across the road so it arrives about when the truck
## that set it off does. Every trip near it counts it as chaos.
func _drop_boulder(route_id: StringName, road: DdRoute, site: Dictionary, lead_seconds: float) -> void:
	var d := float(site["d"])
	var side := float(site["side"])
	var i := road.index_at_distance(d)
	var across := DdRoute.right_of(road.yaws[i]) * -side
	var width := road.width_at(d)
	# Over the top of the cliff where there is one: the first version started rock 9 m up and
	# 3 m behind a 16 m face, and the cliff caught every boulder it was meant to drop.
	var wall := str(road.segment_at(d)["wall"])
	var cliff := wall == "both" or (wall == "left" and side < 0.0) or (wall == "right" and side > 0.0)
	var up := DdRoute.WALL_HEIGHT + config.boulder_radius + 1.0 if cliff else 7.0
	var at := road.points[i] + road.position - across * (width * 0.5 + 2.0) + Vector3(0.0, up, 0.0)

	var body := RigidBody3D.new()
	body.name = "Boulder"
	body.mass = config.boulder_mass
	body.continuous_cd = true
	var shape := SphereShape3D.new()
	shape.radius = config.boulder_radius
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)

	if draws:
		var mesh := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = config.boulder_radius
		sphere.height = config.boulder_radius * 2.0
		sphere.radial_segments = 10
		sphere.rings = 6
		mesh.mesh = sphere
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.45, 0.4, 0.36)
		mesh.material_override = material
		body.add_child(mesh)

	add_child(body)
	body.global_position = at
	# Across, with enough time in the air that it lands on the road near when the truck does.
	body.linear_velocity = across * config.boulder_speed * clampf(2.5 / maxf(lead_seconds, 0.5), 0.6, 1.4)
	boulders[body] = {"route": route_id, "born": _now, "floor": road.position.y + road.lowest_point() - 80.0}
	boulder_made.emit(body)

	for k: StringName in drivers:
		var driver: Driver = drivers[k]

		if driver.on_road() and (driver.trip as DdTrip).route_id == route_id \
				and absf((driver.trip as DdTrip).distance - d) < 90.0:
			var trip: DdTrip = driver.trip
			trip.boulders += 1

			# Once per stretch of cliff per trip: a driver who kept falling back past the same
			# site would otherwise be paid more for every fall.
			if not trip.met.has("rock|%d" % int(site.get("index", 0))):
				trip.met["rock|%d" % int(site.get("index", 0))] = true
				trip.chaos_units += config.boulder_chaos

	boulder_dropped.emit(route_id, at)


# --- Reports -----------------------------------------------------------------

func describe() -> Dictionary:
	var on_road := 0

	for k: StringName in drivers:
		if (drivers[k] as Driver).on_road():
			on_road += 1

	return {
		"routes": route_order.size(), "drivers": drivers.size(), "on_road": on_road,
		"boulders": boulders.size(), "tick": tick, "seed": seed_value,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["dangerous delivery: %s" % describe()])

	for id in route_order:
		lines.append("  route %s" % (routes[id] as DdRoute).describe())

	for k: StringName in drivers:
		var driver: Driver = drivers[k]
		var where := (driver.trip as DdTrip).describe() if driver.trip != null else {"in": "garage"}
		lines.append("  %-16s %s%s %s" % [driver.name, "bot " if driver.is_bot else "", "solo " if driver.solo else "", where])

	return lines
