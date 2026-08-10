extends CanvasLayer

# How long the text stays fully visible before fading out, and how long the
# fade itself takes.
export var display_time := 3.0
export var fade_time := 1.0

# Where to go once the intro is done. This is the main menu (Start /
# Settings / Quit), not the game itself -- the menu's Start button is what
# actually loads 3DScene.tscn.
export var next_scene := "res://ui/MainMenu.tscn"

onready var root = $Root

var _finished = false

func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	root.modulate.a = 1.0

	yield(get_tree().create_timer(display_time), "timeout")
	_finish()

func _input(event):
	# Let the player skip the intro early with any key/click/gamepad button.
	if _finished:
		return
	if (event is InputEventKey or event is InputEventMouseButton or event is InputEventJoypadButton) and event.pressed:
		_finish()

func _finish():
	if _finished:
		return
	_finished = true

	var tween = Tween.new()
	add_child(tween)
	tween.interpolate_property(root, "modulate:a", root.modulate.a, 0.0, fade_time, Tween.TRANS_SINE, Tween.EASE_IN_OUT)
	tween.start()
	yield(tween, "tween_all_completed")

	# This frees the Intro scene (and this script's node), so nothing below
	# this call should touch `self` or its children.
	get_tree().change_scene(next_scene)
