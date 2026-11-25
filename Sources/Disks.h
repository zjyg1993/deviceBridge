#import <Foundation/Foundation.h>
#import <DiskArbitration/DiskArbitration.h>

// Run off the main thread. Returns rows and an optional list-level status.
NSDictionary *DBReadDisks(void);

// Returns the live media identity for a whole disk eligible for ejection.
NSNumber *DBDiskEjectIdentifier(DADiskRef disk);
