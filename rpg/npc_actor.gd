extends "res://combat/combat_actor.gd"
## Neutral villagers and hostile villagers use the same animated combat actor.
const FONT = preload("res://assets/ui/fonts/NotoSansSC.ttf")
var host: Node
var marker: Label3D
var hostile := false
var _social_defeated := false
var clock := 0.0
var rest_facing := Vector3.BACK

func configure(owner_game: Node, data: Dictionary) -> void:
	host=owner_game
	arena=host.combat_world
	sandbox_mode=false
	definition=UnitDefinition.for_player()
	definition.merge(data.duplicate(true),true)
	enemy_id=str(data.id)
	definition.faction_id="villager."+str(data.id)
	definition.level=1
	definition.stats={"STR":8,"DEX":8,"CON":8,"INT":8,"PER":10,"CHA":10}
	definition.resource_profile={"HP":300.0,"Stamina":3.0,"Poise":55.0}
	definition.body={"radius":.3,"height":1.5,"scale":Vector3.ONE}
	definition.visual={"kind":"procedural","color":"#"+str(data.get("palette",{}).get("cloak","526f65")),"scale":1.0,"animation_family":"UNARMED"}
	definition.movement.speed=2.5
	definition.ai={"aggro_range":8.0,"attack_cooldown":1.8,"grab_every":0}
	definition.combat.damage=28.0
	definition.combat.range=1.5
	var direction: Array=data.get("facing",[0.0,0.0,1.0])
	rest_facing=Vector3(direction[0],0,direction[2]).normalized()
	facing=rest_facing

func _ready() -> void:
	super._ready()
	set_control_mode("none")
	add_to_group("interactables")
	add_to_group("narrative_npcs")
	marker=Label3D.new()
	marker.name="QuestMarker"
	marker.font=FONT
	marker.font_size=64
	marker.outline_size=8
	marker.pixel_size=.009
	marker.position.y=2.10
	marker.modulate=Color("edcc85")
	marker.outline_modulate=Color("343f39")
	marker.billboard=BaseMaterial3D.BILLBOARD_ENABLED
	add_child(marker)
	host.quests.changed.connect(_update_marker)
	combat.died.connect(func(): host.interactions.npc_defeated(self))
	_update_marker()
	_ground.call_deferred()

func _ground() -> void:
	await get_tree().physics_frame
	if not is_inside_tree(): return
	var query:=PhysicsRayQueryParameters3D.create(global_position+Vector3.UP*6,global_position-Vector3.UP*10,1,[get_rid()])
	var hit:=get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty(): global_position.y=hit.position.y+.015
	spawn_point=global_position

func _process(delta: float) -> void:
	clock+=delta
	if not hostile and not dead:
		var observer: Node=host.controlled_actor()
		var direction: Vector3=observer.global_position-global_position
		direction.y=0
		var target:=rest_facing if direction.length()>4 or direction.length()<.1 else direction.normalized()
		facing=facing.lerp(target,1-exp(-delta*4)).normalized()
	marker.position.y=2.1+sin(clock*2)*.035

func social_id() -> String:
	return "interaction.npc."+str(definition.id)

func is_essential() -> bool:
	return definition.get("essential",false)==true

func apply_social_state(record: Dictionary) -> void:
	var next_hostile: bool=record.get("hostile",false)
	var next_defeated: bool=record.get("defeated",false)
	if hostile!=next_hostile or _social_defeated!=next_defeated:
		hostile=next_hostile
		_social_defeated=next_defeated
		arena.set_faction_relation(faction_id,host.player.faction_id,hostile)
		if next_defeated:
			set_control_mode("none")
			combat.state="DEAD"
			combat.in_combat=false
			resources.pools["HP"]["current"]=0.0
			# A defeated story NPC is wounded, not removed. Bring them back to
			# the authored village position, even after a fight in a river.
			if is_essential(): global_position=spawn_point
			refresh_collision_layer()
		else:
			# Reconciliation also cancels a living villager's pending attack and
			# damage statuses. Never reset the player or their combat timeout.
			if dead or not hostile:
				combat.reset()
				animation.visible=true
				if is_essential(): global_position=spawn_point
			set_control_mode("ai" if hostile else "none")
			ai_cooldown=.7
		refresh_collision_layer()
	_update_marker()

func refresh_collision_layer() -> void:
	super.refresh_collision_layer()
	# Preserve the village's solid bystanders. Hostiles use the normal combat
	# layer so terrain-only sight rays do not mistake their target for a wall.
	if not dead and not hostile: collision_layer |= 1

func _update_marker() -> void:
	if not is_instance_valid(marker): return
	if hostile or dead:
		marker.text="援" if dead else "和"
		marker.visible=is_essential()
		return
	if not str(definition.get("shop_id","")).is_empty():
		marker.text="商"
		marker.show()
		return
	var available:=false
	var ready:=false
	for id in definition.get("quests",[]):
		var state: String=host.quests.status(id)
		ready=ready or state=="ready"
		available=available or state=="available"
	marker.text="?" if ready else "!"
	marker.visible=ready or available

func prompt(_game: Node) -> String:
	if is_essential() and (hostile or dead):
		return ("F 救助并致歉 · " if dead else "F 认错和解 · ")+display_name
	return "F 交谈 · "+display_name

func interact(game: Node) -> void:
	if game==host:
		var action: String="reconcile" if is_essential() and (hostile or dead) else ("trade" if not str(definition.get("shop_id","")).is_empty() else "talk")
		host.interactions.execute(self,action)

func _exit_tree() -> void:
	if is_instance_valid(host) and host.quests!=null and host.quests.changed.is_connected(_update_marker): host.quests.changed.disconnect(_update_marker)
