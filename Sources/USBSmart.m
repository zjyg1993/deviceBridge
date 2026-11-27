#import "USBSmart.h"
#import <DiskArbitration/DiskArbitration.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOBSD.h>
#import <IOKit/storage/IOMedia.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

@interface DBSmartCapture : NSObject
@property NSString *disk;
@property NSNumber *registry;
@property NSNumber *location;
@property NSMutableSet<NSString *> *volumes;
@end
@implementation DBSmartCapture
@end

static id DBRegistryProperty(io_registry_entry_t entry, CFStringRef key) {
    return CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0));
}

static NSNumber *DBUSBRegistry(io_registry_entry_t node) {
    if (![DBRegistryProperty(node, CFSTR("idVendor")) isEqual:@0x152d] ||
        ![DBRegistryProperty(node, CFSTR("idProduct")) isEqual:@0x0580]) return nil;
    uint64_t identity = 0;
    return IORegistryEntryGetRegistryEntryID(node, &identity) == KERN_SUCCESS && identity ? @(identity) : nil;
}

static NSDictionary<NSNumber *, NSNumber *> *DBConnectedBridges(void) {
    NSMutableDictionary *connected = [NSMutableDictionary new];
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) != KERN_SUCCESS) return connected;
    io_service_t node;
    while ((node = IOIteratorNext(iterator))) {
        NSNumber *identity = DBUSBRegistry(node);
        NSNumber *location = DBRegistryProperty(node, CFSTR("locationID"));
        if (identity && location.unsignedIntValue) connected[location] = identity;
        IOObjectRelease(node);
    }
    IOObjectRelease(iterator);
    return connected;
}

static DBSmartCapture *DBBridgeForMedia(io_registry_entry_t node) {
    // A synthesized APFS volume can be several levels below its physical USB media.
    NSString *disk = nil;
    DBSmartCapture *capture = nil;
    while (node) {
        if (IOObjectConformsTo(node, kIOMediaClass) && [DBRegistryProperty(node, CFSTR(kIOMediaWholeKey)) boolValue]) {
            disk = DBRegistryProperty(node, CFSTR(kIOBSDNameKey));
        }
        if (IOObjectConformsTo(node, "IOUSBHostDevice")) {
            NSNumber *identity = DBUSBRegistry(node);
            NSNumber *location = DBRegistryProperty(node, CFSTR("locationID"));
            if (identity && location.unsignedIntValue &&
                [disk rangeOfString:@"^disk[0-9]{1,8}$" options:NSRegularExpressionSearch].length) {
                capture = [DBSmartCapture new];
                capture.disk = disk;
                capture.registry = identity;
                capture.location = location;
            }
            IOObjectRelease(node);
            break;
        }
        io_registry_entry_t parent = IO_OBJECT_NULL;
        IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent);
        IOObjectRelease(node);
        node = parent;
    }
    return capture;
}

static NSData *DBSmartRun(NSString *path, NSArray<NSString *> *arguments, NSData *input, int *exitCode) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *output = [NSPipe pipe];
    NSPipe *source = input ? [NSPipe pipe] : nil;
    task.standardOutput = output;
    task.standardInput = source ?: NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return nil;
    if (source) {
        [source.fileHandleForWriting writeData:input error:nil];
        [source.fileHandleForWriting closeFile];
    }
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (exitCode) *exitCode = task.terminationStatus;
    return data;
}

