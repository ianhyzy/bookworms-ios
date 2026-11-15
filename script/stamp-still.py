# Bakes the wooden desk stamp that comes down on the Top Five tag (`StampFall`): a still of the
# stamp (`StampStill`) and its shadow on the paper with the stamp touching the paper
# (`StampShadowNear`) and lifted (`StampShadowFar`), all seen from in front and a little above
# through a long lens, so the flat details page and the stamp share one view. Then it prints the
# rubber face's corners and each shadow's frame, in the still's pixels, for `StampFall`.
#
# The model is "Wood Stamp 4" by necmettinturkan (see README-AI.md's Credits). Download its USDZ
# and run, from the repository root:
#
#     blender -b --factory-startup -P script/stamp-still.py -- <path to Wood_Stamp_4.usdz>
#
# The model's varnish, rubber, and brass are glossy, so the bake roughens them and lowers their
# specular reflections, to read as worn wood and rubber. Its textures stay at full size, since
# only the still ships.
import json
import math
import os
import subprocess
import sys
import tempfile

import bpy
import numpy as np
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector

source = sys.argv[sys.argv.index("--") + 1]
assets = "Bookworms/Assets.xcassets"
# The still's width in pixels: about the rubber face's width on an iPhone's screen at three
# pixels per point, with room for larger text.
stillWidth = 1000
# The camera's height above the paper, in degrees. At this angle the rubber face's outline on
# the paper is about as wide for its height as the stamp's printed label.
elevation = math.radians(27)
# How far the far shadow's stamp is lifted, in the model's units: about a third of its height.
farLift = 1.0

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(filepath=source)
scene = bpy.context.scene
parts = [o for o in scene.objects if o.type == "MESH"]
rubber = next(o for o in parts if o.parent.name.startswith("stamp_alt_tabla"))
root = parts[0]
while root.parent:
    root = root.parent


def bounds(objects):
    points = [o.matrix_world @ Vector(c) for o in objects for c in o.bound_box]
    return (
        Vector([min(p[i] for p in points) for i in range(3)]),
        Vector([max(p[i] for p in points) for i in range(3)]),
    )


low, high = bounds(parts)
rubberLow, rubberHigh = bounds([rubber])
floor = rubberLow.z

# Worn varnish, rubber, and brass in place of the model's glossy finish. Materials are found by
# the model's names and by their nodes' types, since node names are localized.
for material in bpy.data.materials:
    bsdf = next(n for n in material.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Specular IOR Level"].default_value = 0.3
    if material.name == "Fine_wood":
        # The roughness texture runs from about 0.11 to 0.25.
        link = bsdf.inputs["Roughness"].links[0]
        remap = material.node_tree.nodes.new("ShaderNodeMapRange")
        remap.inputs["From Min"].default_value = 0.1
        remap.inputs["From Max"].default_value = 0.25
        remap.inputs["To Min"].default_value = 0.5
        remap.inputs["To Max"].default_value = 0.78
        material.node_tree.links.new(link.from_socket, remap.inputs["Value"])
        material.node_tree.links.new(remap.outputs["Result"], bsdf.inputs["Roughness"])
    elif material.name == "Material":
        # The brass ring, collar, and inlay, aged.
        bsdf.inputs["Base Color"].default_value = (0.42, 0.27, 0.09, 1)
        bsdf.inputs["Metallic"].default_value = 0.85
        bsdf.inputs["Roughness"].default_value = 0.42
    else:
        # The rubber.
        bsdf.inputs["Base Color"].default_value = (0.03, 0.026, 0.024, 1)
        bsdf.inputs["Metallic"].default_value = 0
        bsdf.inputs["Roughness"].default_value = 0.85

# Card stock under the stamp. Out of the still, it bounces warm light onto the stamp; in the
# shadows, it catches the stamp's shadow.
bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, floor))
paper = bpy.context.object
stock = bpy.data.materials.new("Paper")
stock.use_nodes = True
next(n for n in stock.node_tree.nodes if n.type == "BSDF_PRINCIPLED").inputs[
    "Base Color"
].default_value = (0.86, 0.77, 0.6, 1)
paper.data.materials.append(stock)

world = bpy.data.worlds.new("World")
world.use_nodes = True
background = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
background.inputs["Color"].default_value = (0.9, 0.85, 0.78, 1)
background.inputs["Strength"].default_value = 0.45
scene.world = world


def light(name, location, size, energy, color):
    data = bpy.data.lights.new(name, "AREA")
    data.size = size
    data.energy = energy
    data.color = color
    item = bpy.data.objects.new(name, data)
    item.location = location
    item.rotation_euler = (
        (Vector((0, 0, 1.2)) - Vector(location)).to_track_quat("-Z", "Y").to_euler()
    )
    scene.collection.objects.link(item)


# A warm lamp almost overhead, a little behind the stamp, so its shadow falls a little toward the
# viewer, as under the paper props (`SoftShadow`), and a soft fill from the viewer's side.
light("Lamp", (-1, 1.2, 10), 3, 1300, (1, 0.93, 0.84))
light("Fill", (2.5, -9, 4), 6, 500, (1, 0.96, 0.92))

camera = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
camera.data.lens = 135
camera.data.sensor_fit = "HORIZONTAL"
target = Vector((0, 0, (low.z + high.z) / 2))
camera.location = target + 60 * Vector((0, -math.cos(elevation), math.sin(elevation)))
camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
scene.collection.objects.link(camera)
scene.camera = camera

