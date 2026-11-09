# Legacy procedural model. Production artwork and its prompts are described in energy-house-artwork.txt.
# Render to a scratch directory: do not overwrite the production energy-house assets.
# Renders the Energy card's house: an original cutaway of a two-storey house (its gable side open on the rooms), solar
# panels on a standing-seam roof, the inverter, battery and meter inside, and a utility pole with its wire, on a model
# base and a transparent background, so the same image sits on the web UI's light and dark cards. It also writes where
# the parts and the cables land in the image (`energy-house.json`), so the page draws its callouts and animated cables
# there, on the conduits the render shows.
#
#   blender -b -P Scripts/energy-house.py -- --out Sources/HomeswiftUI/Web [--samples 128] [--width 1600] [--battery 1|0]
#     [--night 0|1] [--format WEBP|PNG]
#
# writes energy-house.webp and .json (energy-house-no-battery.* with --battery 0, energy-house-night.webp and
# energy-house-no-battery-night.webp with --night 1: the night's layout is the day's).

import bpy, json, math, os, random, sys
import numpy
from mathutils import Matrix, Vector
from bpy_extras.object_utils import world_to_camera_view

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
def arg(name, default):
    return type(default)(args[args.index(name) + 1]) if name in args else default
OUT = os.path.abspath(arg("--out", "energy-house-out"))
SAMPLES = arg("--samples", 128)
WIDTH = arg("--width", 1600)
BATTERY = arg("--battery", 1) == 1
NIGHT = arg("--night", 0) == 1   # moonlight, the rooms and the garden lamps lit

# The house: 10 m by 7 m, two storeys, a 28° gable roof along x, walls 30 cm thick. Its +x side is cut away.
W, D, H = 10.0, 7.0, 5.6
T = 0.3
FLOOR = 2.8
PITCH = math.radians(28)
OVER = 0.45
RIDGE = H + D / 2 * math.tan(PITCH)
x0, x1, y0, y1 = -W / 2, W / 2, -D / 2, D / 2
CUT = 1.05   # the front wall ends here: the rooms right of it are open to the front and the side

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
collection = scene.collection

# Materials ----------------------------------------------------------------------------------------------------------------

def material(name, color, rough=0.5, metal=0.0, **extra):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    for key, value in extra.items():
        bsdf.inputs[key].default_value = value
    return mat

def noise_bump(mat, scale, strength):
    """A fine noise bump: render, concrete, fabric."""
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = scale
    noise.inputs["Detail"].default_value = 8
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = strength
    links.new(noise.outputs["Fac"], bump.inputs["Height"])
    links.new(bump.outputs["Normal"], nodes["Principled BSDF"].inputs["Normal"])
    return mat

def pattern(name, colors, mortar, width, height, mortar_size, axes="xy", rough=0.5, metal=0.0, bump=0.3, grain=0.0):
    """Bricks in world metres on two axes: planks, boards, a roof's seams. `grain` streaks them like wood."""
    mat = material(name, colors[0], rough, metal)
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    coords = nodes.new("ShaderNodeTexCoord")
    split = nodes.new("ShaderNodeSeparateXYZ")
    join = nodes.new("ShaderNodeCombineXYZ")
    links.new(coords.outputs["Object"], split.inputs["Vector"])
    links.new(split.outputs[axes[0].upper()], join.inputs["X"])
    links.new(split.outputs[axes[1].upper()], join.inputs["Y"])
    brick = nodes.new("ShaderNodeTexBrick")
    brick.offset = 0.5
    brick.inputs["Scale"].default_value = 1.0
    brick.inputs["Brick Width"].default_value = width
    brick.inputs["Row Height"].default_value = height
    brick.inputs["Mortar Size"].default_value = mortar_size
    brick.inputs["Mortar Smooth"].default_value = 0.3
    brick.inputs["Color1"].default_value = (*colors[0], 1)
    brick.inputs["Color2"].default_value = (*colors[1], 1)
    brick.inputs["Mortar"].default_value = (*mortar, 1)
    links.new(join.outputs["Vector"], brick.inputs["Vector"])
    color = brick.outputs["Color"]
    if grain:
        stretch = nodes.new("ShaderNodeVectorMath")
        stretch.operation = "MULTIPLY"
        stretch.inputs[1].default_value = (1.5, 40.0, 1.0) if height < width else (40.0, 1.5, 1.0)
        links.new(join.outputs["Vector"], stretch.inputs[0])
        noise = nodes.new("ShaderNodeTexNoise")
        noise.inputs["Scale"].default_value = 3.0
        noise.inputs["Detail"].default_value = 6
        links.new(stretch.outputs["Vector"], noise.inputs["Vector"])
        mix = nodes.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        mix.blend_type = "MULTIPLY"
        mix.inputs["Factor"].default_value = grain
        links.new(color, mix.inputs["A"])
        links.new(noise.outputs["Color"], mix.inputs["B"])
        color = mix.outputs["Result"]
    links.new(color, nodes["Principled BSDF"].inputs["Base Color"])
    bmp = nodes.new("ShaderNodeBump")
    bmp.inputs["Strength"].default_value = bump
    bmp.invert = True
    links.new(brick.outputs["Fac"], bmp.inputs["Height"])
    links.new(bmp.outputs["Normal"], nodes["Principled BSDF"].inputs["Normal"])
    return mat

render = noise_bump(material("Render", (0.86, 0.86, 0.84), 0.85), 180, 0.06)
plaster = noise_bump(material("Plaster", (0.74, 0.72, 0.68), 0.9), 120, 0.03)
section = material("Section", (0.95, 0.95, 0.94), 0.95)
plinth = noise_bump(material("Plinth", (0.16, 0.16, 0.17), 0.8), 120, 0.1)
frame = material("Frame", (0.07, 0.07, 0.08), 0.35)
alu = material("Aluminium", (0.75, 0.76, 0.78), 0.3, 1.0)
gutter = material("Gutter", (0.12, 0.12, 0.13), 0.35, 0.8)
base = noise_bump(material("Base", (0.62, 0.62, 0.6), 0.9), 50, 0.08)
paving = pattern("Paving", ((0.32, 0.32, 0.31), (0.29, 0.29, 0.28)), (0.18, 0.18, 0.18), 0.6, 0.6, 0.008, "xy", 0.85, bump=0.4)
roof_metal = pattern("Standing seam", ((0.07, 0.075, 0.08), (0.07, 0.075, 0.08)), (0.16, 0.17, 0.18), 0.5, 80.0, 0.012, "xy",
                     0.4, 0.7, bump=0.8)
