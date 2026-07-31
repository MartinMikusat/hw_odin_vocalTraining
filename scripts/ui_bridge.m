#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#include <string.h>
#include <unistd.h>

static NSString *copyStringAttribute(
    AXUIElementRef element,
    CFStringRef attribute
) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) !=
            kAXErrorSuccess ||
        value == NULL) {
        return nil;
    }
    NSString *result = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        result = [(__bridge NSString *)value copy];
    }
    CFRelease(value);
    return result;
}

static BOOL elementMatches(AXUIElementRef element, NSString *label) {
    NSArray<NSString *> *values = @[
        copyStringAttribute(element, kAXTitleAttribute) ?: @"",
        copyStringAttribute(element, kAXDescriptionAttribute) ?: @"",
        copyStringAttribute(element, kAXHelpAttribute) ?: @"",
    ];
    for (NSString *value in values) {
        if ([value isEqualToString:label]) {
            return YES;
        }
    }
    return NO;
}

static AXUIElementRef findElement(
    AXUIElementRef element,
    NSString *label,
    NSInteger depth
) {
    if (depth > 12) {
        return NULL;
    }
    if (elementMatches(element, label)) {
        return (AXUIElementRef)CFRetain(element);
    }
    CFTypeRef childrenValue = NULL;
    if (AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute,
            &childrenValue
        ) != kAXErrorSuccess ||
        childrenValue == NULL) {
        return NULL;
    }
    AXUIElementRef found = NULL;
    if (CFGetTypeID(childrenValue) == CFArrayGetTypeID()) {
        CFArrayRef children = (CFArrayRef)childrenValue;
        CFIndex count = CFArrayGetCount(children);
        for (CFIndex index = 0; index < count && found == NULL; index++) {
            AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(
                children,
                index
            );
            found = findElement(child, label, depth + 1);
        }
    }
    CFRelease(childrenValue);
    return found;
}

static AXUIElementRef findApplicationElement(pid_t pid, NSString *label) {
    AXUIElementRef application = AXUIElementCreateApplication(pid);
    AXUIElementRef found = findElement(application, label, 0);
    CFRelease(application);
    return found;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4 || strcmp(argv[1], "ax-press") != 0) {
            fprintf(
                stderr,
                "usage: ui_bridge ax-press pid label\n"
            );
            return 2;
        }
        if (!AXIsProcessTrusted()) {
            fprintf(
                stderr,
                "Accessibility permission is required for the bridge suite\n"
            );
            return 77;
        }
        pid_t pid = (pid_t)strtol(argv[2], NULL, 10);
        NSString *value = [NSString stringWithUTF8String:argv[3]];
        AXUIElementRef element = NULL;
        for (NSInteger attempt = 0;
             attempt < 40 && element == NULL;
             attempt++) {
            element = findApplicationElement(pid, value);
            if (element == NULL) {
                usleep(5000);
            }
        }
        if (element == NULL) {
            fprintf(stderr, "Accessibility element not found: %s\n", argv[3]);
            return 3;
        }
        AXError error = AXUIElementPerformAction(element, kAXPressAction);
        CFRelease(element);
        return error == kAXErrorSuccess ? 0 : 4;
    }
}