render = scene.render
render.engine = "CYCLES"
scene.cycles.samples = 256
scene.cycles.use_denoising = True
cycles = bpy.context.preferences.addons["cycles"].preferences
cycles.compute_device_type = "METAL"
cycles.get_devices()
for device in cycles.devices:
    device.use = device.type == "METAL"
scene.cycles.device = "GPU" if any(d.use for d in cycles.devices) else "CPU"
render.film_transparent = True
scene.view_settings.view_transform = "Standard"
render.image_settings.file_format = "PNG"
render.image_settings.color_mode = "RGBA"
render.image_settings.color_depth = "8"


def project(point):
    """`point` in the frame's pixels, from its top left."""
    p = world_to_camera_view(scene, camera, point)
    return Vector((p.x * render.resolution_x, (1 - p.y) * render.resolution_y))


# Frames the stamp in a square, `stillWidth` wide, with room for its shadows; the bake crops it.
render.resolution_x = render.resolution_y = 2 * stillWidth
bpy.context.view_layer.update()
corners = [project(o.matrix_world @ Vector(c)) for o in parts for c in o.bound_box]
span = max(p.x for p in corners) - min(p.x for p in corners)
camera.data.lens *= stillWidth / span
bpy.context.view_layer.update()
corners = [project(o.matrix_world @ Vector(c)) for o in parts for c in o.bound_box]
side = render.resolution_x
camera.data.shift_x = ((min(p.x for p in corners) + max(p.x for p in corners)) / 2 - side / 2) / side
camera.data.shift_y = -((min(p.y for p in corners) + max(p.y for p in corners)) / 2 - side / 2) / side
bpy.context.view_layer.update()

face = [
    project(Vector((x, y, floor)))
    for x, y in [
        (rubberLow.x, rubberHigh.y),
        (rubberHigh.x, rubberHigh.y),
        (rubberHigh.x, rubberLow.y),
        (rubberLow.x, rubberLow.y),
    ]
]
scratch = tempfile.mkdtemp()


def bake(name):
    render.filepath = os.path.join(scratch, name + ".png")
    bpy.ops.render.render(write_still=True)
    image = bpy.data.images.load(render.filepath)
    pixels = np.array(image.pixels[:], dtype=np.float32).reshape(
        image.size[1], image.size[0], 4
    )[::-1]
    bpy.data.images.remove(image)
    return pixels


def crop(pixels, threshold, pad):
    """The rectangle around the pixels whose alpha passes `threshold`, with `pad` pixels."""
    rows = np.where(pixels[..., 3].max(axis=1) > threshold)[0]
    columns = np.where(pixels[..., 3].max(axis=0) > threshold)[0]
    top, bottom = max(rows[0] - pad, 0), min(rows[-1] + 1 + pad, pixels.shape[0])
    left, right = max(columns[0] - pad, 0), min(columns[-1] + 1 + pad, pixels.shape[1])
    return left, top, right, bottom


def write(pixels, rect, imageset):
    left, top, right, bottom = rect
    part = np.ascontiguousarray(pixels[top:bottom, left:right][::-1])
    image = bpy.data.images.new(imageset, right - left, bottom - top, alpha=True)
    image.pixels.foreach_set(part.ravel())
    png = os.path.join(scratch, imageset + "-cropped.png")
    image.filepath_raw = png
    image.file_format = "PNG"
    image.save()
    folder = os.path.join(assets, imageset + ".imageset")
    os.makedirs(folder, exist_ok=True)
    # HEIF keeps the transparency at a fraction of a PNG's size.
    subprocess.run(
        ["sips", "-s", "format", "heic", "-s", "formatOptions", "80", png, "--out",
         os.path.join(folder, imageset + ".heic")],
        check=True, capture_output=True)
    with open(os.path.join(folder, "Contents.json"), "w") as contents:
        json.dump(
            {
                "images": [{"filename": imageset + ".heic", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
            },
            contents, indent=2)
        contents.write("\n")


paper.visible_camera = False
still = bake("stamp")
stillRect = crop(still, 1 / 255, 4)
write(still, stillRect, "StampStill")

# The shadows fall from the lamp alone: the sky and the fill would spread a faint shadow far
# across the paper.
paper.visible_camera = True
paper.is_shadow_catcher = True
for part in parts:
    part.visible_camera = False
background.inputs["Strength"].default_value = 0
bpy.data.objects["Fill"].hide_render = True
frames = {}
for imageset, lift in [("StampShadowNear", 0), ("StampShadowFar", farLift)]:
    root.location.z += lift
    shadow = bake(imageset)
    root.location.z -= lift
    rect = crop(shadow, 0.03, 2)
    write(shadow, rect, imageset)
    frames[imageset] = [rect[0] - stillRect[0], rect[1] - stillRect[1], rect[2] - rect[0],
                        rect[3] - rect[1]]

print("STILL", stillRect[2] - stillRect[0], stillRect[3] - stillRect[1])
print("FACE", [[round(float(p.x) - int(stillRect[0]), 1), round(float(p.y) - int(stillRect[1]), 1)] for p in face])
for imageset, frame in frames.items():
    print(imageset, [int(value) for value in frame])
