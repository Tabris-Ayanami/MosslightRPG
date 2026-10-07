extends Control
## Select the fixed release before loading App: its property initializers create
## a SaveRepository and therefore the first CombatDatabase.
const Release = preload("res://rpg/content_release.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
var release_directory := ""
var storage_root := "user://releases"
var app: Node
var startup_error := ""

func _ready() -> void:
	_start.call_deferred()

func _start() -> void:
	if release_directory.is_empty():
		for argument in OS.get_cmdline_user_args():
			if argument.begins_with("--release-root="):
				release_directory = argument.trim_prefix("--release-root=")
	if release_directory.is_empty() and OS.has_feature("formal_release"):
		release_directory = Release.distribution_directory()
	if not release_directory.is_empty():
		var result: Dictionary = Release.activate(release_directory, storage_root)
		if not result.ok:
			_fail(result.error)
			return
		if DirAccess.make_dir_recursive_absolute(Release.preferences_path().get_base_dir()) != OK:
			_fail("无法创建此版本的保存目录")
			return
		Preferences.settings_path = Release.preferences_path()
	app = load("res://scenes/frontend/app.tscn").instantiate()
	add_child(app)
	print("GAME_STARTUP ", JSON.stringify({"formal":Release.is_active(), "identity":Release.identity()}))

func _fail(reason: String) -> void:
	startup_error = reason
	printerr("GAME_STARTUP_REFUSED ", reason)
	if DisplayServer.get_name() == "headless":
		get_tree().quit(1)
		return
	var backdrop := ColorRect.new()
	backdrop.color = Color("202923")
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(580, 0)
	column.add_theme_constant_override("separation", 24)
	center.add_child(column)
	var title := Label.new()
	title.text = "暂时无法开始旅途"
	title.add_theme_font_size_override("font_size", 28)
	column.add_child(title)
	var explanation := Label.new()
	explanation.text = reason + "\n请恢复同一版本的完整游戏文件后重新启动。"
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	explanation.custom_minimum_size.x = 580
	explanation.add_theme_font_size_override("font_size", 20)
	column.add_child(explanation)
	var close := Button.new()
	close.text = "退出游戏"
	close.custom_minimum_size.y = 46
	close.pressed.connect(func(): get_tree().quit(1))
	column.add_child(close)
	close.grab_focus()
