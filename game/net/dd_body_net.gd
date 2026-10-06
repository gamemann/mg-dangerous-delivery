extends DotNetBehaviour

## A replicated rigid body: a boulder, and the base of a truck's.
##
## [b]Server-authoritative and never predicted[/b] — dot-vehicle's and dot-props' decision: two
## machines diverge on a rigid body within seconds, and a correction on something being steered
## reads worse than latency. The server pulls the body's pose; a client draws it, interpolated,
## on a body frozen so its own physics never fights the packets.

var body: Node3D = null

var net_position: Vector3 = Vector3.ZERO
var net_rotation: Quaternion = Quaternion.IDENTITY


func _register_net_vars() -> void:
	replicate(&"net_position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
	replicate(&"net_rotation", DotNetVar.Type.QUATERNION).bits(10).interpolated()


func pull() -> void:
	if body == null or not is_instance_valid(body):
		return

	net_position = body.global_position
	net_rotation = body.global_basis.get_rotation_quaternion()


func _net_simulate(_tick: int, _delta: float) -> void:
	if identity != null and identity.is_authoritative:
		pull()


func _net_state_applied(_tick: int) -> void:
	_draw()


func _net_interpolated(_tick: int) -> void:
	_draw()


func _draw() -> void:
	if body == null or not is_instance_valid(body):
		return

	if identity != null and identity.is_authoritative:
		return

	body.global_transform = Transform3D(Basis(net_rotation), net_position)

	var rigid := body as RigidBody3D

	if rigid != null and not rigid.freeze:
		rigid.freeze = true
