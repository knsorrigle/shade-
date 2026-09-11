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
    float fog[4];        // x amount, y depth scale
    float fogColour[4];
    float ao[4];         // x strength, y radius scale, z bias, w range
} MSUniforms;

typedef struct { float direction[4]; } MSBlurParams;

static id<MTLRenderPipelineState> gComposite = nil;
static id<MTLRenderPipelineState> gBrightPass = nil;
static id<MTLRenderPipelineState> gBlur = nil;
static id<MTLRenderPipelineState> gAOPass = nil;
static id<MTLTexture> gAOA = nil, gAOB = nil, gAOWhite = nil;
static id<MTLTexture> gScratch = nil, gBloomA = nil, gBloomB = nil, gLUT = nil;
static id<MTLTexture> gDepthStub = nil;
/// Our own copy of the scene depth.
///
/// Sampling the game's depth texture directly returns zero while a blit from the
/// same texture in the same command buffer reads real values — the contents are
/// resolvable but not sampleable as bound. Copying first makes them ours to read.
static id<MTLTexture> gDepthCopy = nil;
static BOOL UpdateDepthCopy(id<MTLCommandBuffer> commandBuffer);
static void SurveyDepthCandidates(id<MTLCommandBuffer> commandBuffer);
static void PrintAOThumbnail(id<MTLCommandBuffer> commandBuffer);
/// Set once a depth target has been confirmed by its contents rather than by
/// its shape. Until then the choice is a guess, and the guess is wrong: the
/// largest matching target holds a mask, not geometry.
static BOOL gDepthConfirmed = NO;

