extends Node

## The game as a deployed server runs it: a real [DotServer], the world from the server scene,
## the module loaded BY PATH the way an operator names it.
##
##   godot --headless --path . res://examples/dedicated.tscn

const DdGame := preload("../game/dd_game.gd")

const SECTIONS := 6
const CHECKS := 19

const SERVER_DIR := "user://dd_dedicated"
const PORT := 28941
const QUERY_PORT := 28942
const TICK_RATE := 60

var _passed := 0
var _failed := 0
var _entered := 0
var _finished := 0
var _failures := PackedStringArray()

var server: DotServer = null
var scene: Node = null
var game: DdGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dangerous delivery as a dedicated server")
	DotPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	await _boot()

	if server != null and server.state == DotServer.State.RUNNING:
		await _test_the_module_loads()
		_test_the_console()
		await _test_stand_ins()
		await _test_it_unloads()

	_test_no_message_preloads_itself()

	print("")
	print("%d sections entered, %d finished" % [_entered, _finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _entered != SECTIONS or _finished != SECTIONS:
		print("ERROR: %d of %d sections finished, %d declared." % [_finished, _entered, SECTIONS])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d declared. A section aborted part-way." % [_passed + _failed, CHECKS])
		code = 1

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)
	get_tree().quit(code)


## A booted server's listener holds the main loop: take it down before quitting, or the run
## prints its results and hangs.
func _shut_down() -> void:
	if server == null:
		return

	if server.modules != null:
		server.modules.unload_all()

	server.shutdown("the dedicated test is finished")

	for _i in range(10):
		await get_tree().process_frame

	if is_instance_valid(scene):
		remove_child(scene)
		scene.free()

	if is_instance_valid(server):
		remove_child(server)
		server.free()

	await get_tree().process_frame


func _boot() -> void:
	_section("booting")
	var cfg_path := "%s/server.cfg" % SERVER_DIR
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)
	cfg.store_line("sv_tickrate %d" % TICK_RATE)
	cfg.close()

	var config := DotServerConfig.new()
	config.startup_config = cfg_path
	config.autoexec_config = ""
	config.hostname = "dangerous delivery test"
	config.max_players = 16
	config.hibernate_when_empty = false
	config.rcon_password = ""
	config.port = PORT
	config.query_port = QUERY_PORT
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.stdin_console_enabled = false

	server = DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)

	for _i in range(120):
		await get_tree().process_frame

		if server.state == DotServer.State.RUNNING:
			break

	_check(server.state == DotServer.State.RUNNING, "the server boots", DotServer.State.keys()[server.state])
	_check(Engine.physics_ticks_per_second == TICK_RATE, "and sv_tickrate reached the engine")
	_finished_section()


func _test_the_module_loads() -> void:
	_section("the module")
	scene = (load("res://scenes/dd_server.tscn") as PackedScene).instantiate()
	add_child(scene)
	await get_tree().process_frame
	game = DotRegistry.get_node_service(DdGame.SERVICE) as DdGame
	_check(game != null and game.routes.size() == 5, "the server scene builds the mountain and publishes it")
	_check(game != null and not game.draws, "and draws nothing")

	var script := load("res://game/dd_module.gd") as GDScript
	script.set("bank_file", "%s/accounts.json" % SERVER_DIR)
	var loaded: DotResult = await server.modules.load_module("res://game/dd_module.gd")
	_check(loaded.ok, "the module loads into the server", loaded.error.message if not loaded.ok else "")
	var module := _module()
	_check(module != null and module.get("net") != null and module.get("bridge") != null, "with its netcode and bridge")
	var net: DotNetManager = module.get("net") if module != null else null
	_check(net != null and absf(net.config.world_extent - DdGame.NET_WORLD_EXTENT) < 0.01 and not net.config.enable_prediction,
		"against the world extent a client decodes with, and predicting nothing")
	_finished_section()


func _test_the_console() -> void:
	_section("the console")
	_check(_said(_run_command("dd_status"), "dd_snowline"), "dd_status lists the routes")
	var _snow := _run_command("dd_weather snow")
	_check(int(game.weather_at(&"dd_foothills", 10.0)["sky"]) == 2, "dd_weather snow makes it snow everywhere")
	var _off := _run_command("dd_weather off")
	_check(game.forced_weather.is_empty(), "and off hands the sky back")
	var _rocks := _run_command("dd_rocks 0")
	_check(not game.config.boulders_enabled, "a cvar turns rock off")
	var _back := _run_command("dd_rocks 1")
	_finished_section()


func _test_stand_ins() -> void:
	_section("stand-ins")
	var _b := _run_command("dd_bots 2")
	var until := Time.get_ticks_msec() + 6000
	var on_road := 0

	while Time.get_ticks_msec() < until:
		await get_tree().physics_frame
		on_road = 0

		for key: StringName in game.drivers:
			if (game.drivers[key] as DdGame.Driver).on_road():
				on_road += 1

		if on_road == 2:
			break

	_check(game.drivers.size() == 2, "dd_bots seats two stand-ins", "%d" % game.drivers.size())
	_check(on_road == 2, "and both set off", "%d" % on_road)
	var module := _module()
	_check(module.get("bridge").call("entity_count") == 2, "each truck is replicated")
	var key: StringName = game.drivers.keys()[0]
	var truck := (game.drivers[key] as DdGame.Driver).truck as Node3D
	var start := truck.global_position
	await _seconds(7.0)
	var driver: DdGame.Driver = game.drivers[key]
	_check(truck.global_position.distance_to(start) > 5.0, "and a stand-in drives",
		"%.1f m, %s, throttle %.2f" % [truck.global_position.distance_to(start), (driver.trip as RefCounted).call("describe"), driver.command.throttle])
	var _none := _run_command("dd_bots 0")
	await _seconds(2.5)
	_check(game.drivers.is_empty(), "dd_bots 0 takes them away")
	_finished_section()


func _test_it_unloads() -> void:
	_section("unloading")
	server.modules.unload_all()
	await get_tree().process_frame
	_check(_module() == null, "the module unloads")
	_check(is_instance_valid(game), "and leaves the world, which outlives it")
	_finished_section()


## A message script that preloads itself leaks the whole script graph at exit
## (mg-buses-from-hell's 8ed866c), after quit(), where no assertion reaches: checked on the source.
func _test_no_message_preloads_itself() -> void:
	_section("exiting clean")
	var offenders := PackedStringArray()

	for file in DirAccess.open("res://game/net").get_files():
		if file.ends_with(".gd"):
			var source := FileAccess.get_file_as_string("res://game/net/" + file)

			if source.contains("extends DotNetMessage") and source.contains("preload(\"%s\")" % file):
				offenders.append(file)

	_check(offenders.is_empty(), "no message preloads itself", ", ".join(offenders))
	_finished_section()


# --- Harness -----------------------------------------------------------------

func _module() -> DotModule:
	return server.modules.get_module("delivery") if server != null and server.modules != null else null


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, context)
	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.findn(text) >= 0:
			return true

	return false


func _seconds(s: float) -> void:
	var until := Time.get_ticks_msec() + int(s * 1000.0)

	while Time.get_ticks_msec() < until:
		await get_tree().physics_frame


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
