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

// The chain lives in one file that both routes compile, so the overlay and the
// injected payload cannot drift apart. MetalShade installs it here.
static NSURL *ShaderURL(void) {
    NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                            inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"MetalShade" isDirectory:YES]
            URLByAppendingPathComponent:@"Shaders/EffectChain.metal"];
}

/// Path the app writes live settings to. Environment variables are fixed at
/// launch, so they cannot drive a slider while a game is running.
static NSURL *SettingsURL(void) {
    NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                            inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"MetalShade" isDirectory:YES]
            URLByAppendingPathComponent:@"inject-settings.json"];
}

typedef struct {
    float a[4];          // sharpen, clarity, tone, bloom intensity
    float b[4];          // bloom threshold, exposure, gamma, vibrance
    float colour[4];     // brightness, contrast, saturation, temperature
    float tint[4];       // rgb, enabled
    float lut[4];        // x mix — the payload binds an identity, so kept at 0
    float domainMin[4];
    float domainMax[4];
} MSUniforms;

typedef struct { float direction[4]; } MSBlurParams;

static id<MTLRenderPipelineState> gComposite = nil;
static id<MTLRenderPipelineState> gBrightPass = nil;
static id<MTLRenderPipelineState> gBlur = nil;
static id<MTLTexture> gScratch = nil, gBloomA = nil, gBloomB = nil, gLUT = nil;

static float gSharpen = 0, gClarity = 0, gTone = 0, gBloom = 0, gBloomThreshold = 0.8f;
static float gExposure = 0, gGamma = 1.0f, gVibrance = 0;
static float gBrightness = 0, gContrast = 1.0f, gSaturation = 1.0f, gTemperature = 0;
static BOOL gTint = NO;
static BOOL gDisabled = NO;

static float ReadNumber(NSDictionary *json, NSString *key, float fallback) {
    NSNumber *value = json[key];
    return [value isKindOfClass:[NSNumber class]] ? value.floatValue : fallback;
}

static void ApplySettingsFile(void) {
    NSData *data = [NSData dataWithContentsOfURL:SettingsURL()];
    if (!data) { return; }
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) { return; }

    gSharpen        = ReadNumber(json, @"intensity", gSharpen);
    gClarity        = ReadNumber(json, @"clarity", gClarity);
    gTone           = ReadNumber(json, @"tone", gTone);
    gBloom          = ReadNumber(json, @"bloom", gBloom);
    gBloomThreshold = ReadNumber(json, @"bloomThreshold", gBloomThreshold);
    gExposure       = ReadNumber(json, @"exposure", gExposure);
    gGamma          = ReadNumber(json, @"gamma", gGamma);
    gVibrance       = ReadNumber(json, @"vibrance", gVibrance);
    gBrightness     = ReadNumber(json, @"brightness", gBrightness);
    gContrast       = ReadNumber(json, @"contrast", gContrast);
    gSaturation     = ReadNumber(json, @"saturation", gSaturation);
    gTemperature    = ReadNumber(json, @"temperature", gTemperature);
    NSNumber *tint = json[@"tint"];
    if ([tint isKindOfClass:[NSNumber class]]) { gTint = tint.boolValue; }
}

static void ReadSettings(void) {
    // Environment variables so a Steam launch option can configure this without
    // a rebuild, and so a bad setting can be removed without touching the game.
    const char *intensity = getenv("METALSHADE_INTENSITY");
    if (intensity) { gSharpen = fminf(fmaxf(atof(intensity), 0.0f), 1.0f); }
    const char *tint = getenv("METALSHADE_TINT");
    gTint = (tint && atoi(tint) != 0);

    // A settings file, if the app has written one, wins: it is the live channel.
    ApplySettingsFile();
    MSLog(@"settings: sharpen %.2f clarity %.2f tone %.2f bloom %.2f | "
          @"exposure %+.2f gamma %.2f vibrance %+.2f | "
          @"brightness %+.2f contrast %.2f saturation %.2f temperature %+.2f | tint %@",
          gSharpen, gClarity, gTone, gBloom, gExposure, gGamma, gVibrance,
          gBrightness, gContrast, gSaturation, gTemperature, gTint ? @"on" : @"off");
}