static NSData *DBSmartServiceRequest(NSString *request, int seconds) {
    int connection = socket(AF_UNIX, SOCK_STREAM, 0);
    if (connection < 0) return nil;
    int preventSignal = 1;
    struct timeval timeout = {.tv_sec = seconds};
    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &preventSignal, sizeof preventSignal);
    setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strlcpy(address.sun_path, "/var/run/devicebridge-usb-smart.sock", sizeof address.sun_path);
    uid_t peer;
    gid_t group;
    NSData *result = nil;
    if (connect(connection, (struct sockaddr *)&address, sizeof address) == 0 &&
        getpeereid(connection, &peer, &group) == 0 && peer == 0) {
        NSData *input = [request dataUsingEncoding:NSASCIIStringEncoding];
        ssize_t sent = write(connection, input.bytes, input.length);
        shutdown(connection, SHUT_WR);
        if (sent == (ssize_t)input.length) {
            NSMutableData *response = [NSMutableData new];
            char buffer[4096];
            NSInteger received;
            do {
                received = read(connection, buffer, sizeof buffer);
                if (received > 0) [response appendBytes:buffer length:(NSUInteger)received];
            } while ((received > 0 || (received == -1 && errno == EINTR)) && response.length <= 65536);
            if (received == 0 && response.length && response.length <= 65536) result = response;
        }
    }
    close(connection);
    return result;
}

static BOOL DBSmartServiceReady(void) {
    NSData *reply = DBSmartServiceRequest(@"status\n", 2);
    return [reply isEqual:[@"DeviceBridge USB SMART 1\n" dataUsingEncoding:NSASCIIStringEncoding]];
}

static BOOL DBInstallSmartService(void) {
    NSString *script = @"on run argv\n"
        "set commandLine to \"/bin/bash \" & quoted form of (item 1 of argv) & \" \" & quoted form of (item 2 of argv) & \" \" & quoted form of (item 3 of argv)\n"
        "return do shell script commandLine with administrator privileges\n"
        "end run";
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *installer = [bundle pathForResource:@"install-usb-smart" ofType:@"sh"];
    if (!installer) return NO;
    int result = 1;
    DBSmartRun(@"/usr/bin/osascript", @[@"-e", script, @"--", installer, bundle.bundlePath,
        [@(getuid()) stringValue]], nil, &result);
    return result == 0 && DBSmartServiceReady();
}

static NSDictionary *DBCaptureSnapshot(NSString *helper, DBSmartCapture *capture, NSString **status) {
    NSString *request = [NSString stringWithFormat:@"%@ %@\n", capture.disk, capture.registry];
    NSData *raw = DBSmartServiceRequest(request, 160);
    if (!raw.length) { *status = @"SMART 读取失败"; return nil; }
    int result = 1;
    NSData *decoded = DBSmartRun(helper, @[@"decode"], raw, &result);
    id response = decoded.length && result == 0 ? [NSJSONSerialization JSONObjectWithData:decoded options:0 error:nil] : nil;
    NSDictionary *snapshot = [response isKindOfClass:NSDictionary.class] && [response[@"health"] isKindOfClass:NSDictionary.class] ? response : nil;
    *status = snapshot ? @"插入时已读取" : @"SMART 数据解析失败";
    return snapshot;
}

static BOOL DBMountVolume(NSString *uuid) {
    // UUID stays stable when USB capture causes the BSD disk number to change.
    for (int attempt = 0; attempt < 6; attempt++) {
        int result = 1;
        DBSmartRun(@"/usr/sbin/diskutil", @[@"mount", uuid], nil, &result);
        if (result == 0) return YES;
        [NSThread sleepForTimeInterval:0.5];
    }
    return NO;
}

typedef void (^DBEjectCompletion)(NSError *);

static void DBEjectFinished(DADiskRef disk, DADissenterRef dissenter, void *context) {
    DBEjectCompletion completion = CFBridgingRelease(context);
    NSError *error = nil;
    if (dissenter) {
        NSString *reason = (__bridge NSString *)DADissenterGetStatusString(dissenter);
        error = [NSError errorWithDomain:@"DeviceBridge.Disk" code:DADissenterGetStatus(dissenter)
            userInfo:@{NSLocalizedDescriptionKey:reason.length ? reason : @"macOS 未能弹出硬盘，请关闭正在使用该盘的文件后重试。"}];
    }
    completion(error);
}

static void DBUnmountForEject(DADiskRef disk, DADissenterRef dissenter, void *context) {
    if (dissenter) DBEjectFinished(disk, dissenter, context);
    else DADiskEject(disk, kDADiskEjectOptionDefault, DBEjectFinished, context);
}