floor_wood = pattern("Oak floor", ((0.55, 0.38, 0.22), (0.5, 0.34, 0.2)), (0.25, 0.16, 0.09), 1.4, 0.19, 0.004, "xy", 0.45,
                     bump=0.15, grain=0.35)
cladding = pattern("Larch cladding", ((0.6, 0.42, 0.25), (0.55, 0.38, 0.22)), (0.2, 0.13, 0.07), 0.14, 80.0, 0.006, "xz", 0.6,
                   bump=0.5, grain=0.4)
door_mat = material("Door", (0.07, 0.07, 0.08), 0.45)
white_box = material("Device", (0.93, 0.93, 0.92), 0.3)
graphite = material("Graphite", (0.16, 0.17, 0.18), 0.35)
screen_mat = material("Screen", (0.02, 0.02, 0.025), 0.08)
display = material("Display", (0.1, 0.5, 0.9), 0.3, **{"Emission Color": (0.2, 0.6, 1.0, 1), "Emission Strength": 3.0})
led = material("LED", (0.1, 0.9, 0.5), 0.3, **{"Emission Color": (0.1, 1.0, 0.55, 1), "Emission Strength": 6.0})
fabric = noise_bump(material("Fabric", (0.33, 0.36, 0.4), 0.95), 300, 0.2)
grass = noise_bump(material("Lawn", (0.1, 0.24, 0.05), 0.95), 400, 0.6)
nodes, links = grass.node_tree.nodes, grass.node_tree.links
mottle = nodes.new("ShaderNodeTexNoise")
mottle.inputs["Scale"].default_value = 1.2
mottle.inputs["Detail"].default_value = 6
ramp = nodes.new("ShaderNodeValToRGB")
ramp.color_ramp.elements[0].color = (0.06, 0.11, 0.045, 1)
ramp.color_ramp.elements[1].color = (0.1, 0.16, 0.07, 1)
links.new(mottle.outputs["Fac"], ramp.inputs["Fac"])
links.new(ramp.outputs["Color"], nodes["Principled BSDF"].inputs["Base Color"])
deck = pattern("Deck", ((0.42, 0.27, 0.15), (0.38, 0.24, 0.13)), (0.12, 0.08, 0.05), 1.8, 0.145, 0.006, "xy", 0.6, bump=0.4, grain=0.35)
leaves = [noise_bump(material(f"Leaves {i}", color, 0.8), 90, 1.0)
          for i, color in enumerate(((0.06, 0.15, 0.05), (0.09, 0.19, 0.07), (0.13, 0.2, 0.07), (0.1, 0.17, 0.06), (0.045, 0.1, 0.05)))]
bark = material("Bark", (0.18, 0.13, 0.09), 0.9)
planter_mat = material("Planter", (0.3, 0.3, 0.3), 0.8)
conduit = material("Conduit", (0.3, 0.31, 0.33), 0.5)
timber = material("Pole", (0.27, 0.2, 0.14), 0.8)
wire_mat = material("Wire", (0.03, 0.03, 0.03), 0.4)
porcelain = material("Insulator", (0.85, 0.85, 0.82), 0.2)

glass = material("Glass", (0.05, 0.07, 0.08), 0.02, **{"Coat Weight": 1.0, "Specular IOR Level": 0.9, "Transmission Weight": 0.0,
                  **({"Emission Color": (1.0, 0.72, 0.42, 1), "Emission Strength": 2.2} if NIGHT else {})})
# The television's static: white noise, glowing, a little blue.
tv_snow = material("Static", (0.5, 0.5, 0.5), 0.2)
nodes, links = tv_snow.node_tree.nodes, tv_snow.node_tree.links
snow = nodes.new("ShaderNodeTexWhiteNoise")
snow_coords = nodes.new("ShaderNodeTexCoord")
snow_scale = nodes.new("ShaderNodeVectorMath")
snow_scale.operation = "MULTIPLY"
snow_scale.inputs[1].default_value = (260.0, 260.0, 260.0)
links.new(snow_coords.outputs["Object"], snow_scale.inputs[0])
links.new(snow_scale.outputs["Vector"], snow.inputs["Vector"])
tint = nodes.new("ShaderNodeMix")
tint.data_type = "RGBA"
tint.blend_type = "MULTIPLY"
tint.inputs["Factor"].default_value = 1.0
tint.inputs["B"].default_value = (0.82, 0.9, 1.0, 1)
links.new(snow.outputs["Value"], tint.inputs["A"])
links.new(tint.outputs["Result"], nodes["Principled BSDF"].inputs["Base Color"])
links.new(tint.outputs["Result"], nodes["Principled BSDF"].inputs["Emission Color"])
nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 3.0 if NIGHT else 1.4

cells = material("Cells", (0.02, 0.04, 0.12), 0.12, **{"Coat Weight": 1.0, "Coat Roughness": 0.02})
nodes, links = cells.node_tree.nodes, cells.node_tree.links
coords = nodes.new("ShaderNodeTexCoord")
grid = nodes.new("ShaderNodeTexBrick")
grid.offset = 0.0
grid.inputs["Scale"].default_value = 1.0
grid.inputs["Mortar Size"].default_value = 0.004
grid.inputs["Brick Width"].default_value = 0.166
grid.inputs["Row Height"].default_value = 0.166
grid.inputs["Color1"].default_value = (0.02, 0.035, 0.11, 1)
grid.inputs["Color2"].default_value = (0.025, 0.045, 0.13, 1)
grid.inputs["Mortar"].default_value = (0.55, 0.58, 0.62, 1)
links.new(coords.outputs["UV"], grid.inputs["Vector"])
links.new(grid.outputs["Color"], nodes["Principled BSDF"].inputs["Base Color"])

# Geometry helpers -----------------------------------------------------------------------------------------------------------

def mesh_object(name, verts, faces, mats, uv=None):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    collection.objects.link(obj)
    for mat in mats if isinstance(mats, (list, tuple)) else [mats]:
        obj.data.materials.append(mat)
    if uv:
        layer = mesh.uv_layers.new()
        for loop in mesh.loops:
            layer.data[loop.index].uv = uv(mesh.vertices[loop.vertex_index].co)
    return obj