static float gSharpen = 0, gClarity = 0, gTone = 0, gBloom = 0, gBloomThreshold = 0.8f;
static float gExposure = 0, gGamma = 1.0f, gVibrance = 0;
static float gBrightness = 0, gContrast = 1.0f, gSaturation = 1.0f, gTemperature = 0;
/// Depth fog. The scale maps reversed-Z, where the scene occupies a few
/// thousandths, onto 0..1; 128 matches what Cyberpunk 2077 produces.
static float gFog = 0, gFogScale = 0.0003f;
/// Ambient occlusion. Radius is in the same reciprocal-depth units as distance,
/// so it shrinks on screen as geometry recedes.
static float gAO = 0, gAORadius = 2.0f, gAOBias = 0.5f, gAORange = 20.0f;
static float gFogR = 0.62f, gFogG = 0.68f, gFogB = 0.76f;
static BOOL gTint = NO;
static BOOL gDisabled = NO;
/// Draws the scene depth buffer instead of the frame, to establish that it is
/// the right texture before an effect is built on it.
static BOOL gShowDepth = NO;
static BOOL DrawDepthView(id<MTLCommandBuffer> commandBuffer, id<CAMetalDrawable> drawable);

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
    gFog            = ReadNumber(json, @"fog", gFog);
    gFogScale       = ReadNumber(json, @"fogScale", gFogScale);
    gFogR           = ReadNumber(json, @"fogR", gFogR);
    gFogG           = ReadNumber(json, @"fogG", gFogG);
    gFogB           = ReadNumber(json, @"fogB", gFogB);
    gAO             = ReadNumber(json, @"ao", gAO);
    gAORadius       = ReadNumber(json, @"aoRadius", gAORadius);
    gAOBias         = ReadNumber(json, @"aoBias", gAOBias);
    gAORange        = ReadNumber(json, @"aoRange", gAORange);
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
    const char *showDepth = getenv("METALSHADE_SHOW_DEPTH");
    gShowDepth = (showDepth && atoi(showDepth) != 0);

    // A settings file, if the app has written one, wins: it is the live channel.
    ApplySettingsFile();
    MSLog(@"settings: sharpen %.2f clarity %.2f tone %.2f bloom %.2f | "
          @"exposure %+.2f gamma %.2f vibrance %+.2f | "
          @"brightness %+.2f contrast %.2f saturation %.2f temperature %+.2f | "
          @"fog %.2f ao %.2f | tint %@",
          gSharpen, gClarity, gTone, gBloom, gExposure, gGamma, gVibrance,
          gBrightness, gContrast, gSaturation, gTemperature, gFog, gAO,
          gTint ? @"on" : @"off");
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
        || gFog > 0.001f || gAO > 0.001f
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
    gAOPass     = MakePipeline(device, library, @"aoFragment", format);
    if (!gComposite || !gBrightPass || !gBlur || !gAOPass) { return NO; }

    // The composite always samples a depth texture too. A 1x1 stand-in keeps it
    // valid when no scene depth has been found, and fog is forced off in that
    // case so the stand-in cannot affect the picture.
    MTLTextureDescriptor *depthStub =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                           width:1 height:1 mipmapped:NO];
    depthStub.usage = MTLTextureUsageShaderRead;
    depthStub.storageMode = MTLStorageModePrivate;
    gDepthStub = [device newTextureWithDescriptor:depthStub];

    // Occlusion multiplies the image, so its stand-in must be white.
    MTLTextureDescriptor *whiteDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:1 height:1 mipmapped:NO];
    whiteDescriptor.usage = MTLTextureUsageShaderRead;
    whiteDescriptor.storageMode = MTLStorageModeShared;
    gAOWhite = [device newTextureWithDescriptor:whiteDescriptor];
    uint8_t white[4] = { 255, 255, 255, 255 };
    [gAOWhite replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0
                  withBytes:white bytesPerRow:4];

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
    // Occlusion at half resolution: it is blurred anyway, and this is the term
    // that costs eight depth samples per pixel.
    gAOA = MakeTarget(device, target.width / 2, target.height / 2, target.pixelFormat);
    gAOB = MakeTarget(device, target.width / 2, target.height / 2, target.pixelFormat);
    return gScratch && gBloomA && gBloomB && gAOA && gAOB;
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

    {
        // Depth and the drawable are different sizes, and if their aspect ratios
        // also differ then sampling depth with the drawable's UV misaligns them.
        static BOOL reported = NO;
        if (!reported && gDepthCopy) {
            reported = YES;
            double drawableAspect = (double)target.width / (double)target.height;
            double depthAspect = (double)gDepthCopy.width / (double)gDepthCopy.height;
            MSLog(@"drawable %lux%lu (aspect %.4f) vs depth %lux%lu (aspect %.4f) — %@",
                  (unsigned long)target.width, (unsigned long)target.height, drawableAspect,
                  (unsigned long)gDepthCopy.width, (unsigned long)gDepthCopy.height, depthAspect,
                  fabs(drawableAspect - depthAspect) < 0.005
                      ? @"match, UV maps directly"
                      : @"MISMATCH, UV sampling is misaligned");
        }
    }

    // Keep surveying until a target is confirmed by contents. Depth is otherwise
    // chosen by shape, and the largest matching target holds a mask; the loading
    // screen also leaves every target legitimately empty, so one survey proves
    // nothing.
    if (!gDepthConfirmed && (gFog > 0.001f || gAO > 0.001f)) {
        static uint64_t frames = 0;
        if (frames++ % 240 == 1) { SurveyDepthCandidates(commandBuffer); }
    }

    MSUniforms uniforms = {
        { gSharpen, gClarity, gTone, gBloom },
        { gBloomThreshold, gExposure, gGamma, gVibrance },
        { gBrightness, gContrast, gSaturation, gTemperature },
        { 0, 1, 0, gTint ? 1.0f : 0.0f },
        { 0, 0, 0, 0 },
        { 0, 0, 0, 0 },
        { 1, 1, 1, 0 },
        { gDepthCopy ? gFog : 0.0f, gFogScale, 0, 0 },
        { gFogR, gFogG, gFogB, 0 },
        { gDepthCopy ? gAO : 0.0f, gAORadius, gAOBias, gAORange },
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

    if (gAO > 0.001f && gDepthCopy && gAOA && gAOB) {
        FullscreenPass(commandBuffer, gAOA, gAOPass, @[gDepthCopy],
                       &uniforms, sizeof(uniforms));
        // Blur the occlusion, not the image: the estimator's per-pixel rotation
        // is what produces the grain, and it has to go before it is applied.
        MSBlurParams horizontal = {{ 2.5f / (float)gAOA.width, 0, 0, 0 }};
        FullscreenPass(commandBuffer, gAOB, gBlur, @[gAOA],
                       &horizontal, sizeof(horizontal));
        MSBlurParams vertical = {{ 0, 2.5f / (float)gAOA.height, 0, 0 }};
        FullscreenPass(commandBuffer, gAOA, gBlur, @[gAOB],
                       &vertical, sizeof(vertical));
    }

    if (gAO > 0.001f && gDepthCopy && getenv("METALSHADE_SHOW_AO")) {
        static uint64_t frames = 0;
        if (frames++ % 300 == 1) { PrintAOThumbnail(commandBuffer); }
    }

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
    [encoder setFragmentTexture:gDepthCopy ?: gDepthStub atIndex:3];
    [encoder setFragmentTexture:(gAO > 0.001f && gAOA) ? gAOA : gAOWhite atIndex:4];
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
    static int reports = 0;
    if (reports >= 8) { return; }
    reports += 1;

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
    if (!gDisabled && drawable && gShowDepth) {
        @try {
            if (DrawDepthView((id<MTLCommandBuffer>)commandBuffer, drawable)) { return; }
        } @catch (NSException *exception) {
            gShowDepth = NO;
            MSLog(@"depth view disabled after exception: %@", exception.reason);
        }
    }
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
static IMP gOriginalCommit = NULL;
/// Command buffers that encoded a scene-depth pass this frame.
///
/// Copying at presentation is too late: by then the next frame's depth pass has
/// already overwritten most of the buffer, leaving a band of valid data and the
/// rest reading as maximally distant. Copying when the buffer that wrote depth
/// commits captures it whole.
static NSHashTable *gBuffersWithDepth = nil;
static void MS_commit(id self, SEL _cmd);
static NSMutableSet<NSString *> *gSeenDepth = nil;

/// The scene depth texture, held from the pass that writes it.
///
/// It cannot be picked up at presentation: by then the frame is a finished
/// colour image and depth is no longer bound to anything. Retaining it here
/// keeps it alive; its contents are the current frame's, since the engine
/// rewrites the same target each frame.
static id<MTLTexture> gSceneDepth = nil;
static NSString *gSceneDepthKey = nil;
/// Every depth target seen this run, so the one holding real data can be found
/// by reading them rather than by guessing from size.
static NSMutableArray<id<MTLTexture>> *gDepthCandidates = nil;
static id<MTLRenderPipelineState> gDepthView = nil;
static void PrintDepthThumbnail(id<MTLCommandBuffer> commandBuffer);

/// Copies the scene depth into a texture of ours.
///
/// The game's depth texture cannot be sampled directly — a shader reads zero
/// from it while a blit in the same command buffer reads real values — so the
/// copy is what makes it usable.
static BOOL UpdateDepthCopy(id<MTLCommandBuffer> commandBuffer) {
    id<MTLTexture> depth = nil;
    @synchronized (gSeenDepth ?: (id)[NSNull null]) { depth = gSceneDepth; }
    if (!depth) { return NO; }

    if (!gDepthCopy || gDepthCopy.width != depth.width || gDepthCopy.height != depth.height
        || gDepthCopy.pixelFormat != depth.pixelFormat) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:depth.pixelFormat
                                                               width:depth.width
                                                              height:depth.height
                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModePrivate;
        gDepthCopy = [depth.device newTextureWithDescriptor:descriptor];
        if (!gDepthCopy) { return NO; }
        MSLog(@"depth copy allocated %lux%lu", (unsigned long)depth.width, (unsigned long)depth.height);
    }

    id<MTLBlitCommandEncoder> copy = [commandBuffer blitCommandEncoder];
    [copy copyFromTexture:depth sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(depth.width, depth.height, 1)
                toTexture:gDepthCopy destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [copy endEncoding];
    return YES;
}

/// Distinguishes scene depth from the other depth targets a frame produces.
///
/// Shadow maps are square and usually 16-bit; hierarchical Z is a fraction of
/// the size and has no colour attachment. Scene depth is written alongside a
/// colour attachment of matching size, at the internal render resolution.
static BOOL LooksLikeSceneDepth(id<MTLTexture> depth, id<MTLTexture> colour) {
    if (!depth || !colour) { return NO; }
    if (!(depth.usage & MTLTextureUsageShaderRead)) { return NO; }
    if (depth.width == depth.height) { return NO; }          // square: a shadow map
    if (depth.width != colour.width || depth.height != colour.height) { return NO; }
    if (depth.width < 640 || depth.height < 360) { return NO; }  // too small to be the scene
    // Depth32Float_Stencil8 is the usual main scene depth buffer. Excluding it
    // as awkward to sample was a mistake: the plain Depth32Float targets at the
    // same size hold a two-valued mask, not a depth gradient.
    return depth.pixelFormat == MTLPixelFormatDepth32Float
        || depth.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
}

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
            id<MTLTexture> colour = descriptor.colorAttachments[0].texture;
            if (depth.usage & MTLTextureUsageShaderRead) {
                @synchronized (gSeenDepth) {
                    if (!gDepthCandidates) { gDepthCandidates = [NSMutableArray array]; }
                    // Only shapes that could be scene depth. A shadow map is
                    // populated too, and would otherwise win on contents alone.
                    if (LooksLikeSceneDepth(depth, colour)
                        && ![gDepthCandidates containsObject:depth]
                        && gDepthCandidates.count < 12) {
                        [gDepthCandidates addObject:depth];
                    }
                    // Size alone cannot tell a populated scene depth from a
                    // pre-pass target that is still cleared; the survey below
                    // reads them instead.
                    if (!gBuffersWithDepth) {
                        gBuffersWithDepth = [NSHashTable weakObjectsHashTable];
                    }
                    BOOL preferable = !gSceneDepth
                        || (depth.pixelFormat == MTLPixelFormatDepth32Float_Stencil8
                            && gSceneDepth.pixelFormat != MTLPixelFormatDepth32Float_Stencil8);
                    if (LooksLikeSceneDepth(depth, colour) && preferable) {
                        gSceneDepth = depth;
                        NSString *key = [NSString stringWithFormat:@"%lux%lu",
                                         (unsigned long)depth.width, (unsigned long)depth.height];
                        if (![key isEqualToString:gSceneDepthKey]) {
                            gSceneDepthKey = key;
                            MSLog(@"provisional scene depth %@", key);
                        }
                    }
                    if (depth == gSceneDepth) {
                        [gBuffersWithDepth addObject:self];
                    }
                }
            }
            // One line per distinct depth target, not per frame.
            NSString *key = [NSString stringWithFormat:@"%lux%lu-%lu-%lu",
                             (unsigned long)depth.width, (unsigned long)depth.height,
                             (unsigned long)depth.pixelFormat, (unsigned long)depth.usage];
            @synchronized (gSeenDepth) {
                if (![gSeenDepth containsObject:key]) {
                    [gSeenDepth addObject:key];
                    id<MTLTexture> colourLog = descriptor.colorAttachments[0].texture;
                    MSLog(@"depth target %lux%lu format=%lu usage=[%@] samplable=%@ "
                          @"(colour attachment %lux%lu)",
                          (unsigned long)depth.width, (unsigned long)depth.height,
                          (unsigned long)depth.pixelFormat, DescribeUsage(depth.usage),
                          (depth.usage & MTLTextureUsageShaderRead) ? @"YES" : @"no",
                          (unsigned long)colourLog.width, (unsigned long)colourLog.height);
                }
            }
        }
    } @catch (NSException *exception) {
        // Reconnaissance must never be the reason a game fails.
    }
    return ((id (*)(id, SEL, MTLRenderPassDescriptor *))gOriginalRenderEncoder)(self, _cmd, descriptor);
}

