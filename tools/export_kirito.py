"""Build the local Godot character from the user's extracted source and repaired rig.
Run with Blender --background --python tools/export_kirito.py.
Original assets are read-only. No Blender installation is needed to play the game.
"""
import bpy, math, json
from pathlib import Path
from mathutils import Matrix, Vector, Euler

PROJECT = Path(__file__).resolve().parents[1]
SOURCE = Path('F:/demo/crpg/SourceAssets/ThirdParty/KiritoPackage/reference/Assets/SubspaceHunter/Model/桐人')
RIG_SOURCE = Path('F:/demo/crpg/SourceAssets/Characters/LowPoly/Kirito_LowPoly.blend')
OUT = PROJECT / 'assets/characters/kirito'
OUT.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(RIG_SOURCE), load_ui=False)
rig = bpy.data.objects['KiritoHumanoid']
palms = [bpy.data.objects['KiritoPalm_L'], bpy.data.objects['KiritoPalm_R']]
keep = [rig] + palms
for o in list(bpy.data.objects):
    if o not in keep:
        bpy.data.objects.remove(o, do_unlink=True)
rig.name = 'KiritoRig'
rig.animation_data_clear()
for p in rig.pose.bones:
    p.matrix_basis = Matrix.Identity(4)
before = set(bpy.data.objects)
bpy.ops.import_scene.fbx(filepath=str(SOURCE / 'kirito2.fbx'), use_anim=False)
added = set(bpy.data.objects) - before
meshes = [o for o in added if o.type=='MESH' and o.name in ('body_low','polySurface84','tou6_low','tou_fa_low')]
for o in meshes:
    world = o.matrix_world.copy()
    o.parent = None
    o.matrix_world = Matrix.Identity(4)
    o.data.transform(world, shape_keys=True)
    o.modifiers.clear()
    o.parent = rig
    o.matrix_parent_inverse = Matrix.Identity(4)
    mod = o.modifiers.new('KiritoSkin','ARMATURE')
    mod.object = rig
    for v in o.data.vertices:
        valid = [(g.group,g.weight) for g in v.groups if o.vertex_groups[g.group].name in rig.data.bones]
        total = sum(w for _,w in valid)
        if total>0:
            for idx,w in valid: o.vertex_groups[idx].add([v.index],w/total,'REPLACE')
    for g in list(o.vertex_groups):
        if g.name not in rig.data.bones: o.vertex_groups.remove(g)
for o in added:
    if o not in meshes: bpy.data.objects.remove(o,do_unlink=True)

texture_names = {'shen_ti':'shen_ti_basecolor.png','fushi1':'bake_fushi1_albedometal.png','fu_shi2':'bake_fu_shi2_albedometal.png','tou':'tou_2D_View.png','hair':'hair_2D_View.png'}
materials = {}
for label, filename in texture_names.items():
    mat = bpy.data.materials.new('Kirito_'+label)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Roughness'].default_value = .95
    tex = mat.node_tree.nodes.new('ShaderNodeTexImage')
    tex.image = bpy.data.images.load(str(SOURCE/filename),check_existing=True)
    mat.node_tree.links.new(tex.outputs['Color'],bsdf.inputs['Base Color'])
    # The source albedometal alpha stores metalness, not transparency.
    # Hair cards have a real alpha mask; the body and coat must stay opaque.
    if label=='hair':
        mat.node_tree.links.new(tex.outputs['Alpha'],bsdf.inputs['Alpha'])
        mat.surface_render_method = 'DITHERED'
    mat.use_backface_culling = False
    materials[label]=mat
for o in meshes:
    for slot in o.material_slots:
        label=slot.material.name.split('.')[0]
        slot.material=materials[label]
skin=bpy.data.materials.new('Kirito_gloves')
skin.diffuse_color=(.16,.19,.23,1)
for palm in palms:
    world = palm.matrix_world.copy()
    palm.parent = rig
    palm.matrix_world = world
    palm.data.materials.clear()
    palm.data.materials.append(skin)

FPS=30
bpy.context.scene.render.fps=FPS
def rotate(name,x=0,y=0,z=0):
    p=rig.pose.bones.get(name)
    if p is None: return
    basis=p.bone.matrix_local.to_quaternion()
    q=Euler(tuple(math.radians(v) for v in (x,y,z)),'XYZ').to_quaternion()
    p.rotation_mode='QUATERNION'
    p.rotation_quaternion=basis.inverted() @ q @ basis

