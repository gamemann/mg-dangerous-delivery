extends Node3D

## A stand-in drives one route to the depot and says how it went. See drive.sh.
##
## ROUTE=dd_snowline BOTSPEED=7 CALM=1 ROCKS=0 SECS=600 TRUCK=hauler

const DdGame := preload("res://game/dd_game.gd")

var game
var t := 0.0
var route_id := StringName(OS.get_environment("ROUTE") if OS.get_environment("ROUTE") != "" else "dd_foothills")

func _ready() -> void:
	game = DdGame.new()
	game.draws = false
	add_child(game)
	game.config.boulders_enabled = OS.get_environment("ROCKS") != "0"
	game.config.levels_unlock_in_order = false
	print(game.describe_lines())
	var _bot = game.join(&"bot1", "Bot", true)
	if OS.get_environment("TRUCK") != "":
		var _c = game.bank.credit(&"bot1", 100000, "drive tool")
		var _b = game.buy_truck(&"bot1", StringName(OS.get_environment("TRUCK")))
	game.drivers[&"bot1"].idle = 999.0
	if OS.get_environment("BOTSPEED") != "": game.drivers[&"bot1"].autopilot.target_speed = float(OS.get_environment("BOTSPEED"))
	if OS.get_environment("CALM") != "": game.config.weather_frequency = 0.0
	print(game.start_trip(&"bot1", route_id).ok)

func _physics_process(delta: float) -> void:
	t += delta
	var d = game.drivers[&"bot1"]
	if int(t * 60) % 120 == 0:
		print("t=%.0f %s speed=%.1f" % [t, d.trip.describe() if d.trip else "garage", game.truck_speed(d)])
	if t > float(OS.get_environment("SECS") if OS.get_environment("SECS") != "" else "120") or (d.trip and d.trip.state == 3):
		print("END t=%.0f %s paid=%d money=%d" % [t, d.trip.describe() if d.trip else "-", d.trip.paid if d.trip else -1, game.bank.money(&"bot1")])
		get_tree().quit()