static void InstallDepthProbe(Class bufferClass) {
    // Always installed. Scene depth is only reachable from the pass that writes
    // it, and fog can be switched on at any time through the settings file —
    // long after this runs. The hook itself is a comparison per render pass.
    Method method = class_getInstanceMethod(bufferClass, @selector(renderCommandEncoderWithDescriptor:));
    if (!method) { MSLog(@"no -renderCommandEncoderWithDescriptor: to probe"); return; }
    gSeenDepth = [NSMutableSet set];
    gOriginalRenderEncoder = method_getImplementation(method);
    method_setImplementation(method, (IMP)MS_renderCommandEncoder);

    Method commit = class_getInstanceMethod(bufferClass, @selector(commit));
    if (commit) {
        gOriginalCommit = method_getImplementation(commit);
        method_setImplementation(commit, (IMP)MS_commit);
    }
    MSLog(@"depth probe active — reporting each distinct depth target once");
}

/// Draws the held depth buffer as greyscale, to establish that it is the scene
/// depth and correctly oriented before any effect is built on it.
///
/// Kept separate from the shared effect chain: the overlay has no depth to bind,
/// and sampling an unbound texture there would be invalid.
static NSString *const kDepthViewSource = @"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VertexOut { float4 position [[position]]; float2 uv; };\n"
"vertex VertexOut depthVertex(uint id [[vertex_id]]) {\n"
"  float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
"  VertexOut o; o.position = float4(p[id], 0, 1);\n"
"  o.uv = float2((p[id].x + 1) * 0.5, 1 - (p[id].y + 1) * 0.5); return o; }\n"
"fragment float4 depthFragment(VertexOut in [[stage_in]],\n"
"                              depth2d<float> depth [[texture(0)]]) {\n"
"  constexpr sampler s(address::clamp_to_edge, filter::nearest);\n"
"  float d = depth.sample(s, in.uv);\n"
"  // Reversed-Z: distant geometry sits near zero and the whole scene occupies a\n"
"  // few thousandths, so the range is expanded before shaping. Without this the\n"
"  // image is uniformly black even when the buffer is correct.\n"
"  float shaped = pow(saturate(d * 128.0), 0.45);\n"
"  return float4(shaped, shaped, shaped, 1.0); }\n";

