extends Node3D

## One player at the wheel: the garage, the camera, the controls, the HUD, and the sky.
##
## [b]Offline today, and built so a server can take the world away from it.[/b] Everything
## the player does goes through [method _act] (garage) and [member command] (driving), and
## everything they see comes from [member game] — which offline is an authoritative [DdGame]
## this client owns, and against a server will be a mirror the bridge keeps. Nothing here
## decides a price, a checkpoint or a fall.

const DdGame := preload("dd_game.gd")
const DdHud := preload("dd_hud.gd")
const DdGarage := preload("dd_garage.gd")
const DdRoute := preload("dd_route.gd")
const DdTrip := preload("dd_trip.gd")
const DdTruck := preload("dd_truck.gd")
const DdWeather := preload("dd_weather.gd")

const CHANNEL := "delivery.client"

## Who this player is in [member game].
@export var local_key: StringName = &"you"
@export var local_name: String = "Driver"

## Route id to set off on at once, skipping the garage. For a screenshot or a quick test.
@export var auto_route: StringName = &""

## Hand the wheel to dot-vehicle's driver: what a screenshot of a moving truck uses.
@export var autopilot: bool = false

enum CameraMode { CHASE, CAB, HIGH }

var game: DdGame = null
var hud: DdHud = null
var garage: DdGarage = null
var camera: Camera3D = null
var camera_mode: CameraMode = CameraMode.CHASE
var command := DotVehicleCommand.new()

var _rain: CPUParticles3D = null
var _snow: CPUParticles3D = null
var _sun: DirectionalLight3D = null
var _env: Environment = null
var _look := Vector3.ZERO


func _ready() -> void:
	_build_environment()

	game = DdGame.new()
	game.name = "World"
	game.draws = true
	game.authoritative = true
	add_child(game)
	var _me := game.join(local_key, local_name)

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.far = 3000.0
	camera.fov = 70.0
	add_child(camera)
	camera.current = true
	_frame_garage_camera()

	_build_weather()

	var layer := CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)
	hud = DdHud.new()
	hud.name = "Hud"
	layer.add_child(hud)
	garage = DdGarage.new()
	garage.name = "Garage"
	garage.act = _act
	layer.add_child(garage)

	game.stage_reached.connect(func(key: StringName, stage: int) -> void:
		if key == local_key:
			hud.say("CHECKPOINT %d" % stage, 2.0, Color(1.0, 0.85, 0.3)))
	game.fell.connect(func(key: StringName, why: String) -> void:
		if key == local_key:
			hud.say({"fell": "OVER THE EDGE", "flipped": "ON ITS SIDE", "respawn": "BACK TO THE CHECKPOINT"}.get(why, why.to_upper()), 2.0, Color(1.0, 0.4, 0.35)))
	game.delivered.connect(func(key: StringName, _route: StringName, pay: int) -> void:
		if key == local_key:
			hud.say("DELIVERED  +$%d" % pay, 4.0, Color(0.55, 0.95, 0.5))
			hud.show_money(game.bank.money(local_key)))
	game.bank.account_changed.connect(func(key: StringName) -> void:
		if key == local_key:
			hud.show_money(game.bank.money(local_key))
			_refresh_garage())
	game.solo_changed.connect(func(key: StringName, on: bool) -> void:
		if key == local_key:
			hud.show_solo(on)
			hud.say("SOLO" if on else "WITH EVERYBODY", 1.5, Color(0.6, 0.85, 1.0)))

	hud.show_money(game.bank.money(local_key))
	_refresh_garage()
	_show_garage(true)

	if auto_route != &"":
		_act("start", {"route": String(auto_route)})


func _driver() -> DdGame.Driver:
	return game.drivers.get(local_key, null)


# --- The garage --------------------------------------------------------------