def box(name, center, size, mat, bevel=0.0):
    x, y, z = center
    sx, sy, sz = (s / 2 for s in size)
    verts = [(x + dx * sx, y + dy * sy, z + dz * sz) for dx in (-1, 1) for dy in (-1, 1) for dz in (-1, 1)]
    faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    obj = mesh_object(name, verts, faces, mat)
    if bevel:
        mod = obj.modifiers.new("Bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 2
    return obj

def span(name, lo, hi, mat, bevel=0.0):
    """A box from one corner to the other."""
    return box(name, tuple((a + b) / 2 for a, b in zip(lo, hi)), tuple(b - a for a, b in zip(lo, hi)), mat, bevel)

def prism_x(name, profile, xa, xb, mat):
    """A solid along x from a (y, z) outline: a gable wall."""
    n = len(profile)
    verts = [(xa, y, z) for y, z in profile] + [(xb, y, z) for y, z in profile]
    faces = [tuple(range(n))[::-1], tuple(range(n, 2 * n))] + [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
    return mesh_object(name, verts, faces, mat)

def cylinder(name, start, end, radius, mat, vertices=16):
    start, end = Vector(start), Vector(end)
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=(end - start).length, location=(start + end) / 2)
    obj = bpy.context.object
    obj.name = name
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(end - start)
    obj.data.materials.append(mat)
    bpy.ops.object.shade_smooth()
    return obj

def tube(name, points, radius, mat):
    """A cable or conduit along a polyline, with rounded bends."""
    curve = bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = radius
    curve.bevel_resolution = 4
    spline = curve.splines.new("POLY")
    spline.points.add(len(points) - 1)
    for point, co in zip(spline.points, points):
        point.co = (*co, 1)
    obj = bpy.data.objects.new(name, curve)
    collection.objects.link(obj)
    obj.data.materials.append(mat)
    return obj

def cut(obj, *holes):
    """Openings through a wall, as booleans of boxes (lo, hi) that are not rendered."""
    for i, (lo, hi) in enumerate(holes):
        cutter = span(f"{obj.name} hole {i}", lo, hi, section)
        cutter.hide_render = True
        cutter.hide_viewport = True
        mod = obj.modifiers.new(f"Hole {i}", "BOOLEAN")
        mod.operation = "DIFFERENCE"
        mod.object = cutter
        mod.solver = "EXACT"

def frame_in(name, xa, xb, za, zb, y, depth=0.1, mullions=0):
    """A window or glazed door in an opening of the front wall: a frame, mullions, glass."""
    t = 0.07
    span(name + " glass", (xa, y + 0.12, za), (xb, y + 0.14, zb), glass)
    span(name + " head", (xa, y + 0.08, zb - t), (xb, y + 0.08 + depth, zb), frame)
    span(name + " foot", (xa, y + 0.08, za), (xb, y + 0.08 + depth, za + t), frame)
    span(name + " left", (xa, y + 0.08, za), (xa + t, y + 0.08 + depth, zb), frame)
    span(name + " right", (xb - t, y + 0.08, za), (xb, y + 0.08 + depth, zb), frame)
    for i in range(1, mullions + 1):
        mx = xa + (xb - xa) * i / (mullions + 1)
        span(name + f" mullion {i}", (mx - 0.03, y + 0.08, za), (mx + 0.03, y + 0.08 + depth, zb), frame)
    if za > 0.3:
        span(name + " sill", (xa - 0.06, y - 0.06, za - 0.05), (xb + 0.06, y + 0.12, za), alu)

# The base: a plate like an architectural model's, paving along the front ---------------------------------------------------------

BX0, BX1, BY0, BY1 = -7.5, 11.5, -7.5, 6.0
span("Base", (BX0, BY0, -0.35), (BX1, BY1, 0.0), base, bevel=0.04)
for lo, hi in (((BX0, BY0, 0), (BX1, BY0 + 0.25, 0.12)), ((BX0, BY1 - 0.25, 0), (BX1, BY1, 0.12)),
               ((BX0, BY0 + 0.25, 0), (BX0 + 0.25, BY1 - 0.25, 0.12)), ((BX1 - 0.25, BY0 + 0.25, 0), (BX1, BY1 - 0.25, 0.12))):
    span("Rim", lo, hi, base)
lawn = span("Lawn", (BX0 + 0.25, BY0 + 0.25, 0.0), (BX1 - 0.25, BY1 - 0.25, 0.04), grass)
# The deck by the glazed doors, the path to the door, the strip along the front.
span("Deck", (BX0 + 0.25, BY0 + 1.2, 0.0), (-1.4, y0, 0.14), deck, bevel=0.01)
span("Path", (-1.3, BY0 + 0.25, 0.0), (0.4, y0, 0.06), paving)
span("Front strip", (0.4, y0 - 1.1, 0.0), (x1 + 0.2, y0, 0.06), paving)

# Walls ------------------------------------------------------------------------------------------------------------------------

span("Slab", (x0, y0, 0.0), (x1, y1, 0.25), section)
span("Plinth", (x0 - 0.01, y0 - 0.01, 0.0), (CUT, y0 + T, 0.35), plinth)
front = span("Front wall", (x0, y0, 0.25), (CUT, y0 + T, H), render)
DOORS = (x0 + 0.6, x0 + 3.6, 0.25, 2.55)       # glazed sliding doors, ground floor left
ENTRY = (-0.9, 0.2, 0.25, 2.45)
UPPER = [(-4.1, -2.7, 3.6, 4.9), (-1.2, 0.2, 3.6, 4.9)]
cut(front, *[((xa, y0 - 0.1, za), (xb, y0 + T + 0.1, zb)) for xa, xb, za, zb in [DOORS, ENTRY, *UPPER]])
frame_in("Doors", *DOORS, y0, mullions=1)
for i, opening in enumerate(UPPER):
    frame_in(f"Upper window {i}", *opening, y0)
span("Entry door", (ENTRY[0], y0 + 0.12, ENTRY[2]), (ENTRY[1], y0 + 0.18, ENTRY[3]), door_mat)
span("Entry glass", (ENTRY[0] + 0.12, y0 + 0.11, 0.5), (ENTRY[0] + 0.32, y0 + 0.12, 2.2), glass)
span("Canopy", (-1.4, y0 - 1.2, 2.7), (0.7, y0, 2.78), frame)
span("Cladding", (0.35, y0 - 0.05, 0.3), (CUT, y0, 2.78), cladding)
span("Step", (-1.2, y0 - 0.7, 0.03), (0.5, y0, 0.15), plinth)

back = span("Back wall", (x0, y1 - T, 0.25), (x1, y1, H), plaster)
span("Back wall outside", (x0, y1 - 0.01, 0.25), (x1, y1, H), render)
left_wall = prism_x("Gable wall", [(y0, 0.25), (y1, 0.25), (y1, H), (0, RIDGE - 0.05), (y0, H)], x0, x0 + T, render)
# The cut: the walls' ends show their section; a ground-floor partition and the upper floor.
span("Partition", (CUT - 0.15, y0 + T, 0.25), (CUT, y1 - T, FLOOR), plaster)
span("Upper floor", (x0 + T, y0 + T, FLOOR), (x1, y1 - T, FLOOR + 0.25), section)
span("Upper floor wood", (x0 + T, y0 + T, FLOOR + 0.25), (x1, y1 - T, FLOOR + 0.27), floor_wood)
span("Ground floor wood", (x0 + T, y0 + T, 0.25), (x1, y1 - T, 0.27), floor_wood)
span("Front inside", (x0 + T, y0 + T, 0.25), (CUT - 0.15, y0 + T + 0.005, H), plaster)
span("Knee wall", (x0 + T, y1 - T - 0.005, FLOOR + 0.27), (x1, y1 - T, H), plaster)

under = lambda y: RIDGE + 0.12 - abs(y) * math.tan(PITCH) - 0.28 / math.cos(PITCH)
prism_x("Upper partition", [(y0 + T, FLOOR + 0.27), (y1 - T, FLOOR + 0.27), (y1 - T, under(y1 - T)), (0, under(0)),
                            (y0 + T, under(y0 + T))], CUT - 0.15, CUT, plaster)

# The roof: two standing-seam slabs, with a plaster ceiling under them; no overhang on the cut side ------------------------------

run = D / 2 + OVER
drop = run * math.tan(PITCH)
THICK = 0.28
for side in (-1, 1):
    top = RIDGE + 0.12
    a, b = (x0 - OVER, 0, top), (x1, 0, top)
    c, d = (x1, side * run, top - drop), (x0 - OVER, side * run, top - drop)
    roof = mesh_object(f"Roof {side}", [a, b, c, d], [(0, 3, 2, 1) if side < 0 else (0, 1, 2, 3)], [roof_metal, plaster, section])
    solid = roof.modifiers.new("Solidify", "SOLIDIFY")
    solid.thickness = THICK
    solid.offset = -1
    solid.material_offset = 1
    solid.material_offset_rim = 2
    span(f"Fascia {side}", (x0 - OVER, side * run - 0.02, top - drop - 0.3), (x1, side * run + 0.02, top - drop + 0.02), gutter)
    cylinder(f"Gutter {side}", (x0 - OVER, side * (run + 0.09), top - drop - 0.18), (x1, side * (run + 0.09), top - drop - 0.18), 0.07, gutter)
span("Ridge cap", (x0 - OVER, -0.14, RIDGE + 0.1), (x1, 0.14, RIDGE + 0.2), gutter)
cylinder("Downpipe", (x0 + 0.15, -(run + 0.09), RIDGE + 0.12 - drop - 0.2), (x0 + 0.15, -(run + 0.09), 0.1), 0.05, gutter)

# Solar panels on the front slope: 2 rows of 7, 1.13 m by 1.72 m, on rails 12 cm off the metal.
PANELS = []
pw, pl, gap = 1.13, 1.72, 0.03
n_cols, n_rows = 7, 2
start_x = -0.35 - (n_cols * pw + (n_cols - 1) * gap) / 2
normal = Vector((0, -math.sin(PITCH), math.cos(PITCH)))
for row in range(n_rows):
    for col in range(n_cols):
        along = 0.5 + row * (pl + gap) + pl / 2
        center = Vector((start_x + col * (pw + gap) + pw / 2, -along * math.cos(PITCH), RIDGE + 0.12 - along * math.sin(PITCH))) + normal * 0.14
        panel = box(f"Panel {row}-{col}", (0, 0, 0), (pw, pl, 0.04), alu, bevel=0.008)
        panel.location, panel.rotation_euler = center, (PITCH, 0, 0)
        cell = mesh_object(f"Cells {row}-{col}", [(-pw / 2 + 0.03, -pl / 2 + 0.03, 0.021), (pw / 2 - 0.03, -pl / 2 + 0.03, 0.021),
                                                (pw / 2 - 0.03, pl / 2 - 0.03, 0.021), (-pw / 2 + 0.03, pl / 2 - 0.03, 0.021)],
                           [(0, 1, 2, 3)], cells, lambda co: ((co.x + pw / 2) * 0.8, (co.y + pl / 2) * 0.8))
        cell.location, cell.rotation_euler = center, (PITCH, 0, 0)
        PANELS.append(center)
# The array's corners, from the ridge's left end round to the eave's left end: the page draws its modules there.
def slope(x, along):
    return Vector((x, -along * math.cos(PITCH), RIDGE + 0.12 - along * math.sin(PITCH))) + normal * 0.16
array_left, array_right = start_x, start_x + n_cols * pw + (n_cols - 1) * gap
array_top, array_bottom = 0.5, 0.5 + n_rows * pl + (n_rows - 1) * gap
ARRAY = [slope(array_left, array_top), slope(array_right, array_top), slope(array_right, array_bottom), slope(array_left, array_bottom)]

# Inside: on the open room's back wall, where it is seen head on, the meter (the distribution board), the inverter and the
# battery with its gauge, the kitchen left of them; a living room before them, a bedroom and a study above. Lamps glow at night ----------------------------

WALL = y1 - T
oak = pattern("Oak", ((0.5, 0.33, 0.18), (0.46, 0.3, 0.16)), (0.3, 0.19, 0.1), 2.0, 0.12, 0.002, "xy", 0.5, bump=0.05, grain=0.4)
cabinet = material("Cabinet", (0.86, 0.84, 0.8), 0.45)
counter = material("Counter", (0.12, 0.12, 0.13), 0.3)
duvet = noise_bump(material("Duvet", (0.62, 0.36, 0.26), 0.95), 300, 0.2)
linen = noise_bump(material("Linen", (0.9, 0.88, 0.84), 0.95), 300, 0.1)
shade = material("Shade", (0.95, 0.9, 0.8), 0.6, **{"Emission Color": (1.0, 0.78, 0.5, 1), "Emission Strength": 8.0 if NIGHT else 2.0})
terracotta = material("Pot", (0.55, 0.28, 0.17), 0.8)
art = [material(f"Art {i}", color, 0.7) for i, color in enumerate(((0.75, 0.45, 0.25), (0.25, 0.4, 0.55), (0.85, 0.75, 0.5)))]
gauge_on = material("Gauge", (0.1, 0.9, 0.5), 0.3, **{"Emission Color": (0.15, 1.0, 0.55, 1), "Emission Strength": 5.0})
gauge_off = material("Gauge off", (0.18, 0.2, 0.2), 0.4)

def lamp(name, x, y, z, radius=0.16, height=0.2):
    """A lampshade, lit at night, with a soft light under it."""
    cylinder(name, (x, y, z), (x, y, z + height), radius, shade, vertices=24)
    # Warm practical lighting also gives the daytime cutaway depth.
    data = bpy.data.lights.new(name + " light", "POINT")
    data.energy, data.color, data.shadow_soft_size = (40 if NIGHT else 18), (1.0, 0.75, 0.45), 0.15
    light = bpy.data.objects.new(name + " light", data)
    collection.objects.link(light)
    light.location = (x, y, z - 0.05)

def picture(name, x, y0_, y1_, z0, z1, mat):
    """A framed picture on the partition, facing the open side."""
    span(name + " frame", (x, y0_, z0), (x + 0.04, y1_, z1), frame)
    span(name, (x + 0.041, y0_ + 0.05, z0 + 0.05), (x + 0.045, y1_ - 0.05, z1 - 0.05), mat)

# The equipment, larger than life so it reads at card size.
METER = Vector((2.75, WALL - 0.08, 1.75))
span("Meter", (METER.x - 0.26, WALL - 0.16, METER.z - 0.4), (METER.x + 0.26, WALL, METER.z + 0.4), graphite, bevel=0.015)
span("Meter window", (METER.x - 0.14, WALL - 0.165, METER.z + 0.08), (METER.x + 0.14, WALL - 0.16, METER.z + 0.24), display)
for i in range(4):   # the breakers' lights
    span(f"Breaker {i}", (METER.x - 0.16 + i * 0.09, WALL - 0.17, METER.z - 0.2), (METER.x - 0.11 + i * 0.09, WALL - 0.16, METER.z - 0.14), led)
INVERTER = Vector((3.6, WALL - 0.12, 1.6))
span("Inverter", (INVERTER.x - 0.4, WALL - 0.24, INVERTER.z - 0.55), (INVERTER.x + 0.4, WALL, INVERTER.z + 0.55), white_box, bevel=0.025)
span("Inverter fins", (INVERTER.x - 0.44, WALL - 0.18, INVERTER.z - 0.5), (INVERTER.x + 0.44, WALL, INVERTER.z + 0.5), graphite)
span("Inverter display", (INVERTER.x - 0.18, WALL - 0.245, INVERTER.z + 0.14), (INVERTER.x + 0.18, WALL - 0.24, INVERTER.z + 0.34), display)
BAT = Vector((4.45, WALL - 0.16, 0.27))
if BATTERY:
    span("Battery", (BAT.x - 0.34, WALL - 0.34, 0.27), (BAT.x + 0.34, WALL, 1.6), white_box, bevel=0.03)
    span("Battery face", (BAT.x - 0.27, WALL - 0.345, 0.42), (BAT.x + 0.27, WALL - 0.34, 1.45), screen_mat)
    # The charge gauge's five cells, dark: the page lights them to the battery's level (the layout's `gauge`).
    GAUGE = [((BAT.x - 0.18, WALL - 0.35, 0.55 + i * 0.17), (BAT.x + 0.18, WALL - 0.345, 0.67 + i * 0.17)) for i in range(5)]
    for i, (low, high) in enumerate(GAUGE):
        span(f"Gauge {i}", low, high, gauge_off)
# Conduits: the panels' cable down through the upper floor, the battery's, the meter's out to the wire.
SOLAR_RUN = [(x1 - 0.35, -1.6, RIDGE + 0.12 - 1.6 * math.tan(PITCH) - THICK), (x1 - 0.35, -1.6, FLOOR + 0.27),
             (x1 - 0.35, -1.6, FLOOR - 0.05), (x1 - 0.35, WALL - 0.05, FLOOR - 0.05), (INVERTER.x + 0.2, WALL - 0.05, FLOOR - 0.05),
             (INVERTER.x + 0.2, WALL - 0.05, INVERTER.z + 0.55)]
BATTERY_RUN = [(BAT.x - 0.1, WALL - 0.05, 1.6), (BAT.x - 0.1, WALL - 0.05, 2.25), (INVERTER.x + 0.35, WALL - 0.05, 2.25),
               (INVERTER.x + 0.35, WALL - 0.05, INVERTER.z + 0.55)]
METER_RUN = [(INVERTER.x - 0.4, WALL - 0.05, 1.4), (METER.x + 0.26, WALL - 0.05, 1.4)]
FEED = Vector((x1 - 0.05, y1 + 0.25, H - 0.2))
GRID_RUN = [(METER.x, WALL - 0.05, METER.z + 0.4), (METER.x, WALL - 0.05, FLOOR - 0.05), (x1 - 0.2, WALL - 0.05, FLOOR - 0.05),
            (x1 - 0.2, WALL - 0.05, H - 0.2), (x1 - 0.2, y1 + 0.1, H - 0.2), tuple(FEED)]
for name, run_points in (("Solar conduit", SOLAR_RUN), ("Battery conduit", BATTERY_RUN if BATTERY else None),
                         ("Meter conduit", METER_RUN), ("Grid conduit", GRID_RUN)):
    if run_points:
        tube(name, run_points, 0.025, conduit)
span("Feed bracket", (FEED.x - 0.06, y1, FEED.z - 0.06), (FEED.x + 0.06, FEED.y + 0.04, FEED.z + 0.06), gutter)

# The kitchen along the back wall, left of the equipment: a fridge, base units, a worktop, wall units.
span("Fridge", (1.06, WALL - 0.7, 0.27), (1.6, WALL, 2.5), cabinet, bevel=0.015)
span("Fridge handle", (1.56, WALL - 0.72, 1.2), (1.59, WALL - 0.7, 1.9), alu)
span("Base units", (1.62, WALL - 0.62, 0.27), (2.4, WALL, 1.12), cabinet, bevel=0.01)
span("Worktop", (1.62, WALL - 0.66, 1.12), (2.44, WALL, 1.17), counter)
span("Wall units", (1.62, WALL - 0.36, 1.85), (2.4, WALL, 2.5), cabinet, bevel=0.01)
for i, x in enumerate((1.85, 2.15)):
    span(f"Jar {i}", (x - 0.06, WALL - 0.4, 1.17), (x + 0.06, WALL - 0.28, 1.37), terracotta, bevel=0.02)

# The living room: a sofa facing the television, a low table on the rug, a floor lamp, a plant, pictures, a pendant.
span("TV", (1.06, -1.4, 1.0), (1.1, 0.2, 1.9), screen_mat, bevel=0.01)
span("TV screen", (1.101, -1.34, 1.06), (1.104, 0.14, 1.84), tv_snow)
span("TV bench", (1.06, -1.5, 0.27), (1.5, 0.3, 0.65), oak, bevel=0.02)
span("Sofa seat", (3.4, -2.3, 0.27), (4.3, 0.7, 0.72), fabric, bevel=0.06)
span("Sofa back", (4.05, -2.3, 0.27), (4.4, 0.7, 1.15), fabric, bevel=0.06)
for i, y in enumerate((-1.7, -0.3)):
    span(f"Cushion {i}", (3.85, y - 0.3, 0.72), (4.05, y + 0.3, 1.05), duvet, bevel=0.06)
span("Rug", (1.8, -2.4, 0.27), (3.35, 0.9, 0.285), linen)
span("Low table", (2.2, -1.3, 0.285), (2.95, -0.2, 0.62), oak, bevel=0.02)
cylinder("Lamp stand", (4.55, -2.75, 0.27), (4.55, -2.75, 1.6), 0.02, graphite)
lamp("Floor lamp", 4.55, -2.75, 1.6, 0.2, 0.28)
cylinder("Plant pot", (1.45, -2.75, 0.27), (1.45, -2.75, 0.65), 0.18, terracotta)
picture("Living picture", 1.06, 0.55, 1.55, 1.25, 2.15, art[0])
cylinder("Pendant cord", (2.6, -0.8, 2.25), (2.6, -0.8, FLOOR - 0.02), 0.008, graphite)
lamp("Pendant", 2.6, -0.8, 2.05, 0.22, 0.2)

# Upstairs: a bed with its headboard, night tables and lamps; a desk with a screen, a chair and a lamp; a picture.
span("Headboard", (4.42, -2.8, FLOOR + 0.27), (4.55, -0.4, FLOOR + 1.35), oak, bevel=0.02)
span("Bed", (2.2, -2.6, FLOOR + 0.27), (4.42, -0.6, FLOOR + 0.62), linen, bevel=0.06)
span("Duvet", (2.15, -2.65, FLOOR + 0.62), (3.6, -0.55, FLOOR + 0.72), duvet, bevel=0.05)
for i, y in enumerate((-2.15, -1.05)):
    span(f"Pillow {i}", (3.9, y - 0.4, FLOOR + 0.62), (4.35, y + 0.4, FLOOR + 0.8), linen, bevel=0.06)
for i, y in enumerate((-3.0, -0.2)):
    span(f"Night table {i}", (4.0, y - 0.22, FLOOR + 0.27), (4.45, y + 0.22, FLOOR + 0.8), oak, bevel=0.02)
    lamp(f"Night lamp {i}", 4.22, y, FLOOR + 0.8, 0.12, 0.18)
span("Desk", (2.0, 1.8, FLOOR + 0.27), (3.6, WALL, FLOOR + 1.02), oak, bevel=0.01)
span("Screen", (2.5, WALL - 0.25, FLOOR + 1.1), (3.1, WALL - 0.21, FLOOR + 1.5), screen_mat, bevel=0.01)
span("Screen stand", (2.77, WALL - 0.26, FLOOR + 1.02), (2.83, WALL - 0.2, FLOOR + 1.1), graphite)
span("Chair", (2.55, 1.2, FLOOR + 0.27), (3.05, 1.65, FLOOR + 0.75), graphite, bevel=0.04)
lamp("Desk lamp", 3.35, WALL - 0.3, FLOOR + 1.02, 0.1, 0.16)
picture("Upper picture", CUT, -2.6, -1.2, FLOOR + 1.2, FLOOR + 2.0, art[1])
picture("Upper picture 2", CUT, 0.2, 1.0, FLOOR + 1.3, FLOOR + 1.9, art[2])

# The utility pole behind the house on the right, its wire sagging to the bracket ---------------------------------------------------

POLE = Vector((x1 + 4.2, y1 + 0.8, 0.0))
cylinder("Pole", POLE, POLE + Vector((0, 0, 8.2)), 0.13, timber)
span("Cross arm", (POLE.x - 0.08, POLE.y - 0.9, 7.6), (POLE.x + 0.08, POLE.y + 0.9, 7.75), timber)
for dy in (-0.75, 0.0, 0.75):
    cylinder(f"Insulator {dy}", (POLE.x, POLE.y + dy, 7.75), (POLE.x, POLE.y + dy, 7.95), 0.05, porcelain)
POLE_TOP = POLE + Vector((0, 0, 7.95))
sag = [POLE_TOP.lerp(FEED, t) - Vector((0, 0, 0.9 * math.sin(math.pi * t))) for t in [i / 24 for i in range(25)]]
tube("Service wire", [tuple(p) for p in sag], 0.018, wire_mat)

# The garden: shrubs, trees, a hedge, planters; seeded, so every render is the same --------------------------------------------

random.seed(7)
blob_texture = bpy.data.textures.new("Foliage", "CLOUDS")
blob_texture.noise_scale = 0.35
leaf_texture = bpy.data.textures.new("Leaf", "CLOUDS")
leaf_texture.noise_scale = 0.07

def blob(name, center, radius, mat, squash=1.0):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=5, radius=radius, location=center)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (1, 1, squash)
    mod = obj.modifiers.new("Leaves", "DISPLACE")
    mod.texture = blob_texture
    mod.strength = radius * 0.35
    mod.texture_coords = "GLOBAL"
    fine = obj.modifiers.new("Leaf", "DISPLACE")
    fine.texture = leaf_texture
    fine.strength = min(0.12, radius * 0.2)
    fine.texture_coords = "GLOBAL"
    obj.data.materials.append(mat)
    bpy.ops.object.shade_smooth()
    return obj

