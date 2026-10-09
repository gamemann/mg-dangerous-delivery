extends Control

## The player asked for the settings screen. The client owns it; the lot only has the button.
signal settings_requested

## The lot: pick a route, pick a truck, buy one, upgrade it, set off.
##
## [b]It asks and is told.[/b] Every button calls [member act] with an action and its
## arguments — "start", "buy_truck", "select_truck", "upgrade" — and the garage redraws from
## the next [method refresh]. Offline, [member act] is the world itself; against a server it is
## a request on the wire. The garage never decides whether a purchase happened, because the
## party that holds the money does.

## [code]func(action: String, args: Dictionary)[/code].
var act: Callable = Callable()

var _money: Label = null
var _routes: VBoxContainer = null
var _trucks: VBoxContainer = null
var _upgrades: VBoxContainer = null
var _notice: Label = null
var _picked_route: StringName = &""
var _view: Dictionary = {}


func _ready() -> void:
	# With offsets: under a CanvasLayer there is no parent Control, and anchors alone left this
	# zero-sized in the top-left corner (the first render).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.04, 0.05, 0.55)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	var frame := PanelContainer.new()
	frame.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	frame.offset_left = -560.0
	frame.offset_right = 560.0
	frame.offset_top = -300.0
	frame.offset_bottom = 300.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.11, 0.13, 0.94)
	style.set_corner_radius_all(10)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	frame.add_theme_stylebox_override("panel", style)
	add_child(frame)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	frame.add_child(column)

	var head := HBoxContainer.new()
	column.add_child(head)
	var title := Label.new()
	title.text = "DANGEROUS DELIVERY — THE LOT"
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_money = Label.new()
	_money.add_theme_font_size_override("font_size", 26)
	_money.add_theme_color_override("font_color", Color(0.55, 0.95, 0.5))
	head.add_child(_money)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	column.add_child(body)
	_routes = _section(body, "ROUTES", 1.3)
	_trucks = _section(body, "TRUCKS", 1.0)
	_upgrades = _section(body, "UPGRADES", 0.8)

	var foot := HBoxContainer.new()
	column.add_child(foot)
	_notice = Label.new()
	_notice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_notice.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
	foot.add_child(_notice)
	# [b]Settings live behind a button here, not behind Escape[/b], which this game gave to the
	# lot itself: Escape is how a driver gets back to the garage, and taking it would leave
	# them no key for the one screen every trip starts from.
	var options := Button.new()
	options.name = "Settings"
	options.text = "  SETTINGS  "
	options.add_theme_font_size_override("font_size", 18)
	options.pressed.connect(func() -> void: settings_requested.emit())
	foot.add_child(options)
	var go := Button.new()
	go.name = "Start"
	go.text = "  SET OFF  "
	go.add_theme_font_size_override("font_size", 22)
	go.pressed.connect(func() -> void: _do("start", {"route": String(_picked_route)}))
	foot.add_child(go)


func _section(parent: Node, heading: String, stretch: float) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_stretch_ratio = stretch
	parent.add_child(box)
	var label := Label.new()
	label.text = heading
	label.add_theme_font_size_override("font_size", 16)
	label.modulate = Color(1, 1, 1, 0.6)
	box.add_child(label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)
	return list


func _do(action: String, args: Dictionary) -> void:
	if act.is_valid():
		act.call(action, args)


## Redraws from [param view]: {money, routes: [{id, name, level, blurb, length, pay, locked,
## stages}], trucks: [{id, name, blurb, price, pay, owned, selected}], upgrades: [{kind, name,
## level, levels, cost}]}.
func refresh(view: Dictionary) -> void:
	_view = view
	_money.text = "$%d" % int(view.get("money", 0))

	if _picked_route == &"" or not _has_open_route(_picked_route):
		_picked_route = _first_open_route()

	_clear(_routes)

	for r: Dictionary in view.get("routes", []):
		var id := StringName(str(r["id"]))
		var button := Button.new()
		button.toggle_mode = true
		button.button_pressed = id == _picked_route
		button.disabled = bool(r.get("locked", false))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.text = "L%d  %s  —  %d m, %d stages, from $%d%s\n      %s" % [
			int(r["level"]), r["name"], int(r["length"]), int(r["stages"]), int(r["pay"]),
			"   LOCKED" if bool(r.get("locked", false)) else "", r.get("blurb", "")]
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.pressed.connect(func() -> void:
			_picked_route = id
			refresh(_view))
		_routes.add_child(button)

	_clear(_trucks)

	for t: Dictionary in view.get("trucks", []):
		var id := String(t["id"])
		var button := Button.new()
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var state := "DRIVING" if bool(t.get("selected", false)) else ("owned" if bool(t.get("owned", false)) else "$%d" % int(t["price"]))
		button.text = "%s  [%s]  pay x%.1f\n      %s" % [t["name"], state, float(t["pay"]), t.get("blurb", "")]
		button.disabled = bool(t.get("selected", false))

		if bool(t.get("owned", false)):
			button.pressed.connect(func() -> void: _do("select_truck", {"truck": id}))
		else:
			button.pressed.connect(func() -> void: _do("buy_truck", {"truck": id}))

		_trucks.add_child(button)

	_clear(_upgrades)

	for u: Dictionary in view.get("upgrades", []):
		var kind := str(u["kind"])
		var button := Button.new()
		var maxed := int(u["cost"]) < 0
		button.text = "%s  %d/%d  %s" % [u["name"], int(u["level"]), int(u["levels"]), "MAX" if maxed else "$%d" % int(u["cost"])]
		button.disabled = maxed
		button.pressed.connect(func() -> void: _do("upgrade", {"kind": kind}))
		_upgrades.add_child(button)


func notice(text: String) -> void:
	if _notice != null:
		_notice.text = text


func picked_route() -> StringName:
	return _picked_route


func _has_open_route(id: StringName) -> bool:
	for r: Dictionary in _view.get("routes", []):
		if StringName(str(r["id"])) == id and not bool(r.get("locked", false)):
			return true

	return false


func _first_open_route() -> StringName:
	var best: StringName = &""

	# The highest level unlocked: the one a returning player wants next.
	for r: Dictionary in _view.get("routes", []):
		if not bool(r.get("locked", false)):
			best = StringName(str(r["id"]))

	return best


static func _clear(box: Node) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()