static BOOL EnsureDepthView(id<MTLDevice> device, MTLPixelFormat format) {
    if (gDepthView) { return YES; }
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kDepthViewSource options:nil error:&error];
    if (!library) { MSLog(@"depth view shader failed: %@", error); return NO; }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"depthVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"depthFragment"];
    descriptor.colorAttachments[0].pixelFormat = format;
    gDepthView = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!gDepthView) { MSLog(@"depth view pipeline failed: %@", error); return NO; }
    MSLog(@"depth view ready");
    return YES;
}

/// Reads a grid of depth values back once, so the log says what is actually in
/// the texture rather than leaving it to be judged by eye.
///
/// A buffer holding real scene depth varies across the frame. One that is
/// uniform holds a cleared or unwritten target, and would look like a plausible
/// flat image while carrying nothing.
static void SampleDepthGrid(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> depth) {
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:depth.pixelFormat
                                                           width:3 height:3 mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> probe = [depth.device newTextureWithDescriptor:descriptor];
    if (!probe) { return; }

    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    for (NSUInteger row = 0; row < 3; ++row) {
        for (NSUInteger column = 0; column < 3; ++column) {
            NSUInteger x = depth.width * (column * 2 + 1) / 6;
            NSUInteger y = depth.height * (row * 2 + 1) / 6;
            [blit copyFromTexture:depth sourceSlice:0 sourceLevel:0
                     sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(1, 1, 1)
                        toTexture:probe destinationSlice:0 destinationLevel:0
                destinationOrigin:MTLOriginMake(column, row, 0)];
        }
    }
    [blit endEncoding];

    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
        float values[9] = {0};
        [probe getBytes:values bytesPerRow:3 * sizeof(float)
             fromRegion:MTLRegionMake2D(0, 0, 3, 3) mipmapLevel:0];
        float low = values[0], high = values[0];
        for (int i = 1; i < 9; ++i) {
            low = fminf(low, values[i]);
            high = fmaxf(high, values[i]);
        }
        MSLog(@"depth grid: %.4f %.4f %.4f | %.4f %.4f %.4f | %.4f %.4f %.4f",
              values[0], values[1], values[2], values[3], values[4],
              values[5], values[6], values[7], values[8]);
        MSLog(@"depth range %.4f to %.4f — %@", low, high,
              (high - low) > 0.0001f ? @"varies, so this is real scene depth"
                                     : @"uniform, so this target holds nothing useful");
    }];
}