@interface DBUSBSmart ()
@property(nonatomic, readwrite) BOOL busy;
@property(nonatomic, readwrite) BOOL serviceReady;
@property(nonatomic, readwrite) NSString *status;

- (DADissenterRef)approveMount:(DADiskRef)disk;
@end

static void DBInventoryChanged(DADiskRef disk, void *context) {
    [(__bridge DBUSBSmart *)context refreshInventory];
}
static void DBVolumeChanged(DADiskRef disk, CFArrayRef keys, void *context) {
    DBInventoryChanged(disk, context);
}
static DADissenterRef DBApproveMount(DADiskRef disk, void *context) {
    return [(__bridge DBUSBSmart *)context approveMount:disk];
}

@implementation DBUSBSmart {
    DASessionRef _session;
    NSString *_helper;
    NSMutableDictionary<NSNumber *, NSNumber *> *_seen;
    DBSmartCapture *_capture;
    BOOL _enabled;
    BOOL _inventoryScheduled;
    BOOL _inventoryLoading;
    NSUInteger _inventoryGeneration;
    NSArray<NSDictionary *> *_builtInAndExternalDrives;
    NSMutableDictionary<NSNumber *, NSDictionary *> *_snapshotsByRegistry;
    NSNumber *_statusRegistry;
    NSNumber *_ejectingID;
}

@synthesize busy = _busy;

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _helper = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/devicebridge-usb-smart"];
    _status = @"尚无 SMART 读数";
    _seen = [NSMutableDictionary new];
    _builtInAndExternalDrives = @[];
    _snapshotsByRegistry = [NSMutableDictionary new];
    _serviceReady = DBSmartServiceReady();
    if ([NSFileManager.defaultManager isExecutableFileAtPath:_helper]) {
        _session = DASessionCreate(kCFAllocatorDefault);
        if (_session) {
            DARegisterDiskMountApprovalCallback(_session, kDADiskDescriptionMatchVolumeMountable, DBApproveMount, (__bridge void *)self);
            DARegisterDiskAppearedCallback(_session, kDADiskDescriptionMatchMediaWhole, DBInventoryChanged, (__bridge void *)self);
            DARegisterDiskDisappearedCallback(_session, kDADiskDescriptionMatchMediaWhole, DBInventoryChanged, (__bridge void *)self);
            NSArray *volumeKeys = @[(__bridge NSString *)kDADiskDescriptionVolumeNameKey,
                                     (__bridge NSString *)kDADiskDescriptionVolumePathKey];
            DARegisterDiskDescriptionChangedCallback(_session, kDADiskDescriptionMatchVolumeMountable,
                (__bridge CFArrayRef)volumeKeys, DBVolumeChanged, (__bridge void *)self);
            DASessionSetDispatchQueue(_session, dispatch_get_main_queue());
        }
    }
    return self;
}

- (void)dealloc {
    if (_session) {
        DAUnregisterCallback(_session, DBApproveMount, (__bridge void *)self);
        DAUnregisterCallback(_session, DBInventoryChanged, (__bridge void *)self);
        DAUnregisterCallback(_session, DBVolumeChanged, (__bridge void *)self);
        DASessionSetDispatchQueue(_session, NULL);
        CFRelease(_session);
    }
}

- (BOOL)available { return _session != NULL; }
- (BOOL)enabled { return _enabled; }
- (BOOL)busy { return _busy || _ejectingID != nil; }

