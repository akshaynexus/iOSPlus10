# negronigl: Mesa freedreno or softpipe (GLES 3.x) + our msm DRM emulation + the EAGL shim, as one iOS
# dylib, and NegroniGL.bundle (plugin/: the GLD renderer plugin libGFXShared loads) from the same sources.
# This file is the meson of a Gallium target inside Mesa's tree: scripts/gpu/build.sh copies
# userland/negronigl/ to MESA/src/gallium/targets/negronigl/, and our patch
# mesa-patches/0001-negronigl-target.patch adds `subdir('targets/negronigl')` to
# src/gallium/meson.build (Darwin + freedreno only). Linking follows the osmesa target.

ngl_inc = include_directories('.', 'drm')

ngl_gli_c = custom_target(
  'gli_dispatch.c',
  input : ['gen-gli.py', 'gli-slots.txt', main_dispatch_h],
  output : 'gli_dispatch.c',
  command : [prog_python, '@INPUT0@', '@INPUT1@', join_paths(meson.project_source_root(), 'include'),
             '@INPUT2@', '@OUTPUT@'],
)

ngl_core_src = files('negronigl.c', 'eagl.c', 'surface.c', 'shaders.c', 'sw_winsys.c', 'log.c',
                     'drm/negroni_drm.c')
# GLI plugin entries (NegroniGL.bundle only): the 18 _gli_plugin slots EAGL binds on Mesa. The dylib
# uses the Obj-C EAGL shim in eagl.c instead, so these are not part of ngl_core_src.
ngl_plugin_src = files('plugin/gli_table.c', 'plugin/gli_context.c', 'plugin/gli_view.c')
ngl_inc_all = [
  ngl_inc, inc_include, inc_src, inc_mapi, inc_mesa, inc_gallium, inc_gallium_aux,
  inc_gallium_winsys, inc_gallium_drivers,
]
ngl_deps = [dep_thread, dep_clock, idep_mesautil, driver_freedreno, driver_softpipe, idep_xmlconfig, dep_libdrm]

ngl_c_args = [
  '-Wno-unused-parameter', '-Wno-missing-field-initializers', '-Wno-deprecated-declarations',
  '-DNEGRONIGL_MESA_VERSION="@0@"'.format(meson.project_version()),
]

ngl_link_args = [
  '-Wl,-install_name,/usr/lib/negronigl.dylib',
  '-Wl,-exported_symbols_list,' + join_paths(meson.current_source_dir(), 'exports.txt'),
  '-Wl,-dead_strip',
  '-framework', 'IOKit', '-framework', 'IOSurface', '-framework', 'CoreFoundation',
  '-lobjc', '-lc++',
]

libnegronigl = shared_library(
  'negronigl',
  ngl_core_src, ngl_gli_c, main_dispatch_h,
  name_prefix : '',
  name_suffix : 'dylib',
  gnu_symbol_visibility : 'hidden',
  c_args : ngl_c_args,
  link_args : ngl_link_args,
  link_depends : files('exports.txt'),
  include_directories : ngl_inc_all,
  link_whole : [libglapi_static],
  link_with : [libmesa, libgallium, libglapi],
  dependencies : ngl_deps,
  install : false,
)

# NegroniGL.bundle/NegroniGL (scripts/gpu/build.sh makes the bundle around this file). The exports are
# the GLD names libGFXShared looks up (plugin/gen-gld.py: 129 + gldInitializeLibrary/TerminateLibrary).
ngl_gld = custom_target(
  'gld_stubs',
  input : ['plugin/gen-gld.py', 'plugin/gld-names.txt', 'plugin/gld.c'],
  output : ['gld_stubs.c', 'gld-exports.txt'],
  command : [prog_python, '@INPUT0@', '@INPUT1@', '@INPUT2@', '@OUTPUT0@', '@OUTPUT1@'],
)

negronigl_bundle = shared_module(
  'NegroniGL',
  ngl_core_src, ngl_plugin_src, 'plugin/gld.c', ngl_gld[0], ngl_gli_c, main_dispatch_h,
  name_prefix : '',
  name_suffix : 'bin',
  gnu_symbol_visibility : 'hidden',
  # gld.c: the GLD functions have no header; libGFXShared finds them with dlsym
  c_args : ngl_c_args + ['-DNGL_PLUGIN=1', '-Wno-missing-prototypes'],
  link_args : [
    '-Wl,-exported_symbols_list,' + ngl_gld[1].full_path(),
    '-Wl,-dead_strip',
    '-framework', 'IOKit', '-framework', 'IOSurface', '-framework', 'CoreFoundation',
    '-lobjc', '-lc++',
  ],
  link_depends : ngl_gld[1],
  include_directories : ngl_inc_all + [include_directories('plugin')],
  link_whole : [libglapi_static],
  link_with : [libmesa, libgallium, libglapi],
  dependencies : ngl_deps,
  install : false,
)

# ngl_test: the library's self test (and an IOSurface round trip) from a shell on the phone
executable(
  'ngl_test',
  'tools/ngl_test.c',
  include_directories : [ngl_inc],
  c_args : ngl_c_args,
  link_with : libnegronigl,
  link_args : ['-framework', 'IOSurface', '-framework', 'CoreFoundation'],
  install : false,
)