/// Polls rather than watching: the file is tiny, half a second is responsive
/// enough for a slider, and polling cannot leave a dangling watch inside a
/// process we do not own.
static void StartSettingsPolling(void) {
    static dispatch_source_t timer;
    dispatch_queue_t queue = dispatch_queue_create("io.metalshade.inject.settings", DISPATCH_QUEUE_SERIAL);
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.5 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { ApplySettingsFile(); } });
    dispatch_resume(timer);
    MSLog(@"watching %@ for live settings", SettingsURL().path);
}

/// True when any stage would change the picture. Nothing is encoded otherwise,
/// so an idle session costs the game nothing.
static BOOL HasVisibleEffect(void) {
    return gTint || gSharpen > 0.001f || gClarity > 0.001f || gTone > 0.001f || gBloom > 0.001f
        || fabsf(gExposure) > 0.001f || fabsf(gGamma - 1.0f) > 0.001f
        || fabsf(gVibrance) > 0.001f || fabsf(gBrightness) > 0.001f
        || fabsf(gContrast - 1.0f) > 0.001f || fabsf(gSaturation - 1.0f) > 0.001f
        || fabsf(gTemperature) > 0.001f;
}

static id<MTLRenderPipelineState> MakePipeline(id<MTLDevice> device, id<MTLLibrary> library,
                                               NSString *fragment, MTLPixelFormat format) {
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"fullscreenVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:fragment];
    descriptor.colorAttachments[0].pixelFormat = format;
    NSError *error = nil;
    id<MTLRenderPipelineState> state =
        [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!state) { MSLog(@"pipeline '%@' failed: %@", fragment, error); }
    return state;
}

static BOOL EnsurePipelines(id<MTLDevice> device, MTLPixelFormat format) {
    if (gComposite) { return YES; }

    NSString *source = [NSString stringWithContentsOfURL:ShaderURL()
                                                encoding:NSUTF8StringEncoding error:nil];
    if (!source) {
        MSLog(@"no shader at %@ — run MetalShade once so it installs one", ShaderURL().path);
        return NO;
    }

    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) { MSLog(@"shader compile failed: %@", error); return NO; }

    gComposite  = MakePipeline(device, library, @"compositeFragment", format);
    gBrightPass = MakePipeline(device, library, @"brightPassFragment", format);
    gBlur       = MakePipeline(device, library, @"blurFragment", format);
    if (!gComposite || !gBrightPass || !gBlur) { return NO; }

    // The composite always samples a LUT; a 2x2x2 identity keeps it valid when
    // none is loaded, rather than leaving an unbound texture to sample.
    MTLTextureDescriptor *lutDescriptor = [MTLTextureDescriptor new];
    lutDescriptor.textureType = MTLTextureType3D;
    lutDescriptor.pixelFormat = MTLPixelFormatRGBA16Float;
    lutDescriptor.width = lutDescriptor.height = lutDescriptor.depth = 2;
    lutDescriptor.usage = MTLTextureUsageShaderRead;
    gLUT = [device newTextureWithDescriptor:lutDescriptor];

    MSLog(@"effect chain compiled from %@", ShaderURL().lastPathComponent);
    return YES;
}

static id<MTLTexture> MakeTarget(id<MTLDevice> device, NSUInteger width, NSUInteger height,
                                 MTLPixelFormat format) {
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:MAX(width, 1u)
                                                          height:MAX(height, 1u)
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModePrivate;
    return [device newTextureWithDescriptor:descriptor];
}

static BOOL EnsureTextures(id<MTLDevice> device, id<MTLTexture> target) {
    if (gScratch && gScratch.width == target.width && gScratch.height == target.height
        && gScratch.pixelFormat == target.pixelFormat) {
        return YES;
    }
    gScratch = MakeTarget(device, target.width, target.height, target.pixelFormat);
    // Bloom is blurred anyway, so quarter resolution costs nothing visible and a
    // sixteenth of the work.
    gBloomA = MakeTarget(device, target.width / 4, target.height / 4, target.pixelFormat);
    gBloomB = MakeTarget(device, target.width / 4, target.height / 4, target.pixelFormat);
    return gScratch && gBloomA && gBloomB;
}