/// Reads a grid from every depth target seen, so the one holding the frame's
/// geometry is identified by its contents.
///
/// A populated depth buffer varies across the frame. A pre-pass or freshly
/// cleared target is uniform, and looks like a plausible flat image while
/// carrying nothing — which is exactly what the size heuristic selected.
static void SurveyDepthCandidates(id<MTLCommandBuffer> commandBuffer) {
    NSArray<id<MTLTexture>> *candidates = nil;
    @synchronized (gSeenDepth) { candidates = [gDepthCandidates copy]; }
    if (!candidates.count) { return; }

    for (id<MTLTexture> depth in candidates) {
        if (depth.pixelFormat != MTLPixelFormatDepth32Float
            && depth.pixelFormat != MTLPixelFormatDepth16Unorm
            && depth.pixelFormat != MTLPixelFormatDepth32Float_Stencil8) { continue; }
        // A blit from a combined depth-stencil texture yields 8 bytes per pixel;
        // reading it as float pairs takes the depth component.
        BOOL isFloat = depth.pixelFormat != MTLPixelFormatDepth16Unorm;
        BOOL isCombined = depth.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;

        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:depth.pixelFormat
                                                               width:3 height:3 mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        id<MTLTexture> probe = [depth.device newTextureWithDescriptor:descriptor];
        if (!probe) { continue; }

        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        for (NSUInteger row = 0; row < 3; ++row) {
            for (NSUInteger column = 0; column < 3; ++column) {
                [blit copyFromTexture:depth sourceSlice:0 sourceLevel:0
                         sourceOrigin:MTLOriginMake(depth.width * (column * 2 + 1) / 6,
                                                    depth.height * (row * 2 + 1) / 6, 0)
                           sourceSize:MTLSizeMake(1, 1, 1)
                            toTexture:probe destinationSlice:0 destinationLevel:0
                    destinationOrigin:MTLOriginMake(column, row, 0)];
            }
        }
        [blit endEncoding];

        NSUInteger width = depth.width, height = depth.height;
        id<MTLTexture> probeSource = depth;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
            float values[9] = {0};
            if (isCombined) {
                struct { float depth; uint8_t stencil; uint8_t pad[3]; } combined[9] = {0};
                [probe getBytes:combined bytesPerRow:3 * sizeof(combined[0])
                     fromRegion:MTLRegionMake2D(0, 0, 3, 3) mipmapLevel:0];
                for (int i = 0; i < 9; ++i) { values[i] = combined[i].depth; }
            } else if (isFloat) {
                [probe getBytes:values bytesPerRow:3 * sizeof(float)
                     fromRegion:MTLRegionMake2D(0, 0, 3, 3) mipmapLevel:0];
            } else {
                uint16_t raw[9] = {0};
                [probe getBytes:raw bytesPerRow:3 * sizeof(uint16_t)
                     fromRegion:MTLRegionMake2D(0, 0, 3, 3) mipmapLevel:0];
                for (int i = 0; i < 9; ++i) { values[i] = raw[i] / 65535.0f; }
            }
            float low = values[0], high = values[0];
            for (int i = 1; i < 9; ++i) {
                low = fminf(low, values[i]);
                high = fmaxf(high, values[i]);
            }
            BOOL hasData = (high - low) > 0.0001f;
            MSLog(@"candidate %lux%lu range %.4f..%.4f  %@  [%.3f %.3f %.3f %.3f %.3f]",
                  (unsigned long)width, (unsigned long)height, low, high,
                  hasData ? @"<-- HAS DATA" : @"uniform",
                  values[0], values[2], values[4], values[6], values[8]);
            if (hasData) {
                // Contents decide, not size: switch to whatever is actually
                // carrying the frame's geometry.
                gDepthConfirmed = YES;
                @synchronized (gSeenDepth) {
                    if (gSceneDepth != probeSource) {
                        gSceneDepth = probeSource;
                        MSLog(@"scene depth is %lux%lu (chosen by contents)",
                              (unsigned long)width, (unsigned long)height);
                    }
                }
            }
        }];
    }
}

