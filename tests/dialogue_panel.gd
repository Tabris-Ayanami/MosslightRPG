extends SceneTree
## Real Dialogue Manager, native controls, paused input, and stale-await regression.
const DialogueUI=preload("res://rpg/dialogue_panel.gd")
const Line=preload("res://addons/dialogue_manager/dialogue_line.gd")
const Response=preload("res://addons/dialogue_manager/dialogue_response.gd")
const MenuForTest=preload("res://rpg/world_action_menu.gd")
var checks := 0
var failures: Array[String] = []

class Bridge extends RefCounted:
	var accepted := ""
	func accept(value: String) -> void: accepted = value

class Gate extends RefCounted:
	signal resolved(value: Variant)

class DelayedResource extends Resource:
	var gates: Array = []
	var requests: Array[String] = []
	func get_next_dialogue_line(title: String, _states: Array) -> Variant:
		requests.append(title)
		var gate := Gate.new()
		gates.append(gate)
		return await gate.resolved

func _initialize() -> void: call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func ticks(count := 3) -> void:
	for index in range(count): await process_frame

func key(code: Key, echo := false) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	event.echo = echo
	Input.parse_input_event(event)
	var release := InputEventKey.new()
	release.physical_keycode = code
	release.keycode = code
	Input.parse_input_event(release)

func click(control: Control) -> void:
	var at: Vector2 = root.get_final_transform() * control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	Input.parse_input_event(motion)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.global_position = at
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		await ticks(1)

func line(text: String, next_id := "END") -> RefCounted:
	var result := Line.new()
	result.id = text
	result.character = "守望人·艾琳"
	result.text = text
	result.next_id = next_id
	return result