static void FullscreenPass(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> destination,
                           id<MTLRenderPipelineState> pipeline,
                           NSArray<id<MTLTexture>> *inputs,
                           const void *uniforms, size_t uniformsSize) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = destination;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    for (NSUInteger i = 0; i < inputs.count; ++i) {
        [encoder setFragmentTexture:inputs[i] atIndex:i];
    }
    [encoder setFragmentBytes:uniforms length:uniformsSize atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}

/// Encodes the chain into the game's own command buffer, after everything it has
/// already encoded and before presentation.
static void ProcessDrawable(id<MTLCommandBuffer> commandBuffer, id<CAMetalDrawable> drawable) {
    id<MTLTexture> target = drawable.texture;
    if (!target) { return; }
    id<MTLDevice> device = target.device;
    if (!EnsurePipelines(device, target.pixelFormat)) { gDisabled = YES; return; }
    if (!EnsureTextures(device, target)) { gDisabled = YES; return; }

    MSUniforms uniforms = {
        { gSharpen, gClarity, gTone, gBloom },
        { gBloomThreshold, gExposure, gGamma, gVibrance },
        { gBrightness, gContrast, gSaturation, gTemperature },
        { 0, 1, 0, gTint ? 1.0f : 0.0f },
        { 0, 0, 0, 0 },
        { 0, 0, 0, 0 },
        { 1, 1, 1, 0 },
    };

    // A texture cannot be read and written in one pass, so the frame goes to
    // scratch first and is rendered back from there.
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(target.width, target.height, 1)
                toTexture:gScratch destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];

    if (gBloom > 0.001f) {
        FullscreenPass(commandBuffer, gBloomA, gBrightPass, @[gScratch],
                       &uniforms, sizeof(uniforms));
        MSBlurParams horizontal = {{ 1.0f / (float)gBloomA.width, 0, 0, 0 }};
        FullscreenPass(commandBuffer, gBloomB, gBlur, @[gBloomA],
                       &horizontal, sizeof(horizontal));
        MSBlurParams vertical = {{ 0, 1.0f / (float)gBloomA.height, 0, 0 }};
        FullscreenPass(commandBuffer, gBloomA, gBlur, @[gBloomB],
                       &vertical, sizeof(vertical));
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:gComposite];
    [encoder setFragmentTexture:gScratch atIndex:0];
    [encoder setFragmentTexture:gBloomA ?: gScratch atIndex:1];
    [encoder setFragmentTexture:gLUT atIndex:2];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}

#pragma mark - Hooks

static IMP gOriginalNextDrawable = NULL;
static IMP gOriginalPresentDrawable = NULL;
static IMP gOriginalPresentAfter = NULL;
static IMP gOriginalPresentAt = NULL;
static IMP gOriginalDrawablePresent = NULL;
static pthread_once_t gReportOnce = PTHREAD_ONCE_INIT;
static pthread_once_t gProcessOnce = PTHREAD_ONCE_INIT;

static void ReportFirstDrawable(void) {
    MSLog(@"first drawable observed — the game's Metal presentation path is reachable");
}

static void ReportFirstProcessed(void) {
    MSLog(@"first frame processed in the game's command buffer");
}

/// Reads one pixel back from the processed frame once, so the log says what was
/// actually written instead of only that the code ran.
static void VerifyOutput(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> target) {
    static BOOL verified = NO;
    if (verified) { return; }
    verified = YES;

    id<MTLDevice> device = target.device;
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:target.pixelFormat
                                                           width:1 height:1 mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> probe = [device newTextureWithDescriptor:descriptor];
    if (!probe) { return; }

    NSUInteger x = target.width / 2, y = target.height / 2;
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(1, 1, 1)
                toTexture:probe destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];

    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
        uint8_t pixel[4] = {0};
        [probe getBytes:pixel bytesPerRow:4
             fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
        MSLog(@"centre pixel after processing: B=%d G=%d R=%d A=%d",
              pixel[0], pixel[1], pixel[2], pixel[3]);
    }];
}