func _act(action: String, args: Dictionary) -> void:
	var done: DotResult = null
	var acct := game.bank.account(local_key)

	match action:
		"start":
			done = game.start_trip(local_key, StringName(str(args.get("route", ""))))

			if done.ok:
				_show_garage(false)

				if autopilot:
					var me := _driver()
					me.is_bot = true
					me.autopilot = DotVehicleDriver.new()
					me.autopilot.target_speed = 10.0
					me.autopilot.set_route(game._global_points(me.trip.route_id, 4.0))
		"buy_truck":
			done = game.buy_truck(local_key, StringName(str(args["truck"])))
		"select_truck":
			done = game.select_truck(local_key, StringName(str(args["truck"])))
		"upgrade":
			done = game.buy_upgrade(local_key, StringName(str(acct["truck"])), str(args["kind"]))

	if done != null and not done.ok:
		garage.notice(done.error.message)
	elif done != null:
		garage.notice("")

	_refresh_garage()


func _refresh_garage() -> void:
	garage.refresh(game.garage_view(local_key))


func _show_garage(on: bool) -> void:
	garage.visible = on
	hud.visible = not on
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	if on:
		_frame_garage_camera()


func _frame_garage_camera() -> void:
	if game == null or game.route_order.is_empty():
		return

	var road: DdRoute = game.routes[game.route_order[0]]
	var at := road.transform_at(0.0, 0.0)
	at.origin += road.position
	camera.global_position = at.origin + at.basis * Vector3(16.0, 9.0, 18.0)
	camera.look_at(at.origin + at.basis * Vector3(0.0, 1.0, -30.0))


# --- Controls ----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey

	if key == null or not key.pressed or key.echo:
		return

	var me := _driver()

	match key.keycode:
		KEY_B:
			if me != null:
				var _s := game.set_solo(local_key, not me.solo)
		KEY_R:
			_say_refusal(game.respawn(local_key))
		KEY_T:
			_say_refusal(game.restart(local_key))
		KEY_N:
			_say_refusal(game.skip(local_key))
		KEY_C:
			camera_mode = (camera_mode + 1) % 3 as CameraMode
		KEY_G, KEY_ESCAPE:
			game.end_trip(local_key)
			_refresh_garage()
			_show_garage(true)


func _say_refusal(result: DotResult) -> void:
	if result != null and not result.ok:
		hud.say(result.error.message, 2.0, Color(1.0, 0.7, 0.4))


func _physics_process(_delta: float) -> void:
	var me := _driver()

	if me == null or not me.on_road() or garage.visible or me.is_bot:
		return

	command = DotVehicleCommand.new()
	var forward := Input.get_action_strength("ui_up") + (1.0 if Input.is_key_pressed(KEY_W) else 0.0)
	var back := Input.get_action_strength("ui_down") + (1.0 if Input.is_key_pressed(KEY_S) else 0.0)
	var left := Input.get_action_strength("ui_left") + (1.0 if Input.is_key_pressed(KEY_A) else 0.0)
	var right := Input.get_action_strength("ui_right") + (1.0 if Input.is_key_pressed(KEY_D) else 0.0)
	var speed := (me.truck as DdTruck).forward_speed()

	# One key for slowing down and reversing, which is how every driving game does it: brake
	# while still rolling forward, reverse once stopped.
	if back > 0.0 and speed > 0.8:
		command.brake = clampf(back, 0.0, 1.0)
		command.throttle = 0.0
	else:
		command.throttle = clampf(forward, 0.0, 1.0) - clampf(back, 0.0, 1.0)

	command.steer = clampf(right - left, -1.0, 1.0)
	command.handbrake = Input.is_key_pressed(KEY_SPACE)
	game.set_command(local_key, command)


# --- Every frame -------------------------------------------------------------

func _process(delta: float) -> void:
	var me := _driver()

	for k: StringName in game.drivers:
		var other: DdGame.Driver = game.drivers[k]

		if other.truck != null and is_instance_valid(other.truck):
			(other.truck as Node3D).visible = game.sees(me, other)

	if me == null or not me.on_road():
		_set_weather({"sky": DdWeather.CLEAR, "wind": false})
		return

	var trip: DdTrip = me.trip
	var truck: DdTruck = me.truck
	var road: DdRoute = game.routes[trip.route_id]
	var weather := game.weather_at(trip.route_id, trip.distance)
	var zone_id := road.zone_at(trip.distance)
	var zone_name := str((road.doc.get("zones", {}) as Dictionary).get(zone_id, {}).get("name", ""))

	hud.show_trip({
		"stage": trip.stage, "stages": trip.stages, "fraction": trip.distance / maxf(road.length(), 1.0),
		"cargo": trip.cargo, "speed": truck.forward_speed(), "offer": trip.pay_now(game.config),
		"weather": weather, "zone": zone_name, "state": trip.state_name(),
	})
	_set_weather(weather)
	_follow(truck, delta)