def shrub(x, y, size=None, mat=None):
    r = size or random.uniform(0.3, 0.55)
    blob("Shrub", (x, y, r * 0.8), r, mat or random.choice(leaves[:3] + leaves[4:]), 0.85)

def tree(x, y, height, mat):
    cylinder("Trunk", (x, y, 0), (x, y, height * 0.55), 0.07, bark)
    for i in range(4):
        dx, dy, dz = random.uniform(-0.5, 0.5), random.uniform(-0.5, 0.5), random.uniform(-0.3, 0.5)
        blob("Crown", (x + dx, y + dy, height * 0.68 + dz), random.uniform(0.75, 1.05), mat)

for x in (-6.9, -6.0, -5.1, -4.2, -3.3, -2.4, 1.2, 2.3, 3.4, 4.5, 5.6, 6.7):
    shrub(x + random.uniform(-0.15, 0.15), BY0 + 0.65 + random.uniform(-0.1, 0.1))
for y in (-6.2, -5.0, -3.8, -2.6, -1.4):
    shrub(BX1 - 0.65, y + random.uniform(-0.15, 0.15))
for x, y in ((6.2, -2.4), (7.0, -1.6), (6.4, 0.6)):
    shrub(x, y, random.uniform(0.25, 0.4), leaves[3])