static void InstallPresentHook(id<MTLCommandBuffer> sample);
static void InstallDepthProbe(Class bufferClass);

static id<CAMetalDrawable> MS_nextDrawable(id self, SEL _cmd) {
    id<CAMetalDrawable> drawable =
        ((id<CAMetalDrawable> (*)(id, SEL))gOriginalNextDrawable)(self, _cmd);
    if (drawable) { pthread_once(&gReportOnce, ReportFirstDrawable); }
    return drawable;
}

/// Shared by every present variant. Metal offers four ways to show a frame and
/// engines differ in which they use, so hooking only one works by luck.
static void ProcessIfWanted(id commandBuffer, id<CAMetalDrawable> drawable) {
    if (!gDisabled && drawable && HasVisibleEffect()) {
        // Never let a fault here take the game down: fall through to an
        // unmodified present and stop trying.
        @try {
            ProcessDrawable((id<MTLCommandBuffer>)commandBuffer, drawable);
            pthread_once(&gProcessOnce, ReportFirstProcessed);
            VerifyOutput((id<MTLCommandBuffer>)commandBuffer, drawable.texture);
        } @catch (NSException *exception) {
            gDisabled = YES;
            MSLog(@"post-process disabled after exception: %@", exception.reason);
        }
    }
}

static void MS_presentDrawable(id self, SEL _cmd, id<CAMetalDrawable> drawable) {
    ProcessIfWanted(self, drawable);
    ((void (*)(id, SEL, id))gOriginalPresentDrawable)(self, _cmd, drawable);
}

static void MS_presentAfter(id self, SEL _cmd, id<CAMetalDrawable> drawable, CFTimeInterval duration) {
    ProcessIfWanted(self, drawable);
    ((void (*)(id, SEL, id, CFTimeInterval))gOriginalPresentAfter)(self, _cmd, drawable, duration);
}

static void MS_presentAt(id self, SEL _cmd, id<CAMetalDrawable> drawable, CFTimeInterval time) {
    ProcessIfWanted(self, drawable);
    ((void (*)(id, SEL, id, CFTimeInterval))gOriginalPresentAt)(self, _cmd, drawable, time);
}

/// The direct path, where a game presents the drawable itself rather than
/// scheduling it on a command buffer. There is no command buffer to encode into,
/// so one is created on the drawable's own device and committed before the
/// original present runs.
static void MS_drawablePresent(id self, SEL _cmd) {
    id<CAMetalDrawable> drawable = (id<CAMetalDrawable>)self;
    if (!gDisabled && HasVisibleEffect() && drawable.texture) {
        @try {
            static id<MTLCommandQueue> queue = nil;
            if (!queue) { queue = [drawable.texture.device newCommandQueue]; }
            id<MTLCommandBuffer> buffer = [queue commandBuffer];
            ProcessDrawable(buffer, drawable);
            [buffer commit];
            [buffer waitUntilCompleted];
            pthread_once(&gProcessOnce, ReportFirstProcessed);
        } @catch (NSException *exception) {
            gDisabled = YES;
            MSLog(@"post-process disabled after exception: %@", exception.reason);
        }
    }
    ((void (*)(id, SEL))gOriginalDrawablePresent)(self, _cmd);
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

    // The paced variants, used by engines that control their own frame timing.
    Method after = class_getInstanceMethod(bufferClass, @selector(presentDrawable:afterMinimumDuration:));
    if (after) {
        gOriginalPresentAfter = method_getImplementation(after);
        method_setImplementation(after, (IMP)MS_presentAfter);
        MSLog(@"hooked presentDrawable:afterMinimumDuration:");
    }
    Method at = class_getInstanceMethod(bufferClass, @selector(presentDrawable:atTime:));
    if (at) {
        gOriginalPresentAt = method_getImplementation(at);
        method_setImplementation(at, (IMP)MS_presentAt);
        MSLog(@"hooked presentDrawable:atTime:");
    }

    InstallDepthProbe(bufferClass);
}

