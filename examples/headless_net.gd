extends Node

## A server and a client in one process, over the link's loopback, each in its own physics
## world as two processes would be.
##
##   godot --headless --path . res://examples/headless_net.tscn

const DdGame := preload("res://game/dd_game.gd")
const DdNetBridge := preload("res://game/net/dd_net_bridge.gd")
const DdTruck := preload("res://game/dd_truck.gd")
const DdTrip := preload("res://game/dd_trip.gd")
const DdWeather := preload("res://game/dd_weather.gd")

const SECTIONS := 9
const CHECKS := 30

const CLIENT_PEER := 7
const SESSION := 42

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _finished := 0

var _server_game: DdGame = null
var _client_game: DdGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: DdNetBridge = null
var _client_bridge: DdNetBridge = null
var _to_client: Array = []
var _to_server: Array = []
var _tick := 0
var _heard: Dictionary = {}
var _key: StringName = &""


func _ready() -> void:
	print("dangerous delivery, over the wire")

	if await _build():
		await _test_joining()
		await _test_a_trip()
		await _test_driving()
		await _test_weather()
		await _test_solo()
		await _test_refusal()
		await _test_bots()
		await _test_rock()

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


func _make_game(authoritative: bool, parent: Node) -> DdGame:
	var world := DdGame.new()
	world.name = "World"
	world.authoritative = authoritative
	world.draws = false
	world.register_service = false
	world.self_tick = false
	world.config.start_hold_seconds = 0.2
	world.config.seed_value = 4242
	parent.add_child(world)
	return world


func _make_manager(is_server: bool, parent: Node) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Net"
	manager.is_server = is_server
	manager.local_peer_id = 1 if is_server else CLIENT_PEER
	manager.auto_tick = false
	manager.config_file = ""
	var config := DotNetConfig.new()
	config.tick_rate = 60
	config.snapshot_rate = DdGame.NET_SNAPSHOT_RATE
	config.world_extent = DdGame.NET_WORLD_EXTENT
	config.enable_prediction = false
	config.enable_lag_compensation = false
	manager.config = config
	parent.add_child(manager)
	var _s := manager.setup()
	return manager