/// Returns YES when it has drawn, so the normal chain is skipped for that frame.
static BOOL DrawDepthView(id<MTLCommandBuffer> commandBuffer, id<CAMetalDrawable> drawable) {
    if (!gShowDepth) { return NO; }
    id<MTLTexture> depth = nil;
    @synchronized (gSeenDepth ?: (id)[NSNull null]) { depth = gSceneDepth; }
    if (!depth) { return NO; }

    id<MTLTexture> target = drawable.texture;
    if (!EnsureDepthView(target.device, target.pixelFormat)) { gShowDepth = NO; return NO; }

    if (!gDepthCopy) { return NO; }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:gDepthView];
    [encoder setFragmentTexture:gDepthCopy atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    // Survey repeatedly rather than once. The first presented frame is a splash
    // or loading screen with no world geometry, so every depth target reads as
    // cleared and the survey concludes nothing.
    static uint64_t frame = 0;
    static int surveys = 0;
    if (frame == 0) {
        MSLog(@"drew scene depth %lux%lu over the frame, storage=%lu",
              (unsigned long)depth.width, (unsigned long)depth.height,
              (unsigned long)depth.storageMode);
    }
    frame += 1;
    if (surveys < 8 && frame % 300 == 1) {
        surveys += 1;
        MSLog(@"survey %d at frame %llu, depth storage=%lu", surveys, frame,
              (unsigned long)depth.storageMode);
        SurveyDepthCandidates(commandBuffer);
        PrintDepthThumbnail(commandBuffer);
    }
    return YES;
}