- (void)ejectDrive:(NSNumber *)mediaID completion:(void (^)(NSError *))completion {
    if (!_session || self.busy || !mediaID.unsignedLongLongValue) return;
    io_service_t media = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(mediaID.unsignedLongLongValue));
    DADiskRef disk = media && IOObjectConformsTo(media, kIOMediaClass)
        ? DADiskCreateFromIOMedia(kCFAllocatorDefault, _session, media) : NULL;
    if (media) IOObjectRelease(media);
    NSDictionary *description = disk ? CFBridgingRelease(DADiskCopyDescription(disk)) : nil;
    if (![description[(__bridge NSString *)kDADiskDescriptionMediaWholeKey] isEqual:@YES] ||
        ![description[(__bridge NSString *)kDADiskDescriptionDeviceInternalKey] isEqual:@NO]) {
        if (disk) CFRelease(disk);
        [self refreshInventory];
        completion([NSError errorWithDomain:@"DeviceBridge.Disk" code:kDAReturnNotFound
            userInfo:@{NSLocalizedDescriptionKey:@"找不到可弹出的外置硬盘。"}]);
        return;
    }

    _ejectingID = mediaID;
    if (self.changed) self.changed();
    DBEjectCompletion finished = ^(NSError *error) {
        self->_ejectingID = nil;
        if (!error) {
            self->_inventoryGeneration++;
            NSArray *drives = self->_builtInAndExternalDrives;
            self->_builtInAndExternalDrives = [drives filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(NSDictionary *drive, NSDictionary *bindings) {
                    return ![drive[@"ejectID"] isEqual:mediaID];
                }]];
        }
        [self refreshInventory];
        if (self.changed) self.changed();
        completion(error);
    };
    DADiskUnmount(disk, kDADiskUnmountOptionWhole, DBUnmountForEject, (__bridge_retained void *)[finished copy]);
    CFRelease(disk);
}

- (NSArray<NSDictionary *> *)drives {
    NSMutableArray *rows = [NSMutableArray new];
    for (NSDictionary *drive in _builtInAndExternalDrives) {
        NSNumber *registry = drive[@"registry"];
        NSDictionary *snapshot = registry ? _snapshotsByRegistry[registry] : nil;
        BOOL hasStatus = [registry isEqual:_statusRegistry];
        if (!snapshot && !hasStatus && !drive[@"ejectID"]) {
            [rows addObject:drive];
            continue;
        }
        NSMutableDictionary *row = [drive mutableCopy];
        if (snapshot) {
            row[@"name"] = snapshot[@"model"];
            row[@"health"] = snapshot[@"health"];
            row[@"captured_unix"] = snapshot[@"captured_unix"];
            row[@"usbSnapshot"] = @YES;
        }
        if (hasStatus) row[@"captureStatus"] = _status;
        if (drive[@"ejectID"]) {
            row[@"ejectDisabled"] = @(self.busy);
            row[@"ejecting"] = @([drive[@"ejectID"] isEqual:_ejectingID]);
        }
        [rows addObject:row];
    }
    return rows;
}

- (void)refreshInventory {
    if (_inventoryScheduled || !_session) return;
    _inventoryScheduled = YES;
    if (_inventoryLoading) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        self->_inventoryScheduled = NO;
        self->_inventoryLoading = YES;
        NSUInteger generation = self->_inventoryGeneration;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int result = 1;
            NSData *data = DBSmartRun(self->_helper, @[@"inventory"], nil, &result);
            id response = data.length && result == 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSArray *drives = [response isKindOfClass:NSDictionary.class] && [response[@"drives"] isKindOfClass:NSArray.class] ? response[@"drives"] : nil;
            NSMutableArray *rows = [NSMutableArray new];
            for (NSDictionary *drive in drives) {
                NSMutableDictionary *row = [drive mutableCopy];
                if (![drive[@"internal"] boolValue]) {
                    const char *name = [drive[@"id"] UTF8String];
                    io_service_t media = name ? IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, name)) : IO_OBJECT_NULL;
                    if (media) {
                        uint64_t identity = 0;
                        if (IOObjectConformsTo(media, kIOMediaClass) && [DBRegistryProperty(media, CFSTR(kIOMediaWholeKey)) isEqual:@YES] &&
                            IORegistryEntryGetRegistryEntryID(media, &identity) == KERN_SUCCESS && identity)
                            row[@"ejectID"] = @(identity);
                        if ([drive[@"bus"] isEqual:@"USB"]) row[@"registry"] = DBBridgeForMedia(media).registry;
                        else IOObjectRelease(media);
                    }
                }
                [rows addObject:row];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (drives && generation == self->_inventoryGeneration) {
                    self->_builtInAndExternalDrives = rows;
                    if (!self.busy) {
                        NSSet *connected = [NSSet setWithArray:DBConnectedBridges().allValues];
                        for (NSNumber *registry in self->_snapshotsByRegistry.allKeys)
                            if (![connected containsObject:registry]) [self->_snapshotsByRegistry removeObjectForKey:registry];
                    }
                    if (self.changed) self.changed();
                }
                self->_inventoryLoading = NO;
                if (self->_inventoryScheduled) {
                    self->_inventoryScheduled = NO;
                    [self refreshInventory];
                }
            });
        });
    });
}