func _follow(truck: DdTruck, delta: float) -> void:
	var basis := truck.global_basis
	# Flattened, so a truck on its side does not roll the camera with it.
	var flat := Vector3(basis.z.x, 0.0, basis.z.z).normalized()

	if flat == Vector3.ZERO:
		flat = Vector3.BACK

	var target: Vector3
	var look: Vector3

	match camera_mode:
		CameraMode.CAB:
			target = truck.global_position + basis * Vector3(0.0, 2.6, -truck.half_length * 0.55)
			look = target - basis.z * 20.0
			camera.global_position = target
			camera.look_at(look)
			return
		CameraMode.HIGH:
			target = truck.global_position + flat * 22.0 + Vector3(0.0, 16.0, 0.0)
			look = truck.global_position - flat * 8.0
		_:
			target = truck.global_position + flat * (truck.half_length + 9.0) + Vector3(0.0, 5.5, 0.0)
			look = truck.global_position - flat * 6.0 + Vector3(0.0, 1.5, 0.0)

	var k := 1.0 - exp(-delta * 5.0)
	camera.global_position = camera.global_position.lerp(target, k)
	_look = _look.lerp(look, k) if _look != Vector3.ZERO else look
	camera.look_at(_look)


# --- The sky -----------------------------------------------------------------

func _build_environment() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var material := ProceduralSkyMaterial.new()
	material.sky_top_color = Color(0.42, 0.62, 0.86)
	material.sky_horizon_color = Color(0.78, 0.84, 0.9)
	material.ground_bottom_color = Color(0.2, 0.3, 0.32)
	material.ground_horizon_color = Color(0.7, 0.76, 0.8)
	sky.sky_material = material
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.ambient_light_energy = 0.5
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env.tonemap_exposure = 0.8
	_env.fog_enabled = true
	_env.fog_light_color = Color(0.78, 0.84, 0.9)
	_env.fog_density = 0.0012
	var world := WorldEnvironment.new()
	world.name = "Environment"
	world.environment = _env
	add_child(world)

	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	_sun.light_energy = 1.1
	_sun.shadow_enabled = true
	_sun.directional_shadow_max_distance = 160.0
	add_child(_sun)


## Rain and snow are particles round the camera, not over the mountain: what falls a kilometre
## away cannot be seen, and a mountain's worth of particles is a browser's whole frame.
func _build_weather() -> void:
	_rain = _particles(Color(0.7, 0.75, 0.85, 0.6), Vector3(0.0, -28.0, 0.0), Vector3(0.03, 0.6, 0.03), 1600)
	_snow = _particles(Color(1, 1, 1, 0.95), Vector3(0.0, -3.0, 0.0), Vector3(0.12, 0.12, 0.12), 1400)


func _particles(color: Color, gravity: Vector3, size: Vector3, amount: int) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = 2.5 if gravity.y < -10.0 else 6.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(30.0, 2.0, 30.0)
	p.gravity = gravity
	p.direction = Vector3.DOWN
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 4.0
	p.local_coords = false
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = material
	p.mesh = mesh
	p.emitting = false
	camera.add_child(p) if camera != null else add_child(p)
	p.position = Vector3(0.0, 14.0, -10.0)
	return p


func _set_weather(weather: Dictionary) -> void:
	if _rain == null:
		return

	var sky := int(weather.get("sky", DdWeather.CLEAR))
	_rain.emitting = sky == DdWeather.RAIN
	_snow.emitting = sky == DdWeather.SNOW
	var dim := 0.55 if sky != DdWeather.CLEAR else 1.1
	_sun.light_energy = lerpf(_sun.light_energy, dim, 0.02)
	_env.fog_density = lerpf(_env.fog_density, 0.006 if sky == DdWeather.SNOW else (0.003 if sky == DdWeather.RAIN else 0.0012), 0.02)
