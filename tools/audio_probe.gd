extends Node

## Under xvfb-run (never --headless, whose audio driver is Dummy): does a truck make a noise?
##   xvfb-run -a godot --path . res://tools/audio_probe.tscn

const DdClient := preload("res://game/dd_client.gd")


func _ready() -> void:
	var client := DdClient.new()
	client.auto_route = &"dd_foothills"
	client.autopilot = true
	add_child(client)

	await get_tree().process_frame
	# A stand-in on the same route, a second later: the truck behind, heard positionally.
	var _bot := client.game.join(&"bot", "Stand-in", true)
	var _started := client.game.start_trip(&"bot", &"dd_foothills")

	for _i in 240:
		await get_tree().process_frame

	var engine: AudioStreamPlayer = client.sounds._engine
	var bot_truck: Node = (client.game.drivers[&"bot"] as Object).get("truck")
	var other: AudioStreamPlayer3D = bot_truck.get_node_or_null("Engine3D") if bot_truck != null else null
	print("driver=%s engine_playing=%s engine_db=%.1f pitch=%.2f" % [AudioServer.get_driver_name(), engine.playing, engine.volume_db, engine.pitch_scale])
	print("other truck: engine=%s playing=%s db=%.1f pitch=%.2f" % [other != null, other.playing if other else false,
		other.volume_db if other else -999.0, other.pitch_scale if other else 0.0])
	var ok := engine.playing and engine.volume_db > -40.0 and other != null and other.playing and other.volume_db > -40.0
	get_tree().quit(0 if ok else 1)