def pose(kind,t):
    for p in rig.pose.bones:
        p.matrix_basis=Matrix.Identity(4)
        p.rotation_mode='QUATERNION'
    wave=math.sin(t*math.tau)
    rotate('J_Bip_L_UpperArm',0,69,-5)
    rotate('J_Bip_R_UpperArm',0,-69,5)
    rotate('J_Bip_L_LowerArm',-12)
    rotate('J_Bip_R_LowerArm',-12)
    rotate('J_Bip_C_Chest',wave*.8)
    if kind=='Run':
        rotate('J_Bip_L_UpperLeg',wave*34)
        rotate('J_Bip_R_UpperLeg',-wave*34)
        rotate('J_Bip_L_LowerLeg',max(0,-wave)*58+5)
        rotate('J_Bip_R_LowerLeg',max(0,wave)*58+5)
        rotate('J_Bip_L_UpperArm',-wave*27,65,-9)
        rotate('J_Bip_R_UpperArm',wave*27,-65,9)
        rotate('J_Bip_L_LowerArm',-42)
        rotate('J_Bip_R_LowerArm',-42)
        rotate('J_Bip_C_Chest',8,0,wave*4)
    elif kind in ('Jump','Roll'):
        rotate('J_Bip_L_UpperLeg',-38 if kind=='Roll' else -20)
        rotate('J_Bip_R_UpperLeg',-50 if kind=='Roll' else 18)
        rotate('J_Bip_L_LowerLeg',85 if kind=='Roll' else 40)
        rotate('J_Bip_R_LowerLeg',95 if kind=='Roll' else 55)
        rotate('J_Bip_L_UpperArm',-20,48,-25)
        rotate('J_Bip_R_UpperArm',-20,-48,25)
        rotate('J_Bip_C_Chest',25 if kind=='Roll' else 10)
    elif kind in ('Bow','BowRelease'):
        rotate('J_Bip_L_UpperArm',8,5,-82)
        rotate('J_Bip_L_LowerArm',0,0,-7)
        rotate('J_Bip_R_UpperArm',0,-15,20)
        rotate('J_Bip_R_LowerArm',0,0,110 if kind=='Bow' else 90)
        rotate('J_Bip_C_Chest',0,0,-12)
    elif kind in ('Slash','Heavy','HoldSword'):
        a=math.sin(math.pi*min(t*1.15,1)) if kind!='HoldSword' else 0
        heavy=kind=='Heavy'
        rotate('J_Bip_R_UpperArm',-55+a*105, -25-a*40, -40+a*120)
        rotate('J_Bip_R_LowerArm',-60+a*45)
        rotate('J_Bip_L_UpperArm',-12,52,-18)
        rotate('J_Bip_C_Chest',(-12+a*28) if heavy else 3,0,-20+a*42)
    elif kind=='Heal':
        rotate('J_Bip_L_UpperArm',-28,35,-25)
        rotate('J_Bip_R_UpperArm',-28,-35,25)
    # Subtle coat movement, keyed on the original cloth chain rather than rigid bobbing.
    for p in rig.pose.bones:
        if 'skirt' in p.name.lower():
            rotate(p.name,math.sin(t*math.tau+p.bone.head_local.x*4)*(5 if kind=='Run' else 1.2))

clips={'Idle':60,'Run':22,'Jump':30,'Roll':12,'Slash':12,'Heavy':20,'HoldSword':30,'Bow':30,'BowRelease':10,'Heal':30}
rig.animation_data_create()
for kind, count in clips.items():
    action=bpy.data.actions.new(kind)
    rig.animation_data.action=action
    for f in range(count+1):
        pose(kind,f/count)
        for p in rig.pose.bones:
            p.keyframe_insert('rotation_quaternion',frame=f+1,group=p.name)
    action.use_fake_user=True
rig.animation_data.action=bpy.data.actions['Idle']
bpy.context.scene.frame_set(1)
bpy.ops.object.select_all(action='DESELECT')
for o in [rig]+palms+meshes: o.select_set(True)
bpy.context.view_layer.objects.active=rig
bpy.context.scene.frame_start=1
bpy.context.scene.frame_end=61
bpy.ops.export_scene.gltf(filepath=str(OUT/'kirito.glb'),export_format='GLB',use_selection=True,export_yup=True,export_animations=True,export_animation_mode='ACTIONS',export_anim_single_armature=True,export_force_sampling=True,export_skins=True,export_def_bones=True,export_morph=False,export_materials='EXPORT')
(OUT/'source.json').write_text(json.dumps({'model':str(SOURCE/'kirito2.fbx'),'rig':str(RIG_SOURCE),'textures':texture_names,'animations':'Locally authored prototype skeletal clips; not original SAO animations.','source_license':'User-provided third-party source. Redistribution terms not verified.','triangles':sum(len(p.vertices)-2 for o in meshes+palms for p in o.data.polygons)},ensure_ascii=False,indent=2),encoding='utf8')
print('KIRITO_EXPORTED',OUT/'kirito.glb')
