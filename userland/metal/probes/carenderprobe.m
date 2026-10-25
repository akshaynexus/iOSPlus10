// SPDX-License-Identifier: MIT
// Copied from Chlorophyll (ry-diffusion/Chlorophyll 787338f, test/bgmtl_carenderer_probe.m), MIT: see LICENSE.Chlorophyll here.
// NegroniMetal changes: the device is the NegroniMetal one (probe_device.h: Metal's discovery, else --bundle PATH loads the plugin
// in this process), not BGMTLDevice; result lines carry the PASS / FAIL words scripts/metal/phone-test.sh greps (stage 4a); the
// usage line names this tool. The scenes, the CPU reference and the comparison are Chlorophyll's.
//
// Phase (j)(b), test process only: an offscreen CARenderer over an MTLTexture of BGMTLDevice, compared with CoreAnimation's own CPU rendering of
// the same layer tree (-[CALayer renderInContext:]). The device is registered IN THIS PROCESS with MTLAddDevice (as bgmtl_adddev does); nothing else
// on the phone sees it. Scenes: solid layers, an image, text, a rounded clip, a mask, a blur filter. Each scene writes sceneN.ppm (Metal) and
// refN.ppm (CPU) and prints the mean absolute channel difference. Any selector CoreAnimation sends that BGMTLDevice lacks is logged (bgmtl.m).
//   carenderprobe [--bundle PATH] OUTDIR [scene]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "probe_device.h"

#define W 256
#define H 256

static CALayer *
make_scene(int n)
{
   CALayer *root = [CALayer layer];
   root.bounds = CGRectMake(0, 0, W, H);
   root.position = CGPointMake(W / 2, H / 2);
   root.backgroundColor = CGColorCreateGenericRGB(0.1, 0.1, 0.2, 1);
   root.geometryFlipped = NO;
   switch (n) {
   case 0: {   // solid layers, one translucent
      CGFloat c[3][4] = { { 1, 0, 0, 1 }, { 0, 1, 0, 0.5 }, { 0, 0, 1, 1 } };
      for (int i = 0; i < 3; i++) {
         CALayer *l = [CALayer layer];
         l.frame = CGRectMake(20 + i * 50, 20 + i * 40, 120, 120);
         l.backgroundColor = CGColorCreateGenericRGB(c[i][0], c[i][1], c[i][2], c[i][3]);
         [root addSublayer:l];
      }
      break;
   }
   case 1: {   // an image: a gradient made with CoreGraphics
      CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
      CGContextRef g = CGBitmapContextCreate(NULL, 64, 64, 8, 0, cs, kCGImageAlphaPremultipliedLast);
      for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
         CGContextSetRGBFillColor(g, x / 63.0, y / 63.0, 0.5, 1);
         CGContextFillRect(g, CGRectMake(x, y, 1, 1));
      }
      CGImageRef img = CGBitmapContextCreateImage(g);
      CALayer *l = [CALayer layer];
      l.frame = CGRectMake(32, 32, 192, 192);
      l.contents = (__bridge id)img;
      l.magnificationFilter = kCAFilterLinear;
      [root addSublayer:l];
      break;
   }
   case 2: {   // text
      CATextLayer *t = [CATextLayer layer];
      t.frame = CGRectMake(10, 80, 236, 60);
      t.string = @"Bergamota Metal";
      t.fontSize = 28;
      t.foregroundColor = CGColorCreateGenericRGB(1, 1, 1, 1);
      t.contentsScale = 1;
      [root addSublayer:t];
      break;
   }
   case 3: {   // rounded clip with a child that overflows
      CALayer *l = [CALayer layer];
      l.frame = CGRectMake(40, 40, 176, 176);
      l.cornerRadius = 40;
      l.masksToBounds = YES;
      l.backgroundColor = CGColorCreateGenericRGB(0.9, 0.7, 0.1, 1);
      CALayer *c = [CALayer layer];
      c.frame = CGRectMake(100, 100, 150, 150);
      c.backgroundColor = CGColorCreateGenericRGB(0.8, 0.1, 0.5, 1);
      [l addSublayer:c];
      [root addSublayer:l];
      break;
   }
   case 4: {   // a mask layer (a circle shape)
      CALayer *l = [CALayer layer];
      l.frame = CGRectMake(28, 28, 200, 200);
      l.backgroundColor = CGColorCreateGenericRGB(0.2, 0.8, 0.9, 1);
      CAShapeLayer *m = [CAShapeLayer layer];
      m.frame = l.bounds;
      m.path = CGPathCreateWithEllipseInRect(CGRectMake(20, 20, 160, 160), NULL);
      m.fillColor = CGColorCreateGenericRGB(0, 0, 0, 1);
      l.mask = m;
      [root addSublayer:l];
      break;
   }
   case 5: {   // a blur filter over a pattern (CAFilter is private; absent = scene skipped)
      for (int i = 0; i < 8; i++) {
         CALayer *l = [CALayer layer];
         l.frame = CGRectMake(i * 32, 0, 16, H);
         l.backgroundColor = CGColorCreateGenericRGB(1, 1, 1, 1);
         [root addSublayer:l];
      }
      Class cf = NSClassFromString(@"CAFilter");
      id blur = cf ? [cf performSelector:NSSelectorFromString(@"filterWithType:") withObject:@"gaussianBlur"] : nil;
      if (blur) {
         [blur setValue:@6 forKey:@"inputRadius"];
         root.filters = @[ blur ];
      }
      break;
   }
   case 6: {   // a material: stripes behind a CABackdropLayer with blur + saturation and a translucent tint (an iOS platter)
      for (int i = 0; i < 8; i++) {
         CALayer *l = [CALayer layer];
         l.frame = CGRectMake(i * 32, 0, 16, H);
         l.backgroundColor = CGColorCreateGenericRGB(i & 1 ? 1 : 0.1, i & 2 ? 0.8 : 0.2, i & 4 ? 0.9 : 0.1, 1);
         [root addSublayer:l];
      }
      Class bd = NSClassFromString(@"CABackdropLayer"), cf = NSClassFromString(@"CAFilter");
      if (bd && cf) {
         CALayer *b = [bd layer];
         b.frame = CGRectMake(32, 32, 192, 192);
         id blur = [cf performSelector:NSSelectorFromString(@"filterWithType:") withObject:@"gaussianBlur"];
         [blur setValue:@12 forKey:@"inputRadius"];
         id sat = [cf performSelector:NSSelectorFromString(@"filterWithType:") withObject:@"colorSaturate"];
         [sat setValue:@1.8 forKey:@"inputAmount"];
         b.filters = @[ blur, sat ];
         [root addSublayer:b];
         CALayer *tint = [CALayer layer];
         tint.frame = b.frame;
         tint.backgroundColor = CGColorCreateGenericRGB(1, 1, 1, 0.3);
         [root addSublayer:tint];
      }
      break;
   }
   }
   return root;
}

