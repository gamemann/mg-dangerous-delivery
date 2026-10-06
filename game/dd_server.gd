extends Node

## What a dedicated server loads as this game's scene: the world, and nothing that draws.
## The module (dd_module.gd) builds the netcode around it.

const DdGame := preload("dd_game.gd")

const CHANNEL := "delivery.server"

var game: DdGame = null


func _ready() -> void:
	game = DdGame.new()
	game.name = "World"
	game.draws = false
	game.self_tick = false
	# The engine's rate, which the server has already set from `sv_tickrate`.
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)
	DotLog.info(CHANNEL, "the mountain is up", game.describe())
