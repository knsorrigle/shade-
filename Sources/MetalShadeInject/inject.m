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

#pragma mark - CAMetalLayer interception

static IMP gOriginalNextDrawable = NULL;
static pthread_once_t gReportOnce = PTHREAD_ONCE_INIT;

static void ReportFirstDrawable(void) {
    MSLog(@"first drawable observed — the game's Metal presentation path is reachable");
}

static id<CAMetalDrawable> MS_nextDrawable(id self, SEL _cmd) {
    id<CAMetalDrawable> drawable =
        ((id<CAMetalDrawable> (*)(id, SEL))gOriginalNextDrawable)(self, _cmd);
    if (drawable) {
        pthread_once(&gReportOnce, ReportFirstDrawable);
    }
    return drawable;
}

static void InstallDrawableHook(void) {
    Class layerClass = objc_getClass("CAMetalLayer");
    if (!layerClass) {
        MSLog(@"CAMetalLayer is not present; the target may not use Metal directly");
        return;
    }
    Method method = class_getInstanceMethod(layerClass, @selector(nextDrawable));
    if (!method) {
        MSLog(@"CAMetalLayer has no -nextDrawable to hook");
        return;
    }
    gOriginalNextDrawable = method_getImplementation(method);
    method_setImplementation(method, (IMP)MS_nextDrawable);
    MSLog(@"hooked -[CAMetalLayer nextDrawable]");
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

        InstallDrawableHook();
    }
}
