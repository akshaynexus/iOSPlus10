#!/usr/bin/env python3
"""Mi A3 iOS 26 kernel: HID event wire format of 23F84. Writes patches/laurel/xnu-12377/post/9006-laurel-hid-2238.patch.

  scripts/bg.sh hid-port scripts/laurel/ios26-hid-port.sh      (fetches IOHIDFamily, then runs this)

The series patch topaz 0058 (both kernels) stages IOHIDFamily-1915.140.3, the version of iOS 16.7. 23F84 has IOHIDFamily-2238.120.5 (docs/laurel_sprout/ios26-touch.md):
each event has its own queue header, and a digitizer event has doubles (160 bytes), not IOFixed (104 bytes). This tool replaces those Apple files by their 2238.120.5
versions, in post/ only, so the iOS 16 kernel keeps 1915. Our own files of 0058 (SweetHID.cpp, IOHIDEventService.h, IOHIDDebug.h, IOGraphicsTypes.h) stay.

The 4 generated headers (IOHIDEvent{Types,StructDefs,FieldDefs,MacroDefs}.h) are not in Apple's 2238 source: they come from the 1915 tag + the exact schema changes below.
The method and each change: IOS-26-Hot xnu/patches-26/0058-stage-iohidfamily.sh (MIT). Each change must match exactly once, or this tool stops.
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

FAMILY = ('AppleHIDUsageTables.h', 'IOHIDDeviceKeys.h', 'IOHIDDeviceTypes.h', 'IOHIDEvent.cpp', 'IOHIDEvent.h', 'IOHIDEventData.h',
          'IOHIDEventServiceKeys.h', 'IOHIDEventServiceKeys_Private.h', 'IOHIDEventServiceQueue.cpp', 'IOHIDEventServiceQueue.h',
          'IOHIDEventServiceTypes.h', 'IOHIDEventServiceUserClient.cpp', 'IOHIDEventServiceUserClient.h', 'IOHIDFamilyTrace.h', 'IOHIDKeys.h',
          'IOHIDPrivateKeys.h', 'IOHIDProperties.h', 'IOHIDTimeSyncKeys.h', 'IOHIDUsageTables.h')
HIDSYSTEM = ('IOHIDParameter.h', 'IOHIDShared.h', 'IOHIDTypes.h', 'IOLLEvent.h', 'ev_keymap.h')
GENERATED = ('IOHIDEventTypes.h', 'IOHIDEventStructDefs.h', 'IOHIDEventFieldDefs.h', 'IOHIDEventMacroDefs.h')
DEFS_SHA = '2365347f5147a1e2a46de21acd08d27fe0906e85'    # IOHIDFamily-1915.140.3
HID_SHA = 'e31e90a24c27ad6cbe981650d12a1a4124065b03'     # IOHIDFamily-2238.120.5


def one(text, old, new, label):
    n = text.count(old)
    if n != 1:
        raise SystemExit(f'IOHIDFamily schema mismatch ({label}): {n} matches, wanted 1')
    return text.replace(old, new)


def struct_defs(s):
    base = 'typedef struct {\n    uint32_t size;\n    IOHIDEventType type;\n    uint32_t options;\n    uint8_t depth;\n    uint8_t reserved[3];\n'
    s = one(s, base + '} IOHIDCollectionEventData;',
            base + '    uint16_t usagePage;\n    uint16_t usage;\n    uint32_t ungroupForLegacy:1;\n    uint32_t reservedFlags:31;\n} IOHIDCollectionEventData;', 'collection')
    fx = '    struct {\n        IOFixed x;\n        IOFixed y;\n        IOFixed z;\n    } position;\n'
    db = '    struct {\n        IOHIDDouble x;\n        IOHIDDouble y;\n        IOHIDDouble z;\n    } position;\n'
    s = one(s, base + fx + '} IOHIDTranslationEventData;', base + db + '} IOHIDTranslationEventData;', 'translation')
    btn = '    struct {\n        uint32_t mask;\n    } button;\n'
    s = one(s, base + fx + btn + '} IOHIDPointerEventData;', base + db + btn + '} IOHIDPointerEventData;', 'pointer')
    m = re.search(r'typedef struct \{[^{}]*(?:\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}[^{}]*)*\}\s*IOHIDDigitizerEventData;', s)
    if not m:
        raise SystemExit('IOHIDDigitizerEventData not found')
    dig = m.group(0).replace('IOFixed ', 'IOHIDDouble ')
    dig = one(dig, '    IOHIDDouble twist;\n', '    union {\n        IOHIDDouble roll;\n        IOHIDDouble twist;\n    } angle;\n', 'digitizer angle')
    s = one(s, m.group(0), dig, 'digitizer')
    s = one(s, '    uint32_t thumbstickButtonRight:1;\n    IOFixed l4;\n    IOFixed l5;\n    IOFixed r4;\n    IOFixed r5;\n} __IOHIDGameControllerEventData;',
            '    uint32_t thumbstickButtonRight:1;\n    IOFixed l4;\n    IOFixed r4;\n    struct {\n        IOFixed m1;\n        IOFixed m2;\n        IOFixed m3;\n        IOFixed m4;\n    } bottom;\n} __IOHIDGameControllerEventData;', 'game')
    s = one(s, '#endif\n', 'typedef struct {\n    uint32_t size;\n    IOHIDEventType type;\n    uint32_t options;\n    uint8_t depth;\n    uint8_t reserved[3];\n    uint32_t rate;\n    IOHIDDouble confidence;\n    uint32_t location;\n    uint32_t generationCount;\n} IOHIDHeartRateEventData;\n\ntypedef struct {\n    IOHIDHeartRateEventData base;\n} __IOHIDHeartRateEventData;\n\n#endif\n', 'heart rate')
    return s


def macro_defs(m):
    m = m.replace('((IOHIDDigitizerEventData*)event)->twist', '((IOHIDDigitizerEventData*)event)->angle.twist')
    m = m.replace('->l5', '->bottom.m1').replace('->r5', '->bottom.m2')
    for st in ('IOHIDTranslationEventData', 'IOHIDPointerEventData', 'IOHIDDigitizerEventData'):
        m = m.replace(f'CAST_FIXED_TO_INTEGER((({st}*)event)->', f'CAST_DOUBLE_TO_INTEGER((({st}*)event)->')
        m = m.replace(f'CAST_FIXED_TO_DOUBLE((({st}*)event)->', f'CAST_DOUBLE_TO_DOUBLE((({st}*)event)->')
        m = m.replace(f'CAST_FIXED_TO_FIXED((({st}*)event)->', f'CAST_DOUBLE_TO_FIXED((({st}*)event)->')
        for old, new in (('CAST_INTEGER_TO_FIXED', 'CAST_INTEGER_TO_DOUBLE'), ('CAST_DOUBLE_TO_FIXED', 'CAST_DOUBLE_TO_DOUBLE'), ('CAST_FIXED_TO_FIXED', 'CAST_FIXED_TO_DOUBLE')):
            m = re.sub(rf'(\(\({st}\*\)event\)->[^\n=]+=\s*\(typeof\(\(\({st}\*\)event\)->[^\n=]+\)\)\s*){old}\(value\)', rf'\g<1>{new}(value)', m)
    m = re.sub(r'(case kIOHIDEventFieldDigitizerTwist:\s*\\\n(?:\s*[^\n]+\\\n)+?\s*break;\s*\\\n)',
               lambda x: x.group(1) + x.group(1).replace('kIOHIDEventFieldDigitizerTwist', 'kIOHIDEventFieldDigitizerRoll').replace('->angle.twist', '->angle.roll'), m)
    m = one(m, '      case kIOHIDEventTypePointer:\\\n          size = sizeof (__IOHIDPointerEventData);\\\n          break; \\',
            '      case kIOHIDEventTypePointer:\\\n          size = sizeof (__IOHIDPointerEventData);\\\n          break; \\\n      case kIOHIDEventTypeHeartRate:\\\n          size = sizeof (__IOHIDHeartRateEventData);\\\n          break; \\', 'size')
    return m


def event_types(t):
    t = one(t, '    kIOHIDEventTypeGenericGesture,\n    kIOHIDEventTypeCount, // This should always be last',
            '    kIOHIDEventTypeGenericGesture,\n    kIOHIDEventTypeDynamicButton,\n    kIOHIDEventTypeForceStage,\n    kIOHIDEventTypeTouchSensitiveButton,\n    kIOHIDEventTypeHeartRate,\n    kIOHIDEventTypeCount, // This should always be last', 'types')
    t = one(t, '    kIOHIDDigitizerEventEstimatedPressure                   = 1<<30,\n', '    kIOHIDDigitizerEventEstimatedPressure                   = 1<<30,\n    kIOHIDDigitizerEventEstimatedRoll                       = 1U<<31,\n', 'estimated roll')
    a = '    kIOHIDDigitizerEventUpdateQualityRadiiAccuracyMask      = 1<<IOHIDEventFieldOffsetOf(kIOHIDEventFieldDigitizerQualityRadiiAccuracy),\n'
    t = one(t, a, a + '    kIOHIDDigitizerEventUpdateRollMask                      = 1<<IOHIDEventFieldOffsetOf(kIOHIDEventFieldDigitizerRoll),\n', 'update roll')
    t = one(t, '#endif /* _IOKIT_HID_IOHIDEVENTTYPES_H } */', 'enum {\n    kIOHIDHeartRateSensorLocationUnknown        = 0,\n    kIOHIDHeartRateSensorLocationLeftHeadphone  = 1,\n    kIOHIDHeartRateSensorLocationRightHeadphone = 2,\n    kIOHIDHeartRateSensorLocationWatch          = 3,\n};\ntypedef uint32_t IOHIDHeartRateSensorLocation;\n\n#endif /* _IOKIT_HID_IOHIDEVENTTYPES_H } */', 'heart rate location')
    return t


def field_defs(f):
    a = 'static const IOHIDEventField kIOHIDEventFieldDigitizerTwist                                    =  (kIOHIDEventFieldDigitizerBase | 12);\n'
    f = one(f, a, a + 'static const IOHIDEventField kIOHIDEventFieldDigitizerRoll                                     =  (kIOHIDEventFieldDigitizerBase | 23);\n', 'roll field')
    f = one(f, '#endif\n', '#define kIOHIDEventFieldHeartRateBase IOHIDEventFieldBase(kIOHIDEventTypeHeartRate)\nstatic const IOHIDEventField kIOHIDEventFieldHeartRateRate                                     =  (kIOHIDEventFieldHeartRateBase | 0);\nstatic const IOHIDEventField kIOHIDEventFieldHeartRateConfidence                               =  (kIOHIDEventFieldHeartRateBase | 1);\nstatic const IOHIDEventField kIOHIDEventFieldHeartRateLocation                                 =  (kIOHIDEventFieldHeartRateBase | 2);\nstatic const IOHIDEventField kIOHIDEventFieldHeartRateGenerationCount                          =  (kIOHIDEventFieldHeartRateBase | 3);\n#endif\n', 'heart rate fields')
    return f


def kernel_build(p):
    t = p.read_text(encoding='utf-8', errors='surrogateescape')
    t = re.sub(r'#include\s*<IOKit/(?:hid|hidsystem|graphics)/([^>]+)>', r'#include "\1"', t)
    t = t.replace('#include <TargetConditionals.h>', '/* SWEET: kernel build, no SDK TargetConditionals.h */\n#ifndef TARGET_OS_DRIVERKIT\n#define TARGET_OS_DRIVERKIT 0\n#endif')
    t = t.replace('#include <math.h>', '/* SWEET: no <math.h> in the kernel; only NAN is used */\n#ifndef NAN\n#define NAN __builtin_nanf("")\n#endif')
    p.write_text(t, encoding='utf-8', errors='surrogateescape')


def main():
    repo, base, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])   # IOHIDFamily git, the hid folder before this patch, the patch to write
    def show(sha, name):
        return subprocess.check_output(['git', '-C', str(repo), 'show', f'{sha}:IOHIDFamily/{name}']).decode('utf-8')
    if subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD']).decode().strip() != HID_SHA:
        raise SystemExit(f'{repo}: HEAD is not {HID_SHA}')
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp) / 'iokit/Kernel/arm/hid'
        shutil.copytree(base, tree)
        subprocess.check_call(['git', 'init', '-q', tmp])
        subprocess.check_call(['git', '-C', tmp, 'add', '-A'])
        subprocess.check_call(['git', '-C', tmp, '-c', 'user.name=x', '-c', 'user.email=x', 'commit', '-qm', 'base'])
        for n in FAMILY:
            shutil.copy2(repo / 'IOHIDFamily' / n, tree / n)
        for n in HIDSYSTEM:
            shutil.copy2(repo / 'IOHIDSystem/IOKit/hidsystem' / n, tree / n)
        (tree / 'IOHIDEventTypes.h').write_text(event_types(show(DEFS_SHA, 'IOHIDEventTypes.h')))
        (tree / 'IOHIDEventFieldDefs.h').write_text(field_defs(show(DEFS_SHA, 'IOHIDEventFieldDefs.h')))
        (tree / 'IOHIDEventStructDefs.h').write_text(struct_defs(show(DEFS_SHA, 'IOHIDEventStructDefs.h')))
        (tree / 'IOHIDEventMacroDefs.h').write_text(macro_defs(show(DEFS_SHA, 'IOHIDEventMacroDefs.h')))
        for p in sorted(tree.iterdir()):
            if p.suffix in ('.h', '.cpp') and p.name not in ('SweetHID.cpp', 'IOHIDEventService.h', 'IOHIDDebug.h', 'IOGraphicsTypes.h'):
                kernel_build(p)
        subprocess.check_call(['git', '-C', tmp, 'add', '-A'])
        diff = subprocess.check_output(['git', '-C', tmp, 'diff', '--cached', '--no-color', '--no-renames', '--full-index', 'HEAD'])
    head = ('laurel 9006 (iOS 26 only): HID event wire format of 23F84: IOHIDFamily-2238.120.5 in place of the 1915.140.3 of topaz 0058. Each event has its own queue header, '
            'a digitizer event has doubles (160 bytes). Generated by scripts/laurel/ios26-hid-port.py: docs/laurel_sprout/ios26-touch.md.\n\n')
    out.write_bytes(head.encode() + diff)
    print(f'{out}: {len(diff)} bytes')


if __name__ == '__main__':
    main()
