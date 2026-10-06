extends Control

## What a driver sees over the road: the stage and how far along it they are, the money, the
## load, the speed, the sky over this stretch, what the trip pays if they get there, and the
## buttons the genre puts down the side (respawn, restart, skip, solo) with their keys.
##
## [b]Fed, never asking.[/b] [DdClient] calls [method show_trip] each frame with numbers it
## already has; the HUD holds no game state, so a client mirroring a server and an offline
## client draw it identically.

const DdWeather := preload("dd_weather.gd")

var _stage: Label = null
var _bar: ProgressBar = null
var _money: Label = null
var _cargo: Label = null
var _speed: Label = null
var _sky: Label = null
var _offer: Label = null
var _solo: Label = null
var _message: Label = null
var _keys: Label = null
var _message_left: float = 0.0


func _ready() -> void:
	# With offsets: under a CanvasLayer there is no parent Control, and anchors alone left this
	# zero-sized in the top-left corner (the first render).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# The stage strip across the top, as the genre has it.
	var top := PanelContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	top.offset_left = -260.0
	top.offset_right = 260.0
	top.offset_top = 10.0
	top.add_theme_stylebox_override("panel", _panel(Color(0.08, 0.09, 0.1, 0.72)))
	add_child(top)
	var strip := VBoxContainer.new()
	top.add_child(strip)
	_stage = _label(strip, "STAGE 0/0", 20, HORIZONTAL_ALIGNMENT_CENTER)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(500.0, 14.0)
	_bar.show_percentage = false
	_bar.max_value = 1.0
	_bar.add_theme_stylebox_override("fill", _panel(Color(0.98, 0.78, 0.12)))
	_bar.add_theme_stylebox_override("background", _panel(Color(0.2, 0.2, 0.22)))
	strip.add_child(_bar)

	# The numbers, top left.
	var left := VBoxContainer.new()
	left.position = Vector2(16.0, 12.0)
	add_child(left)
	_money = _label(left, "$0", 26)
	_money.add_theme_color_override("font_color", Color(0.55, 0.95, 0.5))
	_cargo = _label(left, "CARGO 100%", 18)
	_offer = _label(left, "", 16)
	_sky = _label(left, "", 16)
	_solo = _label(left, "SOLO", 16)
	_solo.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
	_solo.visible = false

	# Speed, bottom right.
	_speed = _label(self, "0 km/h", 34, HORIZONTAL_ALIGNMENT_RIGHT)
	_speed.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_speed.offset_left = -240.0
	_speed.offset_top = -64.0
	_speed.offset_right = -20.0
	_speed.offset_bottom = -16.0

	# The keys, down the right side.
	_keys = _label(self, "R  respawn\nT  restart\nN  skip stage\nB  solo\nC  camera\nG  garage", 15)
	_keys.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	_keys.offset_left = -150.0
	_keys.offset_right = -14.0
	_keys.offset_top = -70.0
	_keys.offset_bottom = 70.0
	_keys.modulate = Color(1, 1, 1, 0.75)

	# A line in the middle for a checkpoint, a fall, a delivery.
	_message = _label(self, "", 36, HORIZONTAL_ALIGNMENT_CENTER)
	_message.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_message.offset_left = -400.0
	_message.offset_right = 400.0
	_message.offset_top = -120.0
	_message.offset_bottom = -60.0
	_message.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_message.add_theme_constant_override("outline_size", 8)


func _label(parent: Node, text: String, size: int, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = align
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("outline_size", 4)
	parent.add_child(label)
	return label


static func _panel(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(6)
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 6
	box.content_margin_bottom = 6
	return box


## One frame of a trip. [param facts] carries what the client knows:
## stage, stages, fraction, cargo, speed (m/s), offer, weather {sky, wind}, zone name, state.
func show_trip(facts: Dictionary) -> void:
	var state := str(facts.get("state", "driving"))
	_stage.text = "STAGE %d/%d" % [int(facts.get("stage", 0)) + (0 if state == "delivered" else 1), int(facts.get("stages", 1))]

	if state == "delivered":
		_stage.text = "DELIVERED"

	_bar.value = clampf(float(facts.get("fraction", 0.0)), 0.0, 1.0)
	var cargo := float(facts.get("cargo", 1.0))
	_cargo.text = "CARGO %d%%" % int(round(cargo * 100.0))
	_cargo.add_theme_color_override("font_color", Color(1, 1, 1) if cargo > 0.6 else (Color(1.0, 0.75, 0.3) if cargo > 0.3 else Color(1.0, 0.35, 0.3)))
	_offer.text = "Pays $%d on delivery" % int(facts.get("offer", 0)) if state != "delivered" else ""
	_speed.text = "%d km/h" % int(round(absf(float(facts.get("speed", 0.0))) * 3.6))

	var weather: Dictionary = facts.get("weather", {})
	var words := PackedStringArray()
	var sky := int(weather.get("sky", DdWeather.CLEAR))

	if sky == DdWeather.SNOW:
		words.append("SNOW: grip low")
	elif sky == DdWeather.RAIN:
		words.append("RAIN: slippery")

	if bool(weather.get("wind", false)):
		words.append("WIND")

	var zone := str(facts.get("zone", ""))
	_sky.text = ("%s — %s" % [zone, ", ".join(words)]) if not words.is_empty() and zone != "" else (", ".join(words) if not words.is_empty() else zone)


func show_money(amount: int) -> void:
	_money.text = "$%d" % amount


func show_solo(on: bool) -> void:
	_solo.visible = on


## A line in the middle of the screen for [param seconds].
func say(text: String, seconds: float = 2.5, color: Color = Color(1, 1, 1)) -> void:
	_message.text = text
	_message.add_theme_color_override("font_color", color)
	_message_left = seconds


func message() -> String:
	return _message.text if _message_left > 0.0 else ""


func _process(delta: float) -> void:
	if _message_left > 0.0:
		_message_left -= delta
		_message.modulate.a = clampf(_message_left / 0.4, 0.0, 1.0)

		if _message_left <= 0.0:
			_message.text = ""