/// Renders the depth copy small and prints it as text.
///
/// Nine sampled points cannot distinguish a depth gradient from a two-valued
/// mask, and judging a full-screen image by eye cannot either. A coarse picture
/// in the log can: real scene depth shows a continuum and recognisable
/// silhouettes, a mask shows blocks.
static id<MTLTexture> gThumbnail = nil;

static void PrintDepthThumbnail(id<MTLCommandBuffer> commandBuffer) {
    const NSUInteger width = 48, height = 24;
    if (!gThumbnail) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:width height:height
                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        gThumbnail = [gDepthCopy.device newTextureWithDescriptor:descriptor];
        if (!gThumbnail) { return; }
    }
    if (!gDepthView || !gDepthCopy) { return; }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = gThumbnail;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:gDepthView];
    [encoder setFragmentTexture:gDepthCopy atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
        uint8_t pixels[24 * 48 * 4];
        [gThumbnail getBytes:pixels bytesPerRow:width * 4
                  fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        const char *ramp = " .:-=+*#%@";
        NSMutableString *picture = [NSMutableString stringWithString:@"\n"];
        NSMutableSet<NSNumber *> *distinct = [NSMutableSet set];
        for (NSUInteger y = 0; y < height; ++y) {
            NSMutableString *row = [NSMutableString string];
            for (NSUInteger x = 0; x < width; ++x) {
                uint8_t value = pixels[(y * width + x) * 4 + 1];  // green channel
                [distinct addObject:@(value)];
                [row appendFormat:@"%c", ramp[(value * 9) / 255]];
            }
            [picture appendFormat:@"  |%@|\n", row];
        }
        MSLog(@"depth thumbnail (%lu distinct values across %lu pixels):%@",
              (unsigned long)distinct.count, (unsigned long)(width * height), picture);
    }];
}