func shot(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://docs/dialogue-ui")
	DirAccess.make_dir_recursive_absolute(directory)
	root.get_texture().get_image().save_png(directory.path_join(name + ".png"))

func run() -> void:
	root.size=Vector2i(1280,720)
	var host:=Node.new()
	root.add_child(host)
	var panel:=DialogueUI.new()
	host.add_child(panel)
	panel.setup(host)
	var signals: Dictionary={"opened":0,"closed":0}
	panel.opened.connect(func(): signals.opened+=1)
	panel.closed.connect(func(): signals.closed+=1)
	var bridge:=Bridge.new()
	var manager: Node=Engine.get_singleton("DialogueManager")
	var resource: Resource=manager.create_resource_from_text("~ start\n守望人·艾琳: 风穿过风铃村，旅人，欢迎回来。\n守望人·艾琳: 愿意替村子巡视林间的路吗？\n- 我去看看。\n\tdo accept(\"patrol\")\n\t守望人·艾琳: 谢谢。小心那些举着盾的士兵。\n- 我还需要准备一下。\n\tdo accept(\"later\")\n\t守望人·艾琳: 村子会等你。\n=> END")
	check(not panel.start(Resource.new(),bridge),"invalid resources cannot open the conversation")
	check(not panel.is_open() and not panel.visible and signals.opened==0,"rejected starts have no modal side effects")
	check(panel.start(resource,bridge),"valid conversation opens synchronously")
	check(not panel.start(resource,bridge),"open conversation cannot be accidentally replaced")
	await ticks(6)
	check(panel.speaker.text=="守望人·艾琳" and panel.body.get_parsed_text().contains("欢迎回来"),"real Dialogue Manager supplies speaker and body")
	check(not panel._typing.finished and panel.body.visible_characters<panel.body.get_total_character_count(),"speech reveals characters progressively")
	var before: int=panel.body.visible_characters
	key(KEY_F,true)
	await ticks(1)
	check(panel.dialogue_line.text.contains("欢迎回来"),"key echo cannot advance dialogue")
	key(KEY_F)
	await ticks(2)
	check(panel._typing.finished and panel.dialogue_line.text.contains("欢迎回来"),"first F completes typing without skipping the line")
	key(KEY_F)
	await ticks(6)
	check(panel._response_ids.size()==2,"second F advances to the actual branching line")
	check(not panel.choice_bubble.visible,"choice bubble waits until the speaker has finished")
	key(KEY_F)
	await ticks(3)
	check(panel._typing.finished and bridge.accepted.is_empty(),"finishing a branching line does not accidentally choose an answer")
	panel._process(.3)
	check(panel.choice_bubble.visible and panel.menu.get_parent()==panel.choice_bubble,"responses live in the separate player bubble")
	key(KEY_SPACE)
	await ticks(1)
	check(bridge.accepted.is_empty(),"space cannot accidentally select a response")
	key(KEY_DOWN)
	await ticks(2)
	check(panel.menu.selected==1,"arrow navigation changes the F-row response")
	key(KEY_F)
	await ticks(6)
	check(bridge.accepted=="later" and panel.body.get_parsed_text().contains("村子会等你"),"F commits the selected real dialogue mutation exactly once")
	key(KEY_F)
	await ticks(2)
	key(KEY_F)
	await ticks(6)
	check(not panel.is_open() and signals.closed==1,"end of conversation closes exactly once")
	check(panel.dialogue_line==null and panel.dialogue_resource==null and panel._bridge==null and panel.body.text.is_empty(),"close releases all owned dialogue state")
	panel.close()
	check(signals.closed==1,"close is idempotent")
	paused=true
	bridge.accepted=""
	check(panel.start(resource,bridge),"conversation reopens while the world is paused")
	await ticks(6)
	key(KEY_F)
	await ticks(2)
	key(KEY_F)
	await ticks(6)
	key(KEY_F)
	await ticks(3)
	panel._process(.3)
	# Native left click on the central wooden badge selects the player answer.
	var at: Vector2=panel.menu.get_global_transform()*panel.menu.BADGE
	var motion:=InputEventMouseMotion.new()
	motion.position=root.get_final_transform()*at
	motion.global_position=motion.position
	Input.parse_input_event(motion)
	for down in [true,false]:
		var event:=InputEventMouseButton.new()
		event.position=root.get_final_transform()*at
		event.global_position=event.position
		event.button_index=MOUSE_BUTTON_LEFT
		event.pressed=down
		Input.parse_input_event(event)
		await ticks(1)
	await ticks(6)
	check(bridge.accepted=="patrol","native left click confirms the choice while paused")
	var standalone_menu:=MenuForTest.new()
	root.add_child(standalone_menu)
	standalone_menu.set_entries([{"id":"first","label":"一"},{"id":"second","label":"二"},{"id":"third","label":"三"}])
	standalone_menu.expanded=1
	var chosen: Array[String]=[]
	standalone_menu.activated.connect(func(id: String): chosen.append(id))
	var click_row:=InputEventMouseButton.new()
	click_row.position=Vector2(100,standalone_menu.BADGE.y+standalone_menu.ROW)
	click_row.button_index=MOUSE_BUTTON_LEFT
	click_row.pressed=true
	standalone_menu.handle_pointer(click_row)
	check(chosen==["second"],"a single left click on an adjacent option selects and confirms it")
	standalone_menu.queue_free()
	key(KEY_ESCAPE)
	await ticks(2)
	check(not panel.is_open() and paused,"Escape closes without stealing host ownership of pause")
	paused=false
	var delayed:=DelayedResource.new()
	panel.start(delayed,bridge,"first")
	await ticks(3)
	key(KEY_F)
	key(KEY_ENTER)
	await ticks(2)
	check(delayed.requests==["first"],"input while awaiting cannot duplicate a dialogue request")
	delayed.gates[0].resolved.emit(line("等待之后的第一句","second"))
	await ticks(3)
	panel._typing.finish()
	key(KEY_ENTER)
	key(KEY_ENTER)
	await ticks(2)
	check(delayed.requests==["first","second"],"rapid advance presses start only one asynchronous request")
	panel.close()
	panel.start(delayed,bridge,"replacement")
	await ticks(3)
	delayed.gates[1].resolved.emit(line("旧对话的迟到结果"))
	await ticks(2)
	check(panel.body.get_parsed_text()=="稍候……","stale result cannot overwrite a new conversation")
	delayed.gates[2].resolved.emit(line("新对话的当前内容"))
	await ticks(2)
	check(panel.body.get_parsed_text()=="新对话的当前内容","current async result still displays normally")
	panel.close()
	panel.start(delayed,bridge,"closed")
	await ticks(3)
	panel.close()
	delayed.gates[3].resolved.emit(line("已经关闭"))
	await ticks(2)
	check(not panel.visible and panel.dialogue_line==null,"late result cannot reopen a closed bubble")
	var large:=line("风铃村的故事，需要每一位旅人慢慢读完。".repeat(30))
	for i in range(10):
		var response:=Response.new()
		response.text="回答 %d"%i
		response.next_id="result_%d"%i
		response.is_allowed=i!=0
		large.responses.append(response)
	for resolution in [Vector2i(960,540),Vector2i(1280,720),Vector2i(1920,1080)]:
		root.size=resolution
		panel.start(delayed,bridge,"size")
		await ticks(3)
		delayed.gates.back().resolved.emit(large)
		await ticks(4)
		panel._typing.finish()
		panel._process(.3)
		check(Rect2(Vector2.ZERO,root.get_visible_rect().size).encloses(panel.paper.get_global_rect()),"speaker bubble fits viewport at %s"%resolution)
		check(panel.menu.visible_indices().size()<=3 and panel.body.scroll_active,"long speech and many responses have bounded presentation")
		check(panel.menu.selected==1 and not panel.menu.entries[0].enabled,"disabled answers remain unavailable and default selection skips them")
		key(KEY_UP)
		await ticks(2)
		check(panel.menu.selected==9,"keyboard selection wraps past unavailable answers")
		panel.close()
	var Reveal=load("res://rpg/dialogue_reveal.gd")
	var timing:=line("风起，听……我们走吧。")
	timing.tags=PackedStringArray(["pace=30","pause=0.24"])
	timing.speeds={4:2.0,7:1.0}
	var slow=Reveal.new()
	var fast=Reveal.new()
	slow.start(timing.text,timing,"clear")
	fast.start(timing.text,timing,"clear")
	for i in range(15): slow.tick(1.0/30)
	for i in range(60): fast.tick(1.0/120)
	check(slow.characters==fast.characters,"punctuation and speed timing agree at 30 and 120 FPS")
	check(slow.characters_per_second==30 and slow.period_pause==.24,"per-line pacing overrides the reusable voice profile")
	var plain=Reveal.new()
	plain.start("风起听我们走吧",line("风起听我们走吧"),"clear")
	plain.tick(.18)
	var punctuation=Reveal.new()
	punctuation.start("风，起听我们走吧",line("风，起听我们走吧"),"clear")
	punctuation.tick(.18)
	check(punctuation.characters<plain.characters,"punctuation adds an audible-speech-like pause")
	var Skins=load("res://rpg/dialogue_skins.gd")
	for id in ["villager_bubble","player_bubble","demon_bubble","king_bubble"]:
		check(Skins.all().has(id),"stable skin ID is available: "+id)
	check(Skins.resolve("unknown")==Skins.resolve("villager_bubble"),"unknown skin IDs fall back safely")
	check(Skins.font().has_char("桐".unicode_at(0)) and Skins.font().has_char("窃".unicode_at(0)),"pixel font covers the required Chinese dialogue glyphs")
	var weak_bridge: WeakRef=weakref(bridge)
	var weak_resource: WeakRef=weakref(resource)
	bridge=null
	resource=null
	large=null
	delayed=null
	await ticks(5)
	check(weak_bridge.get_ref()==null and weak_resource.get_ref()==null,"completed dialogue does not retain bridge or resource")
	host.queue_free()
	await ticks(5)
	print("DIALOGUE_PANEL %d/%d passed"%[checks-failures.size(),checks])
	quit(0 if failures.is_empty() else 1)
