// ios-sim-keyboard <device UDID> <1|0> [developer dir]: connects (or disconnects) the Mac's keyboard
// to one Simulator device as a hardware keyboard, as Simulator.app's
// I/O ▸ Keyboard ▸ Connect Hardware Keyboard does (CoreSimulator SPI) —
// for the iPad UI tests' hardware-keyboard paths. Built and run by
// Scripts/ios-ui-tests.sh.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: ios-sim-keyboard <udid> <1|0>\n"); return 2; }
        if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)) { fprintf(stderr, "no CoreSimulator\n"); return 1; }
        NSError *error = nil;
        NSString *developerDir = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"/Applications/Xcode.app/Contents/Developer";
        id context = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
            NSClassFromString(@"SimServiceContext"), NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"),
            developerDir, &error);
        id set = ((id (*)(id, SEL, NSError **))objc_msgSend)(context, NSSelectorFromString(@"defaultDeviceSetWithError:"), &error);
        NSDictionary *devices = [set valueForKey:@"devicesByUDID"];
        id device = devices[[[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:argv[1]]]];
        if (!device) { fprintf(stderr, "no device %s\n", argv[1]); return 1; }
        BOOL ok = ((BOOL (*)(id, SEL, BOOL, unsigned int, NSError **))objc_msgSend)(
            device, NSSelectorFromString(@"setHardwareKeyboardEnabled:keyboardType:error:"), atoi(argv[2]) != 0, 0, &error);
        printf("%s %s\n", ok ? "ok" : "failed", error ? error.description.UTF8String : "");
        return ok ? 0 : 1;
    }
}