tree(-6.7, -3.0, 3.8, leaves[1])
tree(10.5, 4.6, 3.4, leaves[3])  # Keep the open rooms and equipment unobstructed.
x = BX0 + 0.7
while x < BX1 - 0.6:
    blob("Hedge", (x, BY1 - 0.7 + random.uniform(-0.08, 0.08), 0.7), random.uniform(0.5, 0.62), leaves[4], 1.25)
    x += random.uniform(0.55, 0.7)
for px in (1.2, 3.6):
    span("Planter", (px - 0.45, y0 - 0.95, 0.06), (px + 0.45, y0 - 0.5, 0.5), planter_mat, bevel=0.02)
    for k in range(3):
        blob("Lavender", (px - 0.25 + k * 0.25, y0 - 0.72, 0.62), 0.16, leaves[3])

# Lounge on the deck: a sofa and a low table.
span("Lounge seat", (-5.2, -6.0, 0.14), (-2.6, -5.2, 0.5), fabric, bevel=0.05)
span("Lounge back", (-5.2, -6.0, 0.14), (-2.6, -5.75, 0.85), fabric, bevel=0.05)
span("Lounge side", (-5.2, -6.0, 0.14), (-4.4, -4.2, 0.5), fabric, bevel=0.05)
span("Lounge table", (-3.8, -4.7, 0.14), (-2.8, -4.0, 0.45), deck, bevel=0.02)