/// CAMetalDrawable is a protocol; its concrete class is private, so it is found
/// from a drawable a layer hands out rather than by name.
static void InstallDirectPresentHook(void) {
    Class drawableClass = objc_getClass("CAMetalDrawable");
    if (!drawableClass) { return; }
    Method method = class_getInstanceMethod(drawableClass, @selector(present));
    if (!method) { MSLog(@"CAMetalDrawable has no -present to hook"); return; }
    gOriginalDrawablePresent = method_getImplementation(method);
    method_setImplementation(method, (IMP)MS_drawablePresent);
    MSLog(@"hooked -[CAMetalDrawable present]");
}

#pragma mark - Depth reconnaissance

// Depth-based effects need the scene depth buffer, which never reaches a
// presented frame. It is reachable here — we are inside the process while the
// frame is still being built — but only if the game created the texture with
// shaderRead usage. That is fixed at creation and cannot be added afterwards,
// so this pass answers whether the effect is possible at all before any attempt
// to build one.
//
// It only observes. Nothing is modified and nothing is sampled.

static IMP gOriginalRenderEncoder = NULL;
static NSMutableSet<NSString *> *gSeenDepth = nil;

static NSString *DescribeUsage(MTLTextureUsage usage) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (usage & MTLTextureUsageShaderRead)      { [parts addObject:@"shaderRead"]; }
    if (usage & MTLTextureUsageShaderWrite)     { [parts addObject:@"shaderWrite"]; }
    if (usage & MTLTextureUsageRenderTarget)    { [parts addObject:@"renderTarget"]; }
    if (usage & MTLTextureUsagePixelFormatView) { [parts addObject:@"pixelFormatView"]; }
    return parts.count ? [parts componentsJoinedByString:@"|"] : @"none";
}

static id MS_renderCommandEncoder(id self, SEL _cmd, MTLRenderPassDescriptor *descriptor) {
    @try {
        id<MTLTexture> depth = descriptor.depthAttachment.texture;
        if (depth) {
            // One line per distinct depth target, not per frame.
            NSString *key = [NSString stringWithFormat:@"%lux%lu-%lu-%lu",
                             (unsigned long)depth.width, (unsigned long)depth.height,
                             (unsigned long)depth.pixelFormat, (unsigned long)depth.usage];
            @synchronized (gSeenDepth) {
                if (![gSeenDepth containsObject:key]) {
                    [gSeenDepth addObject:key];
                    id<MTLTexture> colour = descriptor.colorAttachments[0].texture;
                    MSLog(@"depth target %lux%lu format=%lu usage=[%@] samplable=%@ "
                          @"(colour attachment %lux%lu)",
                          (unsigned long)depth.width, (unsigned long)depth.height,
                          (unsigned long)depth.pixelFormat, DescribeUsage(depth.usage),
                          (depth.usage & MTLTextureUsageShaderRead) ? @"YES" : @"no",
                          (unsigned long)colour.width, (unsigned long)colour.height);
                }
            }
        }
    } @catch (NSException *exception) {
        // Reconnaissance must never be the reason a game fails.
    }
    return ((id (*)(id, SEL, MTLRenderPassDescriptor *))gOriginalRenderEncoder)(self, _cmd, descriptor);
}

static void InstallDepthProbe(Class bufferClass) {
    if (!getenv("METALSHADE_PROBE_DEPTH")) { return; }
    Method method = class_getInstanceMethod(bufferClass, @selector(renderCommandEncoderWithDescriptor:));
    if (!method) { MSLog(@"no -renderCommandEncoderWithDescriptor: to probe"); return; }
    gSeenDepth = [NSMutableSet set];
    gOriginalRenderEncoder = method_getImplementation(method);
    method_setImplementation(method, (IMP)MS_renderCommandEncoder);
    MSLog(@"depth probe active — reporting each distinct depth target once");
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
        StartSettingsPolling();
        InstallDrawableHook();
        if (device) { InstallPresentHookFromDevice(device); }
        InstallDirectPresentHook();
    }
}
