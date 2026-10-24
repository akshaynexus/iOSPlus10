# negronigl: Mesa freedreno (GLES 3.x) + our msm DRM emulation + the EAGL shim, as one iOS dylib.
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
  'negronigl.c', 'eagl.c', 'surface.c', 'shaders.c', 'log.c', 'drm/negroni_drm.c',
  ngl_gli_c, main_dispatch_h,
  name_prefix : '',
  name_suffix : 'dylib',
  gnu_symbol_visibility : 'hidden',
  c_args : ngl_c_args,
  link_args : ngl_link_args,
  link_depends : files('exports.txt'),
  include_directories : [
    ngl_inc, inc_include, inc_src, inc_mapi, inc_mesa, inc_gallium, inc_gallium_aux,
    inc_gallium_winsys, inc_gallium_drivers,
  ],
  link_whole : [libglapi_static],
  link_with : [libmesa, libgallium, libglapi],
  dependencies : [dep_thread, dep_clock, idep_mesautil, driver_freedreno, idep_xmlconfig, dep_libdrm],
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
