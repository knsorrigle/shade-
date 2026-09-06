// MetalShade injection payload.
//
// Loaded into a game with DYLD_INSERT_LIBRARIES. That only works when the
// target's signature permits it: a hardened process needs both
// com.apple.security.cs.disable-library-validation and
// com.apple.security.cs.allow-dyld-environment-variables, and an unsigned or
// non-hardened binary has nothing to enforce. scripts/check-target.sh reports
// which case a given game is in.
//
// This stage establishes the route and nothing more: it confirms the library
// loads, and it intercepts CAMetalLayer's drawable request so the frame the
// game is about to render can be identified. Applying effects to that drawable
// comes next; hooking a shipping renderer is not something to do blind.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <pthread.h>

static void MSLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@  [inject] %@\n",
                      [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterNoStyle
                                                     timeStyle:NSDateFormatterMediumStyle],
                      message];

    NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                            inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [support URLByAppendingPathComponent:@"MetalShade" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *log = [dir URLByAppendingPathComponent:@"inject.log"];

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:log error:nil];
    if (handle) {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } else {
        [data writeToURL:log atomically:YES];
    }
    NSLog(@"MetalShade inject: %@", message);
}

#pragma mark - Post-process pipeline

// The shader mirrors the overlay's, so both routes produce the same picture.
static NSString *const kShaderSource = @"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VertexOut { float4 position [[position]]; float2 uv; };\n"
"struct Uniforms { float intensity; float3 tint; };\n"
"vertex VertexOut msVertex(uint id [[vertex_id]]) {\n"
"  float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
"  VertexOut o; o.position = float4(p[id], 0, 1);\n"
"  o.uv = float2((p[id].x + 1) * 0.5, 1 - (p[id].y + 1) * 0.5); return o; }\n"
"fragment float4 msFragment(VertexOut in [[stage_in]],\n"
"                           texture2d<float> src [[texture(0)]],\n"
"                           constant Uniforms& u [[buffer(0)]]) {\n"
"  constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
"  float3 c = src.sample(s, in.uv).rgb;\n"
"  if (u.tint.g > 0.5) { return float4(mix(c, float3(0,1,0), 0.75), 1); }\n"
"  float2 px = 1.0 / float2(src.get_width(), src.get_height());\n"
"  float3 n = src.sample(s, in.uv + float2(0,-px.y)).rgb;\n"
"  float3 e = src.sample(s, in.uv + float2(px.x,0)).rgb;\n"
"  float3 w = src.sample(s, in.uv - float2(px.x,0)).rgb;\n"
"  float3 so = src.sample(s, in.uv + float2(0,px.y)).rgb;\n"
"  float3 avg = (n + e + w + so) * 0.25;\n"
"  float range = max(max(c.r,c.g),c.b) - min(min(c.r,c.g),c.b);\n"
"  float k = u.intensity * (1.0 - smoothstep(0.2, 0.9, range));\n"
"  return float4(clamp(c + (c - avg) * k, 0.0, 1.0), 1.0); }\n";

typedef struct { float intensity; float pad; float tintR, tintG, tintB; } MSUniforms;

static id<MTLRenderPipelineState> gPipeline = nil;
static id<MTLTexture> gScratch = nil;
static float gIntensity = 0.0f;
static BOOL gTint = NO;
static BOOL gDisabled = NO;

static void ReadSettings(void) {
    // Environment variables so a Steam launch option can configure this without
    // a rebuild, and so a bad setting can be removed without touching the game.
    const char *intensity = getenv("METALSHADE_INTENSITY");
    if (intensity) { gIntensity = fminf(fmaxf(atof(intensity), 0.0f), 1.0f); }
    const char *tint = getenv("METALSHADE_TINT");
    gTint = (tint && atoi(tint) != 0);
    MSLog(@"settings: intensity %.2f, tint %@ (set METALSHADE_INTENSITY / METALSHADE_TINT)",
          gIntensity, gTint ? @"on" : @"off");
}

static BOOL EnsurePipeline(id<MTLDevice> device, MTLPixelFormat format) {
    if (gPipeline) { return YES; }
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kShaderSource options:nil error:&error];
    if (!library) { MSLog(@"shader compile failed: %@", error); return NO; }

    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"msVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"msFragment"];
    descriptor.colorAttachments[0].pixelFormat = format;
    gPipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!gPipeline) { MSLog(@"pipeline creation failed: %@", error); return NO; }
    MSLog(@"post-process pipeline ready (%lu)", (unsigned long)format);
    return YES;
}

static BOOL EnsureScratch(id<MTLDevice> device, id<MTLTexture> target) {
    if (gScratch && gScratch.width == target.width && gScratch.height == target.height
        && gScratch.pixelFormat == target.pixelFormat) {
        return YES;
    }
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:target.pixelFormat
                                                           width:target.width
                                                          height:target.height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModePrivate;
    gScratch = [device newTextureWithDescriptor:descriptor];
    return gScratch != nil;
}

