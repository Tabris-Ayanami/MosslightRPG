extends RefCounted
## Time-budgeted reveal: punctuation and authored per-span speed survive low FPS.
const PATH := "res://data/dialogue/presentation.json"
var characters_per_second := 48.0
var comma_pause := .08
var period_pause := .18
var characters := 0
var elapsed := 0.0
var arrivals: Array[float] = []
var finished := true
var _budget := 0.0
var _delay := 0.0
var _text := ""
var _speeds: Dictionary = {}

func start(text: String, line: RefCounted, voice := "clear") -> void:
	var data: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(PATH))
	var settings: Dictionary=data.default.duplicate()
	settings.merge(data.voices.get(voice,{}),true)
	characters_per_second=float(settings.characters_per_second)
	comma_pause=float(settings.comma_pause)
	period_pause=float(settings.period_pause)
	# Dialogue Manager strips tags from visible text; directors can tune each line.
	for tag in line.tags:
		if tag.begins_with("pace="): characters_per_second=clampf(float(tag.trim_prefix("pace=")),1,180)
		elif tag.begins_with("pause="): period_pause=clampf(float(tag.trim_prefix("pause=")),0,2)
	_text=text
	_speeds=line.speeds.duplicate()
	characters=0
	elapsed=0
	_budget=0
	_delay=0
	arrivals.clear()
	finished=text.is_empty()

func tick(delta: float) -> void:
	elapsed+=maxf(0,delta)
	if finished: return
	_budget+=maxf(0,delta)
	while characters<_text.length() and _budget>=_delay:
		_budget-=_delay
		arrivals.append(elapsed-_budget)
		var letter:=_text[characters]
		characters+=1
		var speed:=1.0
		for index in _speeds:
			if int(index)<=characters: speed=maxf(.05,float(_speeds[index]))
		_delay=1.0/(characters_per_second*speed)
		if letter in "，、,；;：:": _delay+=comma_pause
		elif letter in "。！？.!?…": _delay+=period_pause
	finished=characters>=_text.length()

func finish() -> void:
	while arrivals.size()<_text.length(): arrivals.append(elapsed-.1)
	characters=_text.length()
	finished=true