/// Appends the depth copy to a command buffer that wrote scene depth, just
/// before it commits. Every encoder is closed by then, so a blit can be added,
/// and it runs after the depth pass rather than a frame later.
static void MS_commit(id self, SEL _cmd) {
    @try {
        BOOL wroteDepth = NO;
        @synchronized (gSeenDepth ?: (id)[NSNull null]) {
            wroteDepth = gBuffersWithDepth && [gBuffersWithDepth containsObject:self];
            if (wroteDepth) { [gBuffersWithDepth removeObject:self]; }
        }
        if (wroteDepth && (gFog > 0.001f || gAO > 0.001f || gShowDepth)) {
            UpdateDepthCopy((id<MTLCommandBuffer>)self);
        }
    } @catch (NSException *exception) {
        MSLog(@"depth capture at commit disabled: %@", exception.reason);
    }
    ((void (*)(id, SEL))gOriginalCommit)(self, _cmd);
}

/// Prints the occlusion buffer as text, the same way depth was checked.
///
/// Judging occlusion by eye needs the game loaded and a scene with creases in
/// it. A coarse picture answers the question that actually matters — whether
/// flat surfaces are being left alone — without that.
static void PrintAOThumbnail(id<MTLCommandBuffer> commandBuffer) {
    if (!gAOA || !gBlur) { return; }
    const NSUInteger width = 48, height = 24;
    static id<MTLTexture> thumbnail = nil;
    if (!thumbnail) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:width height:height
                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        thumbnail = [gAOA.device newTextureWithDescriptor:descriptor];
        if (!thumbnail) { return; }
    }

    // A zero-direction blur is a passthrough, which downsamples through the
    // sampler rather than needing another pipeline.
    MSBlurParams none = {{ 0, 0, 0, 0 }};
    FullscreenPass(commandBuffer, thumbnail, gBlur, @[gAOA], &none, sizeof(none));

    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
        uint8_t pixels[24 * 48 * 4];
        [thumbnail getBytes:pixels bytesPerRow:width * 4
                 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        const char *ramp = "@%#*+=-:. ";   // dark occluded -> light open
        NSMutableString *picture = [NSMutableString stringWithString:@"\n"];
        uint8_t low = 255, high = 0;
        for (NSUInteger y = 0; y < height; ++y) {
            NSMutableString *row = [NSMutableString string];
            for (NSUInteger x = 0; x < width; ++x) {
                uint8_t v = pixels[(y * width + x) * 4 + 1];
                low = MIN(low, v); high = MAX(high, v);
                [row appendFormat:@"%c", ramp[(v * 9) / 255]];
            }
            [picture appendFormat:@"  |%@|\n", row];
        }
        MSLog(@"occlusion (%d..%d of 255; mostly light means flat surfaces are "
              @"being left alone):%@", low, high, picture);
    }];
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