# Garden lamps along the path: lit at night.
lamp_glow = material("Lamp", (1.0, 0.85, 0.6), 0.3, **{"Emission Color": (1.0, 0.75, 0.45, 1), "Emission Strength": 12.0 if NIGHT else 0.0})
for ly in (-4.9, -6.4):
    cylinder("Bollard", (0.65, ly, 0.06), (0.65, ly, 0.62), 0.06, graphite)
    cylinder("Bollard light", (0.65, ly, 0.62), (0.65, ly, 0.7), 0.065, lamp_glow)
    if NIGHT:
        glow = bpy.data.lights.new("Bollard glow", "POINT")
        glow.energy, glow.color, glow.shadow_soft_size = 25, (1.0, 0.72, 0.42), 0.1
        lamp = bpy.data.objects.new("Bollard glow", glow)
        collection.objects.link(lamp)
        lamp.location = (0.65, ly, 0.78)

# Interior trim gives each open storey a finished architectural section.
for z in (0.28, FLOOR + 0.28):
    span("Partition skirting", (CUT, y0 + T, z), (CUT + 0.04, WALL, z + 0.12), oak)
    span("Back skirting", (CUT, WALL - 0.04, z), (x1, WALL, z + 0.12), oak)
# A distribution run along the visible cut face, branching into both occupied floors.
# Its illumination remains a live SVG overlay: an idle home must never imply power flow.
HOME_RUN = [(METER.x, WALL - 0.2, 1.4), (x1 + 0.025, WALL - 0.2, 1.4),
            (x1 + 0.025, WALL - 0.2, FLOOR + 0.12), (x1 + 0.025, -2.8, FLOOR + 0.12)]
