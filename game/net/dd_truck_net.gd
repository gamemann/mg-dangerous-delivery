extends "dd_body_net.gd"

## A truck: its pose, plus the steering and speed nothing else replicated can give a watcher.
##
## The steering is what makes a mirrored truck look driven: without it every other truck goes
## round a hairpin with its front wheels straight ahead (mg-buses-from-hell's finding). The
## speed is for the client's own HUD and an engine sound later.

var net_steering: int = 0
var net_speed: int = 0


func _register_net_vars() -> void:
	super._register_net_vars()
	replicate(&"net_steering", DotNetVar.Type.INT).bits(8)
	replicate(&"net_speed", DotNetVar.Type.INT).bits(10)


func pull() -> void:
	super.pull()
	var truck := body as VehicleBody3D

	if truck == null:
		return

	net_steering = clampi(int(round(truck.steering / 0.6 * 127.0)), -127, 127)
	# km/h, signed by direction, so the HUD needs no second conversion.
	net_speed = clampi(int(round(-truck.global_basis.z.dot(truck.linear_velocity) * 3.6)), -511, 511)


func _draw() -> void:
	super._draw()
	var truck := body as VehicleBody3D

	if truck != null and (identity == null or not identity.is_authoritative):
		truck.steering = float(net_steering) / 127.0 * 0.6


func speed_ms() -> float:
	return float(net_speed) / 3.6
