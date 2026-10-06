extends VehicleBody3D

## The trailer behind a tractor unit: a box on two free-rolling axles, hitched to the truck by
## a joint that lets it swing and nod but not roll off on its own.
##
## [b]A VehicleBody3D, not a box dragged along the road[/b]: a dragged box is friction against
## the floor and stops the truck dead on a climb; wheels roll. None of them is driven or steered,
## and the rear axle's grip is what makes it track the truck round a bend instead of sliding wide.
##
## [b]Why it is the point[/b]: the brief is eighteen-wheelers on mountain roads, and what makes
## one hard is the half you are not steering. A trailer cuts inside a hairpin, swings wide on ice
## and pushes on a descent. Configurable per truck (`trailer` in DdTrucks: length, mass, whether
## there is one at all).

const CHANNEL := "delivery.trailer"

var length: float = 7.0
var width: float = 2.5
var height: float = 2.9

## The hitch: where on the truck, in its frame, the trailer's front pivots.
var hitch_on_truck: Vector3 = Vector3.ZERO

var joint: Generic6DOFJoint3D = null
var _wheels: Array[VehicleWheel3D] = []


## Builds it from [param spec] ({length, mass, colour}); [param draws] adds the mesh.
func configure(spec: Dictionary, truck_half_length: float, truck_width: float, draws: bool) -> void:
	name = "Trailer"
	length = float(spec.get("length", 7.0))
	width = minf(float(spec.get("width", truck_width)), 2.8)
	height = float(spec.get("height", 2.9))
	mass = float(spec.get("mass", 3000.0))
	continuous_cd = true
	can_sleep = false
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.4, 0)
	# The hitch sits a little behind the truck's rear and the trailer's front just past it, so
	# the two boxes never touch when it swings.
	hitch_on_truck = Vector3(0, 0.9, truck_half_length + 0.35)

	var shape := BoxShape3D.new()
	shape.size = Vector3(width, height - 0.9, length)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = Vector3(0, 0.9 + (height - 0.9) * 0.5, length * 0.5 + 0.4)
	add_child(collider)

	for z in [length - 1.6, length - 0.5]:
		for x in [-width * 0.5 + 0.35, width * 0.5 - 0.35]:
			var wheel := VehicleWheel3D.new()
			wheel.wheel_radius = 0.5
			wheel.wheel_rest_length = 0.3
			wheel.suspension_travel = 0.3
			wheel.suspension_stiffness = 60.0
			wheel.suspension_max_force = mass * 9.8 * 2.0
			wheel.wheel_friction_slip = 3.0
			wheel.damping_compression = 0.6
			wheel.damping_relaxation = 0.8
			wheel.position = Vector3(x, 0.5 + 0.3, z + 0.4)
			add_child(wheel)
			_wheels.append(wheel)

			if draws:
				var tyre := MeshInstance3D.new()
				var cylinder := CylinderMesh.new()
				cylinder.top_radius = 0.5
				cylinder.bottom_radius = 0.5
				cylinder.height = 0.35
				tyre.mesh = cylinder
				tyre.rotation.z = PI * 0.5
				var black := StandardMaterial3D.new()
				black.albedo_color = Color(0.08, 0.08, 0.09)
				tyre.material_override = black
				wheel.add_child(tyre)

	if draws:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = shape.size
		box.mesh = mesh
		box.position = collider.position
		var material := StandardMaterial3D.new()
		material.albedo_color = spec.get("colour", Color(0.85, 0.85, 0.82)) if spec.get("colour") is Color else Color(0.85, 0.85, 0.82)
		material.roughness = 0.6
		box.material_override = material
		add_child(box)
		var stripe := MeshInstance3D.new()
		var band := BoxMesh.new()
		band.size = Vector3(width + 0.02, 0.35, length - 0.6)
		stripe.mesh = band
		stripe.position = collider.position + Vector3(0, 0.2, 0)
		var red := StandardMaterial3D.new()
		red.albedo_color = Color(0.75, 0.15, 0.12)
		stripe.material_override = red
		add_child(stripe)


## Hitches it to [param truck], both already in the tree and placed.
func hitch(truck: VehicleBody3D) -> void:
	add_collision_exception_with(truck)
	truck.add_collision_exception_with(self)
	joint = Generic6DOFJoint3D.new()
	joint.name = "Hitch"

	for axis in ["x", "y", "z"]:
		joint.set("linear_limit_%s/enabled" % axis, true)
		joint.set("linear_limit_%s/upper_distance" % axis, 0.0)
		joint.set("linear_limit_%s/lower_distance" % axis, 0.0)

	# Swing (yaw) wide, nod (pitch) a little for a crest, roll hardly at all: a trailer that
	# could roll independently would fall off the road while the truck stayed on it.
	joint.set("angular_limit_y/enabled", true)
	joint.set("angular_limit_y/upper_angle", deg_to_rad(80.0))
	joint.set("angular_limit_y/lower_angle", deg_to_rad(-80.0))
	joint.set("angular_limit_x/enabled", true)
	joint.set("angular_limit_x/upper_angle", deg_to_rad(18.0))
	joint.set("angular_limit_x/lower_angle", deg_to_rad(-18.0))
	joint.set("angular_limit_z/enabled", true)
	joint.set("angular_limit_z/upper_angle", deg_to_rad(4.0))
	joint.set("angular_limit_z/lower_angle", deg_to_rad(-4.0))
	truck.get_parent().add_child(joint)
	joint.global_transform = Transform3D(truck.global_basis, truck.to_global(hitch_on_truck))
	joint.node_a = joint.get_path_to(truck)
	joint.node_b = joint.get_path_to(self)


## Puts it straight behind [param truck_at] (the truck's transform), stopped.
func place_behind(truck_at: Transform3D) -> void:
	var at := Transform3D(truck_at.basis, truck_at * hitch_on_truck - truck_at.basis * Vector3(0, 0.9, 0))
	global_transform = at
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, at)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)


## Re-hitches after a teleport: a joint whose two bodies jumped apart pulls them back together
## violently, so it is rebuilt at the new place instead.
func rehitch(truck: VehicleBody3D) -> void:
	if joint != null and is_instance_valid(joint):
		joint.get_parent().remove_child(joint)
		joint.queue_free()

	joint = null
	place_behind(truck.global_transform)
	hitch(truck)


## The angle between truck and trailer, degrees: what a jack-knife is.
func angle_to(truck: Node3D) -> float:
	return rad_to_deg(truck.global_basis.z.signed_angle_to(global_basis.z, Vector3.UP))


func set_grip(grip: float) -> void:
	for wheel in _wheels:
		wheel.wheel_friction_slip = 3.0 * grip


func describe() -> Dictionary:
	return {"length": length, "mass": mass, "hitched": joint != null}
