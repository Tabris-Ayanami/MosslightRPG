@static_unload
extends RefCounted
## Shared transparent colored-pencil plates; retain full-resolution source artwork.
const KINDS: PackedStringArray=["sword","bow","apple","potion","leaf","crystal-amber","pear","flower","wood","stone","mushroom","scroll","feather","crystal-blue","shell","coat","ring","boot"]
static var textures: Dictionary={}

static func texture(kind: String,tint: Color) -> Texture2D:
	var id := kind
	if kind=="crystal": id="crystal-blue" if tint.b>tint.r else "crystal-amber"
	if not id in KINDS: return null
	if textures.has(id): return textures[id]
	var path := "res://assets/ui/items/pencil/"+id+".png"
	if not ResourceLoader.exists(path): return null
	var source: Texture2D=load(path)
	var bounds := source.get_image().get_used_rect()
	if not bounds.has_area(): return null
	var plate := AtlasTexture.new()
	plate.atlas=source
	plate.region=Rect2(bounds)
	plate.filter_clip=true
	textures[id]=plate
	return plate

static func draw(c: CanvasItem,kind: String,center: Vector2,radius: float,tint: Color) -> bool:
	var plate := texture(kind,tint)
	if not plate: return false
	var extent := Vector2(plate.get_size())
	extent*=radius*2.0/maxf(extent.x,extent.y)
	c.draw_texture_rect(plate,Rect2(center-extent*.5,extent),false)
	return true