func _build() -> bool:
	_section("both halves")
	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)
	var client_view := SubViewport.new()
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)
	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)

	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)
	await get_tree().process_frame
	_check(_server_game.routes.size() == 5 and _client_game.routes.is_empty(), "the server reads its routes; the client reads none")

	_server_net = _make_manager(true, server_side)
	_client_net = _make_manager(false, client_side)
	_server_bridge = DdNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)
	_client_bridge = DdNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)
	var a := _server_bridge.attach(_server_game, _server_net)
	var b := _client_bridge.attach(_client_game, _client_net)
	_check(a.ok and b.ok, "both bridges attach")
	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(_server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both ends agree on the schema")
	_server_bridge.link.loopback = func(method: StringName, _peer: int, payload: PackedByteArray) -> void:
		_to_client.append({"method": method, "payload": payload})
	_client_bridge.link.loopback = func(method: StringName, _peer: int, payload: PackedByteArray) -> void:
		_to_server.append({"method": method, "payload": payload})
	_client_bridge.rtt_source = func() -> float: return 40.0
	var _s := _server_net.start()
	var _c := _client_net.start()
	_client_bridge.said.connect(func(text: String, _tone: String) -> void: _heard["said"] = text)
	_finished_section()
	return _failed == 0


func _test_joining() -> void:
	_section("a client joins")
	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(seated.ok, "the server seats them")
	_key = seated.value
	_client_bridge.ask_ready()
	_exchange()
	await _steps(4)
	_check(_client_bridge.local_key == _key, "the client is told who it is", String(_client_bridge.local_key))
	_check(_client_game.routes.size() == 5 and absf(_client_game.routes[&"dd_snowline"].length() - _server_game.routes[&"dd_snowline"].length()) < 0.001,
		"it builds every route from the documents it was sent, to the centimetre")
	_check(_client_game.seed_value == _server_game.seed_value, "it has the weather's seed")
	_check((_client_bridge.garage_view.get("routes", []) as Array).size() == 5 and int(_client_bridge.garage_view.get("money", -1)) == 0,
		"and its garage")
	_finished_section()


func _test_a_trip() -> void:
	_section("setting off")
	_client_bridge.ask_act("start", {"route": "dd_foothills"})
	_exchange()
	await _steps(6)
	var server_driver: DdGame.Driver = _server_game.drivers[_key]
	_check(server_driver.on_road(), "the server starts the trip")
	var mirror: DdGame.Driver = _client_game.drivers.get(_key, null)
	_check(mirror != null and mirror.truck != null and (mirror.truck as RigidBody3D).freeze, "the client mirrors the truck, frozen")
	_check(bool(_client_bridge.trip_view.get("on_road", false)) and str(_client_bridge.trip_view.get("route", "")) == "dd_foothills",
		"and is told its trip")
	_finished_section()


func _test_driving() -> void:
	_section("driving over the wire")
	var server_truck := _server_game.drivers[_key].truck as DdTruck
	var start := server_truck.global_position
	var go := DotVehicleCommand.new()
	go.throttle = 1.0
	await _steps(240, go)
	var moved := server_truck.global_position.distance_to(start)
	_check(moved > 6.0, "the client's throttle drives the server's truck", "%.1f m" % moved)
	var mirror := _client_game.drivers[_key].truck as DdTruck
	_client_net.interpolate_frame(1.0)
	var gap := mirror.global_position.distance_to(server_truck.global_position)
	_check(gap < 3.0, "and the client's copy is where the server's is", "%.2f m apart" % gap)
	_check(float(_client_bridge.trip_view.get("distance", 0.0)) > 5.0, "the trip's distance reaches the client")
	var behaviour := mirror.get_node("Net")
	_check(behaviour != null and behaviour.call("speed_ms") > 1.0, "and so does its speed", "%.1f" % behaviour.call("speed_ms"))
	_finished_section()


func _test_weather() -> void:
	_section("the same sky on both ends")
	var same := true

	for key: String in _server_game.weather:
		if _client_game.weather.get(key, {}) != _server_game.weather[key]:
			same = false

	_check(same and not _server_game.weather.is_empty(), "every zone's weather agrees, from the seed alone", "%d zones" % _server_game.weather.size())
	var _f := _server_game.force_weather("snow")
	_server_bridge.broadcast_weather()
	_exchange()
	await _steps(2)
	_check(int(_client_game.weather_at(&"dd_foothills", 50.0)["sky"]) == DdWeather.SNOW, "an operator's snow reaches the client")
	var _off := _server_game.force_weather("")
	_server_bridge.broadcast_weather()
	_exchange()
	_finished_section()


func _test_solo() -> void:
	_section("solo")
	_client_bridge.ask_act("solo")
	_exchange()
	await _steps(2)
	_check((_server_game.drivers[_key] as DdGame.Driver).solo, "B turns solo on at the server")
	_check((_client_game.drivers[_key] as DdGame.Driver).solo, "and the client knows")
	_check(bool(_client_bridge.trip_view.get("solo", false)), "and its HUD is told")
	_client_bridge.ask_act("solo")
	_exchange()
	await _steps(2)
	_check(not (_client_game.drivers[_key] as DdGame.Driver).solo, "and off again")
	_finished_section()


func _test_refusal() -> void:
	_section("what the server refuses")
	_heard.erase("said")
	_client_bridge.ask_act("buy_truck", {"truck": "bulk"})
	_exchange()
	await _steps(2)
	_check(str(_heard.get("said", "")).contains("costs"), "a truck it cannot afford, in words", str(_heard.get("said", "")))
	_check(not _server_game.bank.owns(_key, &"bulk"), "and nothing changes")
	_client_bridge.ask_act("teleport")
	_exchange()
	await _steps(2)
	_check(str(_heard.get("said", "")).contains("Nothing called"), "an action that does not exist")
	_finished_section()


func _test_bots() -> void:
	_section("stand-ins")
	var bot := _server_bridge.add_bot("Hauler 1")
	(_server_game.drivers[bot] as DdGame.Driver).idle = 0.0
	await _steps(30)
	_exchange()
	await _steps(4)
	var mirror: DdGame.Driver = _client_game.drivers.get(bot, null)
	_check(mirror != null and mirror.is_bot, "a client sees a stand-in arrive")
	_check(mirror != null and mirror.truck != null, "and its truck")
	_server_bridge.remove_bot(bot)
	_exchange()
	await _steps(2)
	_check(not _client_game.drivers.has(bot), "and sees it go")
	_check(_client_bridge.entity_count() == 1, "taking its truck with it", "%d entities" % _client_bridge.entity_count())
	_finished_section()


func _test_rock() -> void:
	_section("rock")
	var road = _server_game.routes[&"dd_foothills"]
	_server_game._drop_boulder(&"dd_foothills", road, road.boulder_sites[0], 2.0)
	_exchange()
	await _steps(4)
	_check(_client_bridge.entity_count() == 2, "a boulder reaches the client", "%d" % _client_bridge.entity_count())
	var body: RigidBody3D = _server_game.boulders.keys()[0]
	_server_game.boulders[body]["born"] = -100.0
	await _steps(3)
	_exchange()
	await _steps(2)
	_check(_client_bridge.entity_count() == 1, "and goes when it goes")
	_finished_section()


# --- Harness -----------------------------------------------------------------

func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


func _exchange() -> void:
	_flush()
	_flush()


func _step(command: DotVehicleCommand = null) -> void:
	_tick += 1
	var _t := _client_net.clock.advance(1.0 / 60.0)
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick, command if command != null else DotVehicleCommand.new())
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotVehicleCommand = null) -> void:
	for _i in count:
		await _step(command)


func _section(name: String) -> void:
	_entered += 1
	print("")
	print(name)


func _finished_section() -> void:
	_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	else:
		_failed += 1
		var line := what if detail == "" else "%s  (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)