HOME_UPPER = [(x1 + 0.025, -0.8, FLOOR + 0.12), (x1 + 0.025, -0.8, FLOOR + 1.1)]
HOME_LOWER = [(x1 + 0.025, -2.8, FLOOR + 0.12), (x1 + 0.025, -2.8, 0.35),
              (x1 + 0.025, -0.8, 0.35)]
for name, points in (("Home distribution", HOME_RUN), ("Upper supply", HOME_UPPER), ("Lower supply", HOME_LOWER)):
    tube(name, points, 0.018, conduit)

# Ground: a shadow catcher beyond the base, so the image is the model and its shadow alone.
bpy.ops.mesh.primitive_plane_add(size=120, location=(0, 0, -0.35))
bpy.context.object.is_shadow_catcher = True
bpy.context.object.hide_render = NIGHT   # at night the catcher catches mostly darkness: a haze, no shadow

# Light: a sun from the front right, a soft sky fill, and lights in the open rooms; at night a low cool moon, a dim blue
# sky and the rooms lit warm ------------------------------------------------------------------------------------------------------

sun_data = bpy.data.lights.new("Sun", "SUN")
sun_data.energy = 0.3 if NIGHT else 1.7   # at night a low moon: the garden in shade, the rooms the brightest
sun_data.color = (0.72, 0.8, 1.0) if NIGHT else (1.0, 0.83, 0.65)
sun_data.angle = math.radians(3)
sun = bpy.data.objects.new("Sun", sun_data)
collection.objects.link(sun)
sun.rotation_euler = (math.radians(50), 0, math.radians(28))

