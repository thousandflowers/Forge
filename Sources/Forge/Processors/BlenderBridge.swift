import Foundation

/// The 3D formats only Blender writes or opens, with their colours and
/// materials: it is started without a window, told what to open and what to
/// write, and never runs what a file would have it run.
enum BlenderBridge {
  private static let opens: Set<String> = ["blend", "fbx", "glb", "gltf", "obj", "stl", "ply", "usd", "usda", "usdc", "usdz", "abc"]
  private static let writes: Set<String> = ["blend", "fbx", "glb", "obj", "stl", "ply", "usd", "usda", "usdc", "usdz", "abc"]
  /// The ends nobody else here has.
  private static let own: Set<String> = ["blend"]
  private static let ownWritten: Set<String> = ["blend", "fbx"]

  static let extensions = own

  static func takes(_ source: String, _ target: String) -> Bool {
    source != target && opens.contains(source) && writes.contains(target) && (own.contains(source) || ownWritten.contains(target))
  }

  /// The names come after the two dashes: they are words to it, and not Python.
  private static let script = """
    import bpy, sys
    a, b = sys.argv[sys.argv.index('--') + 1:][:2]
    s, t = [x.rsplit('.', 1)[1].lower() for x in (a, b)]
    if s == 'blend':
        bpy.ops.wm.open_mainfile(filepath=a, load_ui=False, use_scripts=False)
    else:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        o = bpy.ops
        {'fbx': lambda: o.import_scene.fbx(filepath=a), 'glb': lambda: o.import_scene.gltf(filepath=a), 'gltf': lambda: o.import_scene.gltf(filepath=a),
         'obj': lambda: o.wm.obj_import(filepath=a), 'stl': lambda: o.wm.stl_import(filepath=a), 'ply': lambda: o.wm.ply_import(filepath=a),
         'abc': lambda: o.wm.alembic_import(filepath=a, as_background_job=False)}.get(s, lambda: o.wm.usd_import(filepath=a))()
    o = bpy.ops
    {'blend': lambda: o.wm.save_as_mainfile(filepath=b, copy=True), 'fbx': lambda: o.export_scene.fbx(filepath=b), 'glb': lambda: o.export_scene.gltf(filepath=b, export_format='GLB'),
     'obj': lambda: o.wm.obj_export(filepath=b, export_materials=False), 'stl': lambda: o.wm.stl_export(filepath=b),
     'ply': lambda: o.wm.ply_export(filepath=b), 'abc': lambda: o.wm.alembic_export(filepath=b, as_background_job=False)}.get(t, lambda: o.wm.usd_export(filepath=b))()
    """

  static func arguments(_ input: URL, _ output: URL) -> [String] {
    ["--background", "--factory-startup", "--disable-autoexec", "--python-exit-code", "1", "--python-expr", script, "--", input.path, output.path]
  }
}
