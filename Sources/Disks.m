#import "Disks.h"
#import <signal.h>
#import <unistd.h>

static NSData *runDiskCommand(NSString *path, NSArray *arguments, BOOL allowNonzero) {
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"DeviceBridge-disk.XXXXXX"];
    char *name = strdup(template.fileSystemRepresentation);
    if (!name) return nil;
    int fd = mkstemp(name);
    if (fd >= 0) unlink(name);
    free(name);
    if (fd < 0) return nil;

    NSFileHandle *output = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    task.standardOutput = output;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *terminatedTask) { dispatch_semaphore_signal(finished); };
    if (![task launchAndReturnError:nil]) return nil;
    if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
        if (task.running) kill(task.processIdentifier, SIGKILL);
        return nil;
    }
    if (task.terminationReason != NSTaskTerminationReasonExit || (!allowNonzero && task.terminationStatus)) return nil;
    if (![output seekToOffset:0 error:nil]) return nil;
    return [output readDataToEndOfFileAndReturnError:nil];
}

static NSDictionary *diskutil(NSArray *arguments) {
    NSData *data = runDiskCommand(@"/usr/sbin/diskutil", arguments, NO);
    return data.length ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil] : nil;
}

static NSString *smartctlPath(void) {
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/smartctl"];
    return [NSFileManager.defaultManager isExecutableFileAtPath:path] ? path : nil;
}

static NSString *diskBytes(double bytes) {
    if (bytes < 0) return @"—";
    NSArray *units = @[@"B", @"KB", @"MB", @"GB", @"TB", @"PB", @"EB", @"ZB", @"YB"];
    NSUInteger unit = 0;
    while (bytes >= 1000 && unit + 1 < units.count) {
        bytes /= 1000;
        unit++;
    }
    return [NSString stringWithFormat:unit ? @"%.2f %@" : @"%.0f %@", bytes, units[unit]];
}

