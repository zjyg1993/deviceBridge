#import <Foundation/Foundation.h>
#import <launch.h>
#import <fcntl.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>

static BOOL DBWriteAll(int fd, NSData *data) {
    const unsigned char *bytes = data.bytes;
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = write(fd, bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        offset += (NSUInteger)count;
    }
    return YES;
}

static void DBServe(int connection, uid_t owner, NSString *helper) {
    uid_t user;
    gid_t group;
    if (getpeereid(connection, &user, &group) != 0 || user != owner) return;
    struct timeval deadline = {.tv_sec = 3};
    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &deadline, sizeof deadline);
    int preventSignal = 1;
    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &preventSignal, sizeof preventSignal);

    char message[60];
    size_t length = 0;
    while (length < sizeof message) {
        ssize_t count = read(connection, message + length, sizeof message - length);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return;
        if (!count) break;
        length += (size_t)count;
    }
    if (length == sizeof message) return;
    NSString *request = [[NSString alloc] initWithBytes:message length:length encoding:NSASCIIStringEncoding];
    if ([request isEqual:@"status\n"]) {
        DBWriteAll(connection, [@"DeviceBridge USB SMART 1\n" dataUsingEncoding:NSASCIIStringEncoding]);
        return;
    }
    NSRange match = [request rangeOfString:@"^disk[0-9]{1,8} [0-9]{1,20}\\n$" options:NSRegularExpressionSearch];
    if (!match.length || match.length != request.length) return;
    request = [request substringToIndex:request.length - 1];
    NSArray *arguments = [request componentsSeparatedByString:@" "];

    NSTask *worker = [NSTask new];
    // IOKit plug-in loading needs the login bootstrap used by the USB client.
    // launchctl asuser keeps this worker's root credentials after adopting that context.
    worker.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    worker.arguments = @[@"asuser", [@(owner) stringValue], helper, @"capture", arguments[0], arguments[1]];
    worker.environment = @{@"PATH": @"/usr/bin:/bin:/usr/sbin:/sbin"};
    worker.standardInput = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *output = [NSPipe pipe];
    worker.standardOutput = output;
    if (![worker launchAndReturnError:nil]) return;
    NSData *report = [output.fileHandleForReading readDataToEndOfFile];
    [worker waitUntilExit];
    if (worker.terminationStatus == 0 && report.length <= 65536) DBWriteAll(connection, report);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (geteuid() != 0 || argc != 2) return 2;
        char *end = NULL;
        unsigned long number = strtoul(argv[1], &end, 10);
        if (*end || number < 501 || number >= UINT32_MAX) return 2;
        NSString *directory = [NSProcessInfo.processInfo.arguments[0] stringByDeletingLastPathComponent];
        NSString *helper = [directory stringByAppendingPathComponent:@"devicebridge-usb-smart"];
        int *listeners = NULL;
        size_t count = 0;
        int activation = launch_activate_socket("SMART", &listeners, &count);
        if (activation || count != 1) { free(listeners); return 3; }
        int listener = listeners[0];
        free(listeners);
        fcntl(listener, F_SETFD, FD_CLOEXEC);
        struct pollfd watched = {.fd = listener, .events = POLLIN};
        while (YES) {
            int ready = poll(&watched, 1, 30000);
            if (!ready) { close(listener); return 0; }
            if (ready < 0 && errno == EINTR) continue;
            if (ready < 0) break;
            int connection = accept(listener, NULL, NULL);
            if (connection < 0 && errno == EINTR) continue;
            if (connection < 0) break;
            fcntl(connection, F_SETFD, FD_CLOEXEC);
            @autoreleasepool { DBServe(connection, (uid_t)number, helper); }
            close(connection);
        }
        return 1;
    }
}
