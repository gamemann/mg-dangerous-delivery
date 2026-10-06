extends Node

## Under xvfb-run (never --headless, whose audio driver is Dummy): does a truck make a noise?
##   xvfb-run -a godot --path . res://tools/audio_probe.tscn

const DdClient := preload("res://game/dd_client.gd")


func _ready() -> void:
	var client := DdClient.new()
	client.auto_route = &"dd_foothills"
	client.autopilot = true
	add_child(client)

	for _i in 240:
		await get_tree().process_frame

	var engine: AudioStreamPlayer = client.sounds._engine
	print("driver=%s engine_playing=%s engine_db=%.1f pitch=%.2f" % [AudioServer.get_driver_name(), engine.playing, engine.volume_db, engine.pitch_scale])
	get_tree().quit(0 if engine.playing and engine.volume_db > -40.0 else 1)
