/* Linux build only (userland/laurel/camera/build.sh): the macOS SDK's CVImageBuffer.h includes the whole ApplicationServices
 * umbrella, whose Security headers refuse an iOS target. CoreVideo needs only the CoreGraphics types from it. */
#include <CoreGraphics/CoreGraphics.h>
