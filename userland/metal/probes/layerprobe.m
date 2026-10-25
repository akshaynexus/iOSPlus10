// SPDX-License-Identifier: MIT
// Copied from Chlorophyll (ry-diffusion/Chlorophyll 787338f, test/bgmtl_layer_probe.m), MIT: see LICENSE.Chlorophyll here.
// NegroniMetal changes: the device is the NegroniMetal one (probe_device.h: Metal's discovery, else --bundle PATH loads the plugin
// in this process), not BGMTLDevice; the metallib defaults to the one scripts/metal/build.sh stages (layerprobe.metal); a missing
// device, library or pipeline stops with a FAIL line; the result line carries PASS / FAIL for scripts/metal/phone-test.sh (stage 4a).
//
// CAMetalLayer drawables on BGMTLDevice, in a test process only (nothing registered; the layer is handed our device by hand):
//   layer.device = ours -> nextDrawable (CoreAnimation allocates the IOSurface and sends the device newTextureWithDescriptor:iosurface:plane:)
//   -> a render pass into drawable.texture -> presentDrawable: -> the IOSurface's pixels read back from the CPU and checked.
//   layerprobe [--bundle PATH] [RENDER.metallib]
// NOT RUN YET (needs the phone). Expected on a healthy GPU: the pass completes, the surface holds the triangle, present returns.
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdio.h>
#include "probe_device.h"

#define LAYERPROBE_METALLIB "/usr/local/share/negronimetal/layerprobe.metallib"

int
main(int argc, char **argv)
{
   @autoreleasepool {
      setvbuf(stdout, NULL, _IONBF, 0);
      const char *bundle = nmtl_probe_bundle_arg(&argc, argv);   // NegroniMetal
      const char *metallib = argc > 1 ? argv[1] : LAYERPROBE_METALLIB;
      id dev = nmtl_probe_device(bundle);   // NegroniMetal: in place of bgmtl_create_device()
      if (!dev) { printf("FAIL device: no Metal device\n"); return 2; }
      id queue = [dev newCommandQueue];
      NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:metallib]];
      if (!d) { printf("FAIL metallib: cannot read %s\n", metallib); return 2; }
      dispatch_data_t dd = dispatch_data_create(d.bytes, d.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
      NSError *lerr = nil;
      id lib = [dev newLibraryWithData:dd error:&lerr];
      if (!lib) { printf("FAIL library: %s: %s\n", metallib, lerr ? lerr.description.UTF8String : "nil"); return 2; }
      CAMetalLayer *layer = [CAMetalLayer layer];
      layer.device = dev;
      layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
      layer.framebufferOnly = NO;
      layer.drawableSize = CGSizeMake(64, 64);
      printf("layer.device = %s\n", [[[layer device] name] UTF8String]);
      id<CAMetalDrawable> drawable = [layer nextDrawable];
      printf("nextDrawable: %s, texture %s, iosurface id %u\n", drawable ? "yes" : "nil", [drawable texture] ? class_getName([[drawable texture] class]) : "nil",
             [[drawable texture] iosurface] ? IOSurfaceGetID((IOSurfaceRef)[[drawable texture] iosurface]) : 0);
      if (!drawable || ![drawable texture]) { printf("FAIL drawable: no drawable texture: stopping\n"); return 3; }
      MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
      pd.vertexFunction = [lib newFunctionWithName:@"bg_vs"];
      pd.fragmentFunction = [lib newFunctionWithName:@"bg_fs_color"];
      pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      NSError *err = nil;
      id pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
      if (!pso) { printf("FAIL pipeline: %s\n", err ? err.description.UTF8String : "nil"); return 2; }
      static const float tri[3 * 8] = { -1, -1, 0, 1, 1, 0, 0, 1,   1, -1, 0, 1, 0, 1, 0, 1,   -1, 1, 0, 1, 0, 0, 1, 1 };
      id vb = [dev newBufferWithBytes:tri length:sizeof(tri) options:0];
      MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
      rp.colorAttachments[0].texture = [drawable texture];
      rp.colorAttachments[0].loadAction = MTLLoadActionClear;
      rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
      id cb = [queue commandBuffer];
      id e = [cb renderCommandEncoderWithDescriptor:rp];
      [e setRenderPipelineState:pso];
      [e setVertexBuffer:vb offset:0 atIndex:0];
      [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [e endEncoding];
      [cb presentDrawable:drawable];
      [cb commit];
      [cb waitUntilCompleted];
      printf("command buffer status %ld%s\n", (long)[cb status], [cb error] ? " (error)" : "");
      IOSurfaceRef surf = (IOSurfaceRef)[[drawable texture] iosurface];
      IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
      const uint8_t *base = IOSurfaceGetBaseAddress(surf);
      size_t bpr = IOSurfaceGetBytesPerRow(surf);
      unsigned bad = 0, checked = 0;
      for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
         float nx = (x + 0.5f) / 32 - 1, ny = 1 - (y + 0.5f) / 32;
         float wg = (nx + 1) / 2, wb = (ny + 1) / 2, wr = 1 - wg - wb;
         const uint8_t *p = base + y * bpr + x * 4;
         if (wr > 0.03f && wg > 0.03f && wb > 0.03f) {
            checked++;
            if (fabsf(p[2] - wr * 255) > 3 || fabsf(p[1] - wg * 255) > 3 || fabsf(p[0] - wb * 255) > 3) bad++;
         } else if (wr < -0.03f || wg < -0.03f || wb < -0.03f) {
            checked++;
            if (p[0] || p[1] || p[2]) bad++;
         }
      }
      IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
      printf("%s layer: IOSurface read back by the CPU: %u of %u checked pixels correct, status %ld\n",
             bad || [cb status] != 4 ? "FAIL" : "PASS", checked - bad, checked, (long)[cb status]);
      return bad || [cb status] != 4;
   }
}