for name, location, size, energy in (("Room light", (3.0, 0.0, FLOOR - 0.1), (3.6, 5.6), 520 if NIGHT else 420),
                                     ("Upper light", (3.0, 0.0, RIDGE - 1.6), (3.0, 2.4), 420 if NIGHT else 320),
                                     ("Left room light", (-2.4, 0.0, FLOOR - 0.1), (3.6, 5.6), 300 if NIGHT else 0),
                                     ("Fill", (x1 + 16, -12.0, 9.0), (8.0, 8.0), 150 if NIGHT else 1800)):
    data = bpy.data.lights.new(name, "AREA")
    data.shape = "RECTANGLE"
    data.size, data.size_y = size
    data.energy = energy
    data.color = (0.6, 0.7, 1.0) if NIGHT and name == "Fill" else (1.0, 0.78, 0.5) if NIGHT else (1.0, 0.82, 0.62)
    light = bpy.data.objects.new(name, data)
    collection.objects.link(light)
    light.location = location
    if name == "Fill":
        light.rotation_euler = (Vector((2, 0, 2)) - Vector(location)).to_track_quat("-Z", "Y").to_euler()

world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
background = world.node_tree.nodes["Background"]
background.inputs["Color"].default_value = (0.36, 0.43, 0.68, 1) if NIGHT else (0.95, 0.93, 0.9, 1)
background.inputs["Strength"].default_value = 0.16 if NIGHT else 0.45

# Camera: a lower view favouring the open rooms, the model centred in a 3:2 frame with room on every side --------------------------------------------------------------

cam_data = bpy.data.cameras.new("Camera")
cam_data.lens = 50
# The model a little left of centre: on a wide card the panel covers the image's right edge.
cam_data.shift_x = 0.035
camera = bpy.data.objects.new("Camera", cam_data)
collection.objects.link(camera)
camera.location = (32.0, -17.0, 12.0)
target = Vector((2.0, 0.0, 1.4))
camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
scene.camera = camera

# Render ------------------------------------------------------------------------------------------------------------------------

scene.render.engine = "CYCLES"
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for device in prefs.devices:
        device.use = True
    scene.cycles.device = "GPU"
except Exception:
    pass
scene.render.film_transparent = True
scene.render.resolution_x = WIDTH
# 3:2, as the photographic houses: the model is wider than it is tall, and fills the frame without an empty sky.
scene.render.resolution_y = int(WIDTH * 2 / 3)
scene.view_settings.view_transform = "AgX"
for look in ("AgX - Medium High Contrast", "Medium High Contrast"):
    try:
        scene.view_settings.look = look
        break
    except TypeError:
        continue
scene.view_settings.exposure = 0.1 if NIGHT else -0.3
LAYOUT = "energy-house" if BATTERY else "energy-house-no-battery"
NAME = LAYOUT + ("-night" if NIGHT else "")
scene.render.image_settings.file_format = arg("--format", "WEBP")
scene.render.image_settings.color_mode = "RGBA"
os.makedirs(OUT, exist_ok=True)
if scene.render.image_settings.file_format == "WEBP":
    scene.render.image_settings.quality = 82
scene.render.filepath = os.path.join(OUT, NAME + (".webp" if scene.render.image_settings.file_format == "WEBP" else ".png"))
bpy.ops.render.render()
# The shadow catcher also catches the sky's faint ambient light, a haze over the whole frame: below 5% it goes, so the
# image is the model and its shadow on any card.
result = bpy.data.images["Render Result"]
temporary = os.path.join(OUT, NAME + ".tmp.png")
settings = scene.render.image_settings
chosen = settings.file_format
settings.file_format = "PNG"
result.save_render(temporary, scene=scene)
image = bpy.data.images.load(temporary)
pixels = numpy.array(image.pixels[:], dtype=numpy.float32).reshape(-1, 4)
pixels[:, 3] = numpy.clip((pixels[:, 3] - 0.05) / 0.95, 0, 1)
image.pixels.foreach_set(pixels.ravel())
settings.file_format = chosen
if chosen == "WEBP":
    settings.quality = 82
# The temporary PNG already has AgX applied. Re-encoding it with AgX a second
# time washes out the wood, solar cells and warm room lighting.
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
scene.view_settings.exposure = 0
scene.view_settings.gamma = 1
image.save_render(scene.render.filepath, scene=scene)
os.remove(temporary)

# Where the parts and cables land: fractions of the image's width and height, from its top left ---------------------------------

def screen(point):
    co = world_to_camera_view(scene, camera, Vector(point))
    return [round(co.x, 4), round(1 - co.y, 4)]

layout = {
    "width": scene.render.resolution_x,
    "height": scene.render.resolution_y,
    "anchors": {
        "solar": screen(sum(PANELS, Vector()) / len(PANELS)),
        "inverter": screen(INVERTER),
        "meter": screen(METER),
        "battery": screen((BAT.x, BAT.y - 0.2, 1.0)) if BATTERY else None,
        "grid": screen(POLE_TOP),
        "home": screen((3.0, -0.5, 1.2)),
    },
    "cables": {
        "solar": [screen(p) for p in SOLAR_RUN],
        "home": [screen(p) for p in HOME_RUN],
        "homeUpper": [screen(p) for p in HOME_UPPER],
        "homeLower": [screen(p) for p in HOME_LOWER],
        "battery": [screen(p) for p in BATTERY_RUN] if BATTERY else None,
        "meter": [screen(p) for p in METER_RUN],
        "grid": [screen(p) for p in GRID_RUN] + [screen(p) for p in reversed(sag)],
    },
}
layout["panels"] = {"corners": [screen(c) for c in ARRAY], "columns": n_cols, "rows": n_rows}
if BATTERY:
    # The battery's charge gauge: each cell's face as the image shows it, in the battery's perspective (bottom left,
    # bottom right, top right, top left; the bottom cell first), and the point beside the battery where the page puts
    # its figures (`side`: which side of it).
    face = GAUGE[0][0][1]
    layout["gauge"] = {"cells": [[screen((x, face, z)) for x, z in ((low[0], low[2]), (high[0], low[2]), (high[0], high[2]), (low[0], high[2]))]
                                 for low, high in GAUGE],
                       # Right of the battery, where the wall ends and the garden begins: left of it are the rooms' figures.
                       "label": screen((BAT.x + 0.4, WALL - 0.34, (GAUGE[0][0][2] + GAUGE[-1][1][2]) / 2)), "side": "right"}
with open(os.path.join(OUT, LAYOUT + ".json"), "w") as file:
    json.dump(layout, file, indent=2)
print("layout", json.dumps(layout["anchors"]))
