extends RefCounted
## Stable IDs are authored on any actor as definition.bubble_skin_id or metadata.
const PATH := "res://data/ui/dialogue_skins.json"
const FONT_PATH := "res://assets/ui/fonts/ark-pixel-12px-proportional-zh_hans.otf"
static var _catalog: Dictionary = {}
static var _font: FontFile

static func all() -> Dictionary:
	if _catalog.is_empty(): _catalog=JSON.parse_string(FileAccess.get_file_as_string(PATH))
	return _catalog.duplicate(true)

static func resolve(id: String) -> Dictionary:
	var catalog:=all()
	return catalog.get(id,catalog.villager_bubble).duplicate(true)

static func for_actor(actor: Node, player: Node = null) -> String:
	if not is_instance_valid(actor): return "villager_bubble"
	var explicit:=str(actor.get_meta("bubble_skin_id",""))
	var definition: Variant=actor.get("definition")
	if explicit.is_empty() and definition is Dictionary: explicit=str(definition.get("bubble_skin_id",""))
	if not explicit.is_empty() and all().has(explicit): return explicit
	if actor==player or actor.get("is_player")==true: return "player_bubble"
	if str(actor.get("race_id")).contains("demon"): return "demon_bubble"
	return "villager_bubble"

static func font() -> FontFile:
	if _font==null:
		_font=load(FONT_PATH).duplicate()
		_font.antialiasing=TextServer.FONT_ANTIALIASING_NONE
		_font.hinting=TextServer.HINTING_NONE
		_font.subpixel_positioning=TextServer.SUBPIXEL_POSITIONING_DISABLED
		_font.oversampling=1.0
	return _font