- (void)prepareService:(void (^)(BOOL ready))completion {
    if (_serviceReady) { completion(YES); return; }
    if (self.busy || !_session) { completion(NO); return; }
    _busy = YES;
    _status = @"等待一次性管理员授权…";
    if (self.changed) self.changed();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ready = DBSmartServiceReady() || DBInstallSmartService();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.serviceReady = ready;
            self.busy = NO;
            self.status = ready ? @"尚无 SMART 读数" : @"SMART 后台组件未启用";
            completion(ready);
            if (self.changed) self.changed();
        });
    });
}

- (void)setEnabled:(BOOL)enabled {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (enabled) [_seen addEntriesFromDictionary:DBConnectedBridges()];
}

- (DADissenterRef)approveMount:(DADiskRef)disk {
    if ((!_enabled || !_serviceReady) && !_capture) return NULL;
    NSDictionary *description = CFBridgingRelease(DADiskCopyDescription(disk));
    id uuid = description[(__bridge NSString *)kDADiskDescriptionVolumeUUIDKey];
    if (!uuid || CFGetTypeID((__bridge CFTypeRef)uuid) != CFUUIDGetTypeID()) return NULL;
    NSString *volume = CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, (__bridge CFUUIDRef)uuid));
    DBSmartCapture *target = DBBridgeForMedia(DADiskCopyIOMedia(disk));
    if (!target) return NULL;
    if (_capture) {
        if (![_capture.location isEqual:target.location]) return NULL;
        [_capture.volumes addObject:volume];
    } else {
        if (!_enabled || self.busy || [_seen[target.location] isEqual:target.registry]) return NULL;
        _seen[target.location] = target.registry;
        target.volumes = [NSMutableSet setWithObject:volume];
        _capture = target;
        _statusRegistry = target.registry;
        _busy = YES;
        _status = @"正在读取 SMART…";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.changed) self.changed();
            [self readCapture:target];
        });
    }
    return DADissenterCreate(kCFAllocatorDefault, kDAReturnNotReady, CFSTR("DeviceBridge 正在读取 SMART"));
}

- (void)readCapture:(DBSmartCapture *)capture {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *status;
        NSDictionary *snapshot = DBCaptureSnapshot(self->_helper, capture, &status);
        NSDictionary *connected = DBConnectedBridges();
        dispatch_async(dispatch_get_main_queue(), ^{
            // Approve mounts before asking Disk Arbitration to retry vetoed volumes.
            NSNumber *current = connected[capture.location];
            if (current) self->_seen[capture.location] = current;
            self->_statusRegistry = current ?: capture.registry;
            NSArray *volumes = capture.volumes.allObjects;
            self->_capture = nil;
            self.status = @"正在恢复卷挂载…";
            if (self.changed) self.changed();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                BOOL mounted = YES;
                for (NSString *volume in volumes) mounted = DBMountVolume(volume) && mounted;
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.busy = NO;
                    if (snapshot) self->_snapshotsByRegistry[self->_statusRegistry] = snapshot;
                    self.status = mounted ? status : [status stringByAppendingString:@"，卷未能自动挂载"];
                    [self refreshInventory];
                    if (self.changed) self.changed();
                });
            });
        });
    });
}
@end