static void
write_ppm(const char *path, const uint8_t *bgra)
{
   FILE *f = fopen(path, "wb");
   if (!f) return;
   fprintf(f, "P6\n%d %d\n255\n", W, H);
   for (int i = 0; i < W * H; i++) { fputc(bgra[i * 4 + 2], f); fputc(bgra[i * 4 + 1], f); fputc(bgra[i * 4], f); }
   fclose(f);
}

int
main(int argc, char **argv)
{
   @autoreleasepool {
      setvbuf(stdout, NULL, _IONBF, 0);
      const char *bundle = nmtl_probe_bundle_arg(&argc, argv);   // NegroniMetal
      if (argc < 2) { printf("usage: carenderprobe [--bundle PATH] OUTDIR [scene]\n"); return 2; }
      int only = argc > 2 ? atoi(argv[2]) : -1;
      // NegroniMetal: iOS 16 Metal exports no MTLCopyAllDevices (20H392), so the "devices before" count is not printed here
      if (getenv("BG_IMP_FIND")) {   // which ObjC methods live at these Metal.framework offsets (crash report frames)
         char *list = strdup(getenv("BG_IMP_FIND"));
         unsigned long want[16]; int nw = 0;
         for (char *t = strtok(list, ","); t && nw < 16; t = strtok(NULL, ",")) want[nw++] = strtoul(t, NULL, 16);
         unsigned nc = 0;
         Class *cls = objc_copyClassList(&nc);
         for (unsigned c = 0; c < nc; c++) {
            for (int meta = 0; meta < 2; meta++) {
               Class k = meta ? object_getClass((id)cls[c]) : cls[c];
               unsigned nm = 0;
               Method *ms = class_copyMethodList(k, &nm);
               for (unsigned m = 0; m < nm; m++) {
                  Dl_info di;
                  IMP imp = method_getImplementation(ms[m]);
                  if (!dladdr((void *)imp, &di) || !strstr(di.dli_fname, "/Metal.framework/")) continue;
                  unsigned long off = (unsigned long)imp - (unsigned long)di.dli_fbase;
                  for (int w = 0; w < nw; w++)
                     if (off <= want[w] && want[w] - off < 0x400)
                        printf("0x%lx: %c[%s %s] +0x%lx\n", want[w], meta ? '+' : '-', class_getName(cls[c]),
                               sel_getName(method_getName(ms[m])), want[w] - off);
               }
               free(ms);
            }
         }
         return 0;
      }
      id<MTLDevice> d = nmtl_probe_device(bundle);   // NegroniMetal: in place of bgmtl_create_device() + MTLAddDevice
      printf("default device: %s\n", d ? [[d name] UTF8String] : "nil");
      if (!d) { printf("FAIL device: no Metal device\n"); return 2; }
      int bad = 0, done = 0;
      for (int n = 0; n < 7; n++) {
         if (only >= 0 && n != only) continue;
         CALayer *scene = make_scene(n);
         // the reference: CoreAnimation's CPU path into a bitmap
         CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
         uint8_t *ref = calloc(W * H, 4);
         CGContextRef g = CGBitmapContextCreate(ref, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
         CGContextTranslateCTM(g, 0, H); CGContextScaleCTM(g, 1, -1);   // layer space is top-left, a bitmap context bottom-left
         [scene renderInContext:g];
         // the subject: CARenderer over a texture of the BGMTL device
         MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
         td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
         id<MTLTexture> tex = [d newTextureWithDescriptor:td];
         id<MTLCommandQueue> q = [d newCommandQueue];
         CARenderer *r = [CARenderer rendererWithMTLTexture:tex options:@{ kCARendererMetalCommandQueue : q }];
         if (!r) { printf("FAIL scene %d: CARenderer refused the texture\n", n); bad++; continue; }
         r.layer = scene;
         r.bounds = CGRectMake(0, 0, W, H);
         [CATransaction flush];      // the renderer draws the render tree, which only exists after a commit
         CFTimeInterval t = CACurrentMediaTime();
         void (*msgs)(BOOL) = getenv("BG_MSGSENDS") ? (void (*)(BOOL))dlsym(RTLD_DEFAULT, "instrumentObjcMessageSends") : NULL;
         if (getenv("BG_MSGSENDS")) printf("instrumentObjcMessageSends: %s\n", msgs ? "on (/tmp/msgSends-PID)" : "not exported");
         if (msgs) msgs(YES);
         [r beginFrameAtTime:t timeStamp:NULL];
         [r addUpdateRect:r.bounds];
         [r render];
         [r endFrame];
         if (msgs) msgs(NO);
         // CARenderer commits without waiting: a command buffer behind it on the same queue completes after its work
         id<MTLCommandBuffer> fence = [q commandBuffer];
         [fence commit];
         [fence waitUntilCompleted];
         usleep(200000);   // CoreAnimation may commit its own buffer after ours (seen as an all-zero read now and then)
         uint8_t *out = calloc(W * H, 4);
         [tex getBytes:out bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
         double sum = 0; unsigned nonzero = 0;
         for (int i = 0; i < W * H * 4; i++) { sum += abs((int)out[i] - (int)ref[i]); if (out[i]) nonzero++; }
         printf("%s scene %d: mean abs diff %.2f over %d channels, %u non-zero bytes rendered\n", nonzero ? "PASS" : "FAIL", n,
                sum / (W * H * 4), W * H * 4, nonzero);
         char p[600];
         snprintf(p, sizeof(p), "%s/scene%d.ppm", argv[1], n); write_ppm(p, out);
         snprintf(p, sizeof(p), "%s/ref%d.ppm", argv[1], n); write_ppm(p, ref);
         if (!nonzero) bad++;
         done++;
         free(out); free(ref);
      }
      printf("== %s: %d scenes rendered, %d with nothing drawn or refused\n", bad ? "FAIL" : "PASS", done, bad);
      return bad != 0;
   }
}
