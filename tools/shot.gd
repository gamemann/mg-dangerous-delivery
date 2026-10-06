extends Node

## Renders one frame of the game for a person to look at. See shot.sh.

const DdClient := preload("res://game/dd_client.gd")
const DdWeather := preload("res://game/dd_weather.gd")

var _args: Dictionary = {}


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			_args[arg.substr(2, arg.find("=") - 2)] = arg.substr(arg.find("=") + 1)

	var client := DdClient.new()
	var view := str(_args.get("view", "garage"))

	if view != "garage":
		client.auto_route = StringName(str(_args.get("route", "dd_foothills")))
		client.autopilot = true

	add_child(client)
	client.game.config.levels_unlock_in_order = false

	var truck := str(_args.get("truck", ""))

	if truck != "":
		var _c = client.game.bank.credit(client.local_key, 100000, "shot")
		var _b = client.game.buy_truck(client.local_key, StringName(truck))

	if view != "garage":
		# Unlocking was refused at _ready for anything above level 1: ask again now it is off.
		client.game.end_trip(client.local_key)
		client._act("start", {"route": str(_args.get("route", "dd_foothills"))})

	var sky := str(_args.get("sky", ""))

	if sky != "":
		var _forced: DotResult = client.game.force_weather("clear" if sky == "wind" else sky, sky == "wind")

	# Put the truck this many metres along its route first: a hazard half a kilometre up a
	# road is otherwise minutes of simulated driving under a renderer.
	var at_m := float(_args.get("at", "0"))

	if at_m > 0.0 and view != "garage":
		await get_tree().physics_frame
		var me = client.game.drivers[client.local_key]
		var road = client.game.routes[me.trip.route_id]
		var where: Transform3D = road.transform_at(at_m, 0.8)
		where.origin += road.position
		me.truck.place(where)

		# Re-hitched, as the game does on every teleport: a joint whose two bodies jumped
		# apart yanks them back together (the first render: the truck dragged back to its
		# trailer at the lot, 43% of the load gone).
		if me.trailer != null:
			me.trailer.rehitch(me.truck)
		me.trip.distance = at_m
		me.trip.hint = road.index_at_distance(at_m)
		me.autopilot.set_route(client.game._global_points(me.trip.route_id, at_m))

	if view == "cab":
		client.camera_mode = DdClient.CameraMode.CAB
	elif view == "high":
		client.camera_mode = DdClient.CameraMode.HIGH

	await get_tree().create_timer(float(_args.get("seconds", "6"))).timeout

	if view == "above":
		var road = client.game.routes[StringName(str(_args.get("route", "dd_foothills")))]
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		for p in road.points:
			lo = lo.min(p + road.position)
			hi = hi.max(p + road.position)
		var centre := (lo + hi) * 0.5
		var cam := Camera3D.new()
		cam.far = 5000.0
		add_child(cam)
		cam.global_position = centre + Vector3(0.0, maxf(hi.x - lo.x, hi.z - lo.z) * 0.9 + 60.0, maxf(hi.z - lo.z, 1.0) * 0.35)
		cam.look_at(centre)
		cam.current = true
		client.hud.visible = false
		# From this high, fog is all there is.
		client._env.fog_enabled = false

	for _i in 3:
		await RenderingServer.frame_post_draw

	var path := ProjectSettings.globalize_path(str(_args.get("out", "res://screenshots/shot.png")))
	var image := get_viewport().get_texture().get_image()
	var saved := image.save_png(path)
	print("saved %s (%s)" % [path, error_string(saved)])
	get_tree().quit()