/// Encodes the effect into the game's own command buffer, after everything it
/// has already encoded and before presentation. Reading and writing one texture
/// in a single pass is not allowed, so the frame is copied to scratch first.
static void ProcessDrawable(id<MTLCommandBuffer> commandBuffer, id<CAMetalDrawable> drawable) {
    id<MTLTexture> target = drawable.texture;
    if (!target) { return; }
    id<MTLDevice> device = target.device;
    if (!EnsurePipeline(device, target.pixelFormat)) { gDisabled = YES; return; }
    if (!EnsureScratch(device, target)) { gDisabled = YES; return; }

    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(target.width, target.height, 1)
                toTexture:gScratch destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:gPipeline];
    [encoder setFragmentTexture:gScratch atIndex:0];
    MSUniforms uniforms = { gIntensity, 0, 0, gTint ? 1.0f : 0.0f, 0 };
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}

#pragma mark - Hooks

static IMP gOriginalNextDrawable = NULL;
static IMP gOriginalPresentDrawable = NULL;
static pthread_once_t gReportOnce = PTHREAD_ONCE_INIT;
static pthread_once_t gProcessOnce = PTHREAD_ONCE_INIT;

static void ReportFirstDrawable(void) {
    MSLog(@"first drawable observed — the game's Metal presentation path is reachable");
}

static void ReportFirstProcessed(void) {
    MSLog(@"first frame processed in the game's command buffer");
}

static void InstallPresentHook(id<MTLCommandBuffer> sample);

static id<CAMetalDrawable> MS_nextDrawable(id self, SEL _cmd) {
    id<CAMetalDrawable> drawable =
        ((id<CAMetalDrawable> (*)(id, SEL))gOriginalNextDrawable)(self, _cmd);
    if (drawable) { pthread_once(&gReportOnce, ReportFirstDrawable); }
    return drawable;
}

static void MS_presentDrawable(id self, SEL _cmd, id<CAMetalDrawable> drawable) {
    if (!gDisabled && drawable && (gIntensity > 0.0f || gTint)) {
        // Never let a fault here take the game down: fall through to an
        // unmodified present and stop trying.
        @try {
            ProcessDrawable((id<MTLCommandBuffer>)self, drawable);
            pthread_once(&gProcessOnce, ReportFirstProcessed);
        } @catch (NSException *exception) {
            gDisabled = YES;
            MSLog(@"post-process disabled after exception: %@", exception.reason);
        }
    }
    ((void (*)(id, SEL, id))gOriginalPresentDrawable)(self, _cmd, drawable);
}

static void InstallDrawableHook(void) {
    Class layerClass = objc_getClass("CAMetalLayer");
    if (!layerClass) { MSLog(@"CAMetalLayer absent; target may not use Metal directly"); return; }
    Method method = class_getInstanceMethod(layerClass, @selector(nextDrawable));
    if (!method) { MSLog(@"CAMetalLayer has no -nextDrawable"); return; }
    gOriginalNextDrawable = method_getImplementation(method);
    method_setImplementation(method, (IMP)MS_nextDrawable);
    MSLog(@"hooked -[CAMetalLayer nextDrawable]");
}

/// MTLCommandBuffer is a protocol; the concrete class is private and varies by
/// driver. Creating one buffer of our own on the same device yields the class
/// the game's buffers will also use.
static void InstallPresentHookFromDevice(id<MTLDevice> device) {
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> sample = [queue commandBuffer];
    if (!sample) { MSLog(@"could not create a sample command buffer"); return; }
    Class bufferClass = object_getClass(sample);
    Method method = class_getInstanceMethod(bufferClass, @selector(presentDrawable:));
    if (!method) { MSLog(@"%@ has no -presentDrawable:", NSStringFromClass(bufferClass)); return; }
    gOriginalPresentDrawable = method_getImplementation(method);
    method_setImplementation(method, (IMP)MS_presentDrawable);
    MSLog(@"hooked -[%@ presentDrawable:]", NSStringFromClass(bufferClass));
}

#pragma mark - Entry point

__attribute__((constructor))
static void MetalShadeInjectInit(void) {
    @autoreleasepool {
        NSBundle *main = [NSBundle mainBundle];
        MSLog(@"loaded into %@ (%@), pid %d",
              main.bundleIdentifier ?: @"unknown bundle",
              [[NSProcessInfo processInfo] processName],
              [[NSProcessInfo processInfo] processIdentifier]);

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        MSLog(@"Metal device: %@", device.name ?: @"none");

        ReadSettings();
        InstallDrawableHook();
        if (device) { InstallPresentHookFromDevice(device); }
    }
}
