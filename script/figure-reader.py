# Prepares burning_barb's CC0 Prototyping Mannequin for Tall Stack: applies its mirror, lowers
# its arms from the T-pose about the shoulders, colors it like a wooden artist's mannequin, splits
# the head into its own `head` mesh, which the app finds to hold the reader's photo in front of,
# and exports USDZ.
# Usage: blender -b mannequin.blend --python script/figure-reader.py -- <arm angle> <output.usdz>
import bpy, bmesh, math, sys
from mathutils import Matrix, Vector

args = sys.argv[sys.argv.index('--') + 1:]
ANGLE = math.radians(float(args[0]))
out = args[1]

for o in list(bpy.data.objects):
    if o.type != 'MESH':
        continue
    ev = o.evaluated_get(bpy.context.evaluated_depsgraph_get())
    me = bpy.data.meshes.new_from_object(ev)
    o.modifiers.clear()
    o.data = me
    o.data.transform(o.matrix_world)
    o.matrix_world = Matrix.Identity(4)
    bm = bmesh.new(); bm.from_mesh(o.data); seen = set()
    for v in bm.verts:
        if v.index in seen:
            continue
        comp = []; st = [v]
        while st:
            x = st.pop()
            if x.index in seen:
                continue
            seen.add(x.index); comp.append(x); st += [e.other_vert(x) for e in x.link_edges]
        xs = [c.co.x for c in comp]; zs = [c.co.z for c in comp]
        if min(zs) < 1.25:
            continue
        side = 1 if min(xs) >= 0.138 else (-1 if max(xs) <= -0.138 else 0)
        if not side:
            continue
        pivot = Vector((0.178 * side, -0.036, 1.338))
        R = Matrix.Rotation(ANGLE * side, 3, 'Y')
        for c in comp:
            c.co = pivot + R @ (c.co - pivot)
    bm.to_mesh(o.data); bm.free()

def recolor(name, rgb, rough):
    m = bpy.data.materials[name]
    n = next(n for n in m.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
    for link in [l for l in m.node_tree.links if l.to_node == n]:
        m.node_tree.links.remove(link)
    n.inputs['Base Color'].default_value = (*rgb, 1)
    n.inputs['Roughness'].default_value = rough
    n.inputs['Metallic'].default_value = 0

recolor('body_mat', (0.62, 0.42, 0.24), 0.55)
recolor('joint_mat', (0.22, 0.14, 0.09), 0.5)

body = bpy.data.objects['mannequin_body']
head_me = body.data.copy()
head = bpy.data.objects.new('head', head_me)
bpy.context.scene.collection.objects.link(head)

def keep(obj, want_head):
    bm = bmesh.new(); bm.from_mesh(obj.data)
    drop = [f for f in bm.faces if (min(v.co.z for v in f.verts) >= 1.46) != want_head]
    bmesh.ops.delete(bm, geom=drop, context='FACES')
    bm.to_mesh(obj.data); bm.free()

keep(body, False)
keep(head, True)
bpy.data.objects.remove(bpy.data.objects['mannequin_center'])
bpy.ops.wm.usd_export(
    filepath=out, export_materials=True, selected_objects_only=False,
    convert_world_material=False, export_lights=False, convert_orientation=True, export_global_up_selection='Y',
    export_global_forward_selection='NEGATIVE_Z')
