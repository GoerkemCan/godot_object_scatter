Forest Scatter for Godot 4
==========================

Forest Scatter is an editor plugin for painting many scene instances into a 3D level.
It is based on Marc Gilleron's Scatter Tool and has been ported for Godot 4, with an added forest scatter mode by Goerk.
Original repository: [Zylann/godot_scatter_plugin](https://github.com/Zylann/godot_scatter_plugin).

The plugin adds a `Scatter3D` node. Painted objects are instanced as children of that node, so each scatter layer can be moved, saved, duplicated, or removed as a normal scene subtree.


Compatibility
-------------

- Godot 4.5.x
- 3D scenes using `Node3D`-based paintable scenes
- Surfaces with physics collisions, such as terrain, ground meshes, buildings, or other colliders

This version uses Godot 4 APIs such as `@tool`, `Node3D`, `Camera3D`, `PhysicsRayQueryParameters3D`, `RenderingServer`, and `PackedScene.instantiate()`.


Plugin Info
-----------

- Name: Forest Scatter
- Version: 1.2
- Authors: Marc Gilleron, Goerk
- Addon path: `res://addons/goerk.scatter`


Installation
------------

This is a regular Godot editor plugin.

1. Copy `addons/goerk.scatter` into your project's `addons` folder.
2. Open the project in Godot 4.
3. Go to `Project > Project Settings > Plugins`.
4. Enable `Forest Scatter`.


Basic Use
---------

1. Create or open a 3D scene that has collision geometry.
2. Add a `Scatter3D` node to the scene.
3. Select the `Scatter3D` node.
4. In the Forest Scatter panel, press `Add...` and choose one or more `.tscn` scenes to paint.
5. Select one or more entries in the list for normal paint mode.
6. Left-click or drag in the 3D viewport to paint instances.
7. Right-click or drag to erase painted instances.

Painted instances are added as children of the selected `Scatter3D` node.


Normal Paint Mode
-----------------

Normal mode paints one random selected scene at a time.

- Select entries in the list to choose what can be painted.
- Left-click places an instance on the clicked collision surface.
- Left-drag paints repeatedly.
- Right-click removes painted instances.
- `Object margin` controls the minimum spacing between placements while dragging.


Forest Mode
-----------

Forest mode paints a random group of items from the whole palette list. It is useful for drawing forests, rock fields, grass clumps, props, and other natural clusters.

To use it:

1. Add all scenes you want the forest brush to use.
2. Enable `Forest mode`.
3. Set `Diameter`.
4. Set `Amount`.
5. Set `Object margin`.
6. Left-click or drag on a collision surface.

Forest mode controls:

- `Forest mode`: Enables grouped random scattering.
- `Diameter`: Size of the circular brush area in world units.
- `Amount`: Number of placement attempts per brush stamp.
- `Object margin`: Minimum spacing between spawned items. Use `0` for automatic light spacing.

Forest mode uses all scenes currently shown in the palette list, not only the selected rows.


Scene Requirements
------------------

Scenes added to the palette should:

- Be `.tscn` files.
- Have a `Node3D` root.
- Be safe to instance multiple times.
- Use a sensible origin point, usually near the base of the object.

The surface you paint onto must have collision. If left-click painting does nothing, first check that the target ground or mesh has a collider and is on the active collision mask.


Undo And Erase
--------------

Painting and erasing are registered with Godot's undo/redo system.

- Use Godot undo to remove the last paint stroke.
- Use Godot redo to restore it.
- Right-click directly in the viewport to erase painted children from the active `Scatter3D` node.


License
-------

See [LICENSE.md](goerk.scatter/LICENSE.md).
