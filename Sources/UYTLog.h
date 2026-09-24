#import <Foundation/Foundation.h>
#import <os/log.h>

// NSLog's %@ arguments show up as <private> in Console.app, which hid every
// path, ID and extension we logged. Log the formatted string as public.
#define UYTLog(fmt, ...) os_log(OS_LOG_DEFAULT, "%{public}s", [[NSString stringWithFormat:(fmt), ##__VA_ARGS__] UTF8String])