static NSNumber *number(id value) {
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

static double volumeUsed(NSDictionary *info) {
    NSNumber *size = number(info[@"VolumeSize"]);
    NSNumber *free = number(info[@"VolumeFreeSpace"]);
    NSString *mount = info[@"MountPoint"];
    if ((!size || !free) && mount.length) {
        NSDictionary *fs = [NSFileManager.defaultManager attributesOfFileSystemForPath:mount error:nil];
        size = fs[NSFileSystemSize];
        free = fs[NSFileSystemFreeSize];
    }
    return size && free && size.doubleValue >= free.doubleValue ? size.doubleValue - free.doubleValue : -1;
}

static void addAPFSVolumeNames(NSArray *volumes, NSMutableOrderedSet *names) {
    BOOL hasSystemVolume = NO;
    for (NSDictionary *volume in volumes) {
        if ([volume[@"Roles"] containsObject:@"System"]) hasSystemVolume = YES;
    }
    for (NSDictionary *volume in volumes) {
        NSArray *roles = volume[@"Roles"];
        NSString *name = volume[@"Name"];
        if (name.length && (!roles.count || [roles containsObject:@"System"] ||
                            (!hasSystemVolume && [roles containsObject:@"Data"]))) {
            [names addObject:name];
        }
    }
}

static NSString *diskUsage(NSDictionary *disk, NSDictionary *info, NSArray *containers, NSMutableOrderedSet *volumeNames) {
    NSArray *partitions = disk[@"Partitions"];
    if (!partitions.count) partitions = @[disk];
    double used = 0;
    BOOL hasUsage = NO, incomplete = NO;
    for (NSDictionary *partition in partitions) {
        NSString *identifier = partition[@"DeviceIdentifier"];
        NSString *content = partition[@"Content"];
        if (!identifier.length || [content isEqual:@"EFI"]) continue;
        double partUsed = -1;
        if ([content hasPrefix:@"Apple_APFS"]) {
            for (NSDictionary *container in containers) {
                NSArray *stores = container[@"PhysicalStores"];
                BOOL matches = NO;
                for (NSDictionary *store in stores) {
                    if ([store[@"DeviceIdentifier"] isEqual:identifier]) matches = YES;
                }
                if (!matches) continue;
                addAPFSVolumeNames(container[@"Volumes"], volumeNames);
                // A shared APFS container cannot report usage per physical member.
                if (stores.count != 1) break;
                NSNumber *capacity = number(container[@"CapacityCeiling"]);
                NSNumber *free = number(container[@"CapacityFree"]);
                if (capacity && free && capacity.doubleValue >= free.doubleValue) partUsed = capacity.doubleValue - free.doubleValue;
                break;
            }
        } else {
            NSDictionary *volume = [identifier isEqual:disk[@"DeviceIdentifier"]] ? info : diskutil(@[@"info", @"-plist", identifier]);
            NSString *name = volume[@"VolumeName"];
            if (name.length) [volumeNames addObject:name];
            partUsed = volumeUsed(volume);
        }
        if (partUsed >= 0) {
            used += partUsed;
            hasUsage = YES;
        } else {
            incomplete = YES;
        }
    }
    NSNumber *size = number(info[@"TotalSize"]) ?: number(disk[@"Size"]);
    NSString *usedText = hasUsage ? diskBytes(used) : @"—";
    if (hasUsage && incomplete) usedText = [@"≥" stringByAppendingString:usedText];
    return [NSString stringWithFormat:@"%@ / %@", usedText, diskBytes(size ? size.doubleValue : -1)];
}

static NSString *smartCount(NSNumber *count, NSString *unit) {
    return count ? [NSString stringWithFormat:@"%@ %@", count, unit] : @"—";
}

static NSArray *smartMetrics(NSDictionary *smart, NSDictionary *info, NSString *usage) {
    NSDictionary *nvme = smart[@"nvme_smart_health_information_log"];
    NSNumber *read = number(nvme[@"data_units_read"]);
    NSNumber *written = number(nvme[@"data_units_written"]);
    double readBytes = read ? read.doubleValue * 512000 : -1;
    double writtenBytes = written ? written.doubleValue * 512000 : -1;
    NSNumber *wear = number(smart[@"endurance_used"][@"current_percent"]) ?: number(nvme[@"percentage_used"]);
    NSNumber *blockSize = number(smart[@"logical_block_size"]);
    for (NSDictionary *page in smart[@"ata_device_statistics"][@"pages"]) {
        for (NSDictionary *stat in page[@"table"]) {
            NSString *name = stat[@"name"];
            NSNumber *value = number(stat[@"value"]);
            if (!value || ![stat[@"flags"][@"valid"] boolValue]) continue;
            if (readBytes < 0 && blockSize.doubleValue > 0 && [name isEqual:@"Logical Sectors Read"]) readBytes = value.doubleValue * blockSize.doubleValue;
            if (writtenBytes < 0 && blockSize.doubleValue > 0 && [name isEqual:@"Logical Sectors Written"]) writtenBytes = value.doubleValue * blockSize.doubleValue;
            if (!wear && [name isEqual:@"Percentage Used Endurance Indicator"]) wear = value;
        }
    }

    NSNumber *passed = number(smart[@"smart_status"][@"passed"]);
    NSString *status = info[@"SMARTStatus"];
    NSString *health = @"—";
    if ((passed && !passed.boolValue) || [status isEqual:@"Failing"]) health = @"异常";
    else if (wear) health = [NSString stringWithFormat:@"%.0f%%", MAX(0.0, 100.0 - wear.doubleValue)];
    else if (passed.boolValue || [status isEqual:@"Verified"]) health = @"正常";

    NSNumber *temperature = number(smart[@"temperature"][@"current"]) ?: number(nvme[@"temperature"]);
    NSNumber *cycles = number(smart[@"power_cycle_count"]) ?: number(nvme[@"power_cycles"]);
    NSNumber *hours = number(smart[@"power_on_time"][@"hours"]) ?: number(nvme[@"power_on_hours"]);
    return @[diskBytes(readBytes), diskBytes(writtenBytes), usage, smartCount(temperature, @"°C"),
             health, smartCount(cycles, @"次"), smartCount(hours, @"小时")];
}

NSDictionary *DBReadDisks(void) {
    NSDictionary *inventory = diskutil(@[@"list", @"-plist", @"physical"]);
    NSArray *disks = inventory[@"AllDisksAndPartitions"];
    if (!disks) return @{@"rows": @[], @"status": @"无法读取硬盘列表"};
    if (!disks.count) return @{@"rows": @[], @"status": @"未发现硬盘"};

    NSArray *containers = diskutil(@[@"apfs", @"list", @"-plist"])[@"Containers"];
    NSString *smartctl = smartctlPath();
    NSMutableArray *rows = [NSMutableArray new];
    for (NSDictionary *disk in disks) {
        NSString *identifier = disk[@"DeviceIdentifier"];
        if (!identifier.length) continue;
        NSDictionary *info = diskutil(@[@"info", @"-plist", identifier]);
        NSDictionary *smart = nil;
        if (smartctl) {
            // SMART health/error bits can produce a nonzero status with useful JSON.
            NSString *device = [@"/dev/" stringByAppendingString:identifier];
            NSData *data = runDiskCommand(smartctl, @[@"-j", @"-i", @"-H", @"-A", @"-l", @"devstat", device], YES);
            id result = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([result isKindOfClass:NSDictionary.class]) smart = result;
        }
        NSString *model = smart[@"model_name"] ?: info[@"MediaName"];
        NSString *title = model.length ? [NSString stringWithFormat:@"%@ · %@", model, identifier] : identifier;
        NSDictionary *support = smart[@"smart_support"];
        BOOL smartUnavailable = !smart || ([smart[@"smartctl"][@"exit_status"] intValue] & 3) ||
            [support[@"available"] isEqual:@NO] || [support[@"enabled"] isEqual:@NO];
        BOOL external = info[@"Internal"] && ![info[@"Internal"] boolValue];
        NSMutableOrderedSet *volumeNames = [NSMutableOrderedSet orderedSet];
        NSString *usage = diskUsage(disk, info, containers, volumeNames);
        [rows addObject:@{@"title": title, @"external": @(external),
                          @"metrics": smartMetrics(smart, info, usage),
                          @"volumeNames": [volumeNames.array componentsJoinedByString:@"、"],
                          @"smartUnavailable": @(smartUnavailable)}];
    }
    return @{@"rows": rows, @"status": @"未发现硬盘"};
}
