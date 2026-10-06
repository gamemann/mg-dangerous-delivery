extends DotGameModule

## This game, as a module a dedicated server loads. Over dot-game, like mg-deathrun's.
##
## What is this game's: the netcode's numbers, the cvars, the console commands, stand-ins that
## keep a mountain from being empty, where the money is kept, and the key it is kept under.
##
## [b]No `class_name`[/b]: a module delivered inside a dot-cloud pack cannot have one.

const DdNetBridge := preload("net/dd_net_bridge.gd")
const DdServices := preload("dd_services.gd")
const DdGame := preload("dd_game.gd")
const DdBank := preload("dd_bank.gd")

## Seconds between checks of how many stand-ins there should be.
const ROSTER_INTERVAL := 2.0

## A SQL driver for the bank (dot-moderation's shape), set by a host before the module loads.
## Null keeps the money in [member bank_file]. Static for mg-deathrun's reason: dot-server
## constructs the module from a path, so there is no instance to set a field on first.
static var bank_driver: Object = null

## Where the money is kept without a database.
static var bank_file: String = "user://delivery_accounts.json"

var _bots: DotConVar = null
var _bot_keys: Array[StringName] = []
var _since_roster := 0.0


func _module_name() -> String:
	return "delivery"


func _game_service() -> StringName:
	return DdGame.SERVICE


func _game_missing_hint() -> String:
	return "load scenes/dd_server.tscn as the game scene: it builds the world this module drives"


func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = (game as DdGame).tick_rate
	config.snapshot_rate = DdGame.NET_SNAPSHOT_RATE
	config.world_extent = DdGame.NET_WORLD_EXTENT
	# Nothing is predicted: a truck is a rigid body (dot-vehicle's decision).
	config.enable_prediction = false
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 96
	return config


func _make_bridge() -> Node:
	var bridge_node := DdNetBridge.new()
	# Money is kept under the account, so it survives a reconnect; a guest's account is their
	# device. The session would be a fresh wallet every time somebody pressed reconnect.
	bridge_node.key_fn = func(_peer_id: int, session_id: int) -> StringName:
		var session := server.session_by_userid(session_id) if server != null else null
		var uid := session.uid() if session != null else ""
		return StringName("uid:%s" % uid) if uid != "" else &""
	return bridge_node


func _make_services() -> Node:
	return DdServices.new()


## No platform identity layer yet: names come from the session. See CLAUDE.md.
func _make_identity() -> Node:
	return null


func _game_load() -> DotResult:
	var world := game as DdGame

	if world == null:
		return DotResult.fail(DotError.CODE_STATE, "The registered game is not a DdGame.")

	world.bank.store = DdBank.SqlStore.new(bank_driver) if bank_driver != null else DdBank.JsonStore.new(bank_file)

	add_command("dd_status", _cmd_status, "Show the routes and who is driving where")
	add_command("dd_bank", _cmd_bank, "Show the accounts this server has loaded")
	add_command("dd_weather", _cmd_weather, "Force the sky everywhere: clear, rain, snow, wind, or off", DotAdminFlags.CHANGEMAP)
	add_command("dd_give", _cmd_give, "Give money: dd_give <name> <amount>", DotAdminFlags.ROOT)

	_bots = add_cvar("dd_bots", str(world.config.bots), "Stand-in drivers on the mountain. People take their places.")
	_tunable_bool("dd_solo", world.config.allow_solo, "Whether players may drive solo (B)", func(v: bool) -> void: world.config.allow_solo = v)
	_tunable_bool("dd_skip", world.config.allow_skip, "Whether players may skip a stage (N)", func(v: bool) -> void: world.config.allow_skip = v)
	_tunable_bool("dd_rocks", world.config.boulders_enabled, "Whether rock falls", func(v: bool) -> void: world.config.boulders_enabled = v)
	_tunable_bool("dd_collide", world.config.trucks_collide, "Whether trucks hit each other", func(v: bool) -> void:
		world.config.trucks_collide = v
		world._refresh_exceptions())

	if bridge != null:
		bridge.connect("say_requested", _on_say_requested)

	_wire_map(world)
	return DotResult.success(null)


func _tunable_bool(cvar_name: String, current: bool, description: String, apply: Callable) -> void:
	var cvar := add_cvar(cvar_name, "1" if current else "0", description)

	if cvar != null:
		cvar.changed.connect(func(_old: String, _new: String) -> void:
			apply.call(cvar.get_bool())
			log_info("a setting changed", {"cvar": cvar_name, "now": cvar.get_string()}))


## The browser shows which route somebody is on as the map: the first route's, which is the lot
## everybody starts in.
func _wire_map(world: DdGame) -> void:
	if not world.route_order.is_empty():
		var _reported := report_map(String(world.route_order[0]))


func _game_tick(_tick: int, delta: float) -> void:
	_since_roster += delta

	if _since_roster < ROSTER_INTERVAL:
		return

	_since_roster = 0.0
	_keep_bots()


## Stand-ins up to `dd_bots`, less one for each person: they are there so the mountain is not
## empty, and a person who arrives takes one's place.
func _keep_bots() -> void:
	var world := game as DdGame

	if world == null or bridge == null or _bots == null:
		return

	var humans := 0

	for key: StringName in world.drivers:
		if not (world.drivers[key] as DdGame.Driver).is_bot:
			humans += 1

	for i in range(_bot_keys.size() - 1, -1, -1):
		if not world.drivers.has(_bot_keys[i]):
			_bot_keys.remove_at(i)

	var wanted := maxi(_bots.get_int() - humans, 0)

	while _bot_keys.size() < wanted:
		_bot_keys.append(bridge.call("add_bot", "Hauler %d" % (_bot_keys.size() + 1)))

	while _bot_keys.size() > wanted:
		bridge.call("remove_bot", _bot_keys.pop_back())


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	if services == null:
		return

	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if not said.ok:
		bridge.call("notice", peer_id, said.error.message)


func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines((game as DdGame).describe_lines())

	if bridge != null:
		ctx.reply_lines(bridge.call("describe_lines"))


func _cmd_bank(ctx: DotCmdContext) -> void:
	ctx.reply_lines((game as DdGame).bank.describe_lines())


func _cmd_weather(ctx: DotCmdContext) -> void:
	var sky := ctx.arg(0)
	var world := game as DdGame
	var forced := world.force_weather("" if sky == "off" else ("clear" if sky == "wind" else sky), sky == "wind")

	if not forced.ok:
		ctx.reply_error(forced)
		return

	bridge.call("broadcast_weather")
	ctx.reply("The sky is %s." % (sky if sky != "" and sky != "off" else "the mountain's own again"))


func _cmd_give(ctx: DotCmdContext) -> void:
	var world := game as DdGame
	var who := ctx.arg(0)
	var amount := ctx.arg_int(1)

	for key: StringName in world.drivers:
		if (world.drivers[key] as DdGame.Driver).name.to_lower() == who.to_lower():
			var now := world.bank.credit(key, amount, "admin")
			ctx.reply("%s has %d." % [who, now])
			return

	ctx.reply("Nobody called '%s' is here." % who)


func describe() -> Dictionary:
	var out := super.describe()

	if game != null:
		out.merge({"world": (game as DdGame).describe()}, true)

	return out
