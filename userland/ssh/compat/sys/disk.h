/* iOSPlus10: the iPhoneOS SDK has no <sys/disk.h>; toybox (lib/portability.c) needs only these
 * two ioctls. Same values as the macOS SDK header. Only on the include path of the iOS build. */
#ifndef IOSPLUS10_SYS_DISK_H
#define IOSPLUS10_SYS_DISK_H
#include <stdint.h>
#include <sys/ioccom.h>
#define DKIOCGETBLOCKSIZE  _IOR('d', 24, uint32_t)
#define DKIOCGETBLOCKCOUNT _IOR('d', 25, uint64_t)
#endif
