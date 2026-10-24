#!/usr/bin/env python3
"""negronigl: the GLI dispatch table CA calls, as C over Mesa's GL dispatch.

usage: gen-gli.py gli-slots.txt MESA_INCLUDE_DIR dispatch.h OUT.c

Slot i is called by CoreAnimation as disp[i](rctx, arguments of the GL function of slot i).
Each wrapper makes rctx's context current when it is not, then calls Mesa through the current
dispatch table: CALL_<Name>(GET_DISPATCH(), (...)) of main/dispatch.h. The target is the core
name (suffix ARB/EXT/OES/APPLE/NV/KHR dropped) if Mesa's table has it, else the name itself.
Names in HAND are written in eagl.c as ngl_h_<Name>(rctx, ...). Slots with no Mesa function
log once (ngl_unsupported) and return 0.
Design after ios-sailfish tools/sweetgl/gen-dispatch.py; own code.
"""
import re
import sys

slots_file, inc, dispatch_h, out = sys.argv[1:5]
NSLOTS = 1036   # size of GLEngine's dispatch table

# slot name -> eagl.c function (same arguments, rctx first)
HAND = {
    'glDeleteProgram': 'ngl_h_DeleteObject',     # Apple's slot 591 is DeleteObjectARB: shader or program
    'glShaderSource': 'ngl_h_ShaderSource',
    'glCompileShader': 'ngl_h_CompileShader',
    'glLinkProgram': 'ngl_h_LinkProgram',
    'glGetString': 'ngl_h_GetString',
    'glTexImage2D': 'ngl_h_TexImage2D',
    'glBindTexture': 'ngl_h_BindTexture',
    'glDeleteTextures': 'ngl_h_DeleteTextures',
    'glFramebufferTexture2D': 'ngl_h_FramebufferTexture2D',
    'glDrawArrays': 'ngl_h_DrawArrays',
    'glDrawElements': 'ngl_h_DrawElements',
    'glFlush': 'ngl_h_Flush',
    'glFinishObjectAPPLE': 'ngl_h_FinishObjectAPPLE',
    'glTestObjectAPPLE': 'ngl_h_TestObjectAPPLE',
    'glFinishFenceAPPLE': 'ngl_h_FinishFenceAPPLE',
}
ALIAS = {'CreateShaderObject': 'CreateShader', 'CreateProgramObject': 'CreateProgram',
         'UseProgramObject': 'UseProgram', 'AttachObject': 'AttachShader', 'DetachObject': 'DetachShader'}


def read(path):
    try:
        return open(path).read()
    except FileNotFoundError:
        return ''


# prototypes with parameter names, from the Khronos headers in Mesa's include/
hdr = ''.join(read(inc + '/' + h) for h in ('GL/gl.h', 'GL/glext.h', 'GLES2/gl2.h', 'GLES2/gl2ext.h',
                                            'GLES3/gl3.h', 'GLES3/gl31.h', 'GLES3/gl32.h'))
protos = {}
for m in re.finditer(r'(?:GLAPI|GL_APICALL)\s+([\w\s\*]+?)\s*(?:GLAPIENTRY|APIENTRY|GL_APIENTRY)\s+(gl\w+)\s*\(([^)]*)\)', hdr):
    ret, name, args = ' '.join(m.group(1).split()), m.group(2), ' '.join(m.group(3).split())
    params = [] if args in ('', 'void') else [a.strip() for a in args.split(',')]
    protos.setdefault(name, (ret, params))

# Mesa's dispatch: name -> (return type, [parameter types])
disp = {}
for m in re.finditer(r'typedef\s+(.+?)\s*\(GLAPIENTRYP _glptr_(\w+)\)\((.*?)\);', read(dispatch_h)):
    args = m.group(3).strip()
    disp[m.group(2)] = (m.group(1).strip(), [] if args in ('', 'void') else [a.strip() for a in args.split(',')])


def split(param):
    """'const GLfloat *v' -> ('const GLfloat *', 'v')"""
    m = re.match(r'(.*?)(\w+)\s*$', param)
    return m.group(1).strip(), m.group(2)


def is_ptr(t):
    return '*' in t or t in ('GLhandleARB', 'GLsync', 'GLeglImageOES')


def conv(val, src, dst):
    if src == dst:
        return val
    if is_ptr(src) != is_ptr(dst):
        return '(%s)(uintptr_t)(%s)' % (dst, val)
    return '(%s)(%s)' % (dst, val)


slots = {}
for line in open(slots_file):
    line = line.split('#')[0].split()
    if line:
        slots[int(line[0])] = line[-1]

body, table, missing = [], [], []
for i in range(NSLOTS):
    name = slots.get(i)
    if name in HAND:
        table.append('(void *)%s' % HAND[name])
        continue
    target = None
    if name and name in protos:
        base = name[2:]
        core = ALIAS.get(re.sub(r'(ARB|EXT|OES|APPLE|NV|KHR)$', '', base), re.sub(r'(ARB|EXT|OES|APPLE|NV|KHR)$', '', base))
        for t in (core, base, core + 'ARB', core + 'EXT', core + 'OES'):
            if t in disp and len(disp[t][1]) == len(protos[name][1]):
                target = t
                break
    if target is None:
        table.append('(void *)unsupported_%d' % i)
        body.append('static long unsupported_%d(void) { ngl_unsupported(%d); return 0; }' % (i, i))
        if name:
            missing.append(name)
        continue
    ret, params = protos[name]
    tret, tparams = disp[target]
    sp = [split(p) for p in params]
    # GL_TEXTURE_RECTANGLE textures are 2D ones here (eagl.c ngl_tgt)
    args = ', '.join(conv('NGL_TGT(%s)' % v if v == 'target' else v, t, tt) for (t, v), tt in zip(sp, tparams))
    call = 'CALL_%s(GET_DISPATCH(), (%s))' % (target, args)
    decl = ', '.join(['void *rctx'] + params)
    if ret == 'void':
        stmt = '%s; NGL_POST(%d);' % (call, i)
    else:
        stmt = '%s r = %s; NGL_POST(%d); return r;' % (ret, conv(call, tret, ret), i)
    body.append('static %s w_%d(%s) { NGL_CUR(rctx); %s }' % (ret, i, decl, stmt))
    table.append('(void *)w_%d' % i)

with open(out, 'w') as f:
    f.write('/* generated by userland/negronigl/gen-gli.py from gli-slots.txt: do not edit */\n')
    f.write('#include <stdint.h>\n#include "negronigl.h"\n#include "glapi/glapi.h"\n#include "main/dispatch.h"\n\n')
    f.write('/* hand-written slots (eagl.c) */\n')
    for name, fn in sorted(HAND.items(), key=lambda x: x[1]):
        if name in protos and name in slots.values():
            ret, params = protos[name]
            f.write('%s %s(%s);\n' % (ret, fn, ', '.join(['void *rctx'] + params)))
    f.write('\n' + '\n'.join(body))
    f.write('\n\nvoid *const ngl_dispatch[%d] = {\n' % NSLOTS)
    f.write(''.join('\t%s,\n' % t for t in table))
    f.write('};\n\nconst char *const ngl_slot_names[%d] = {\n' % NSLOTS)
    f.write(''.join('\t"%s",\n' % (slots.get(i) or '?') for i in range(NSLOTS)))
    f.write('};\n')
print('gen-gli: %d slots named, %d without a Mesa function: %s' % (len(slots), len(missing), ' '.join(missing)),
      file=sys.stderr)
