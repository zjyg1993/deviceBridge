#import <Foundation/Foundation.h>

@interface DBUSBSmart : NSObject
@property BOOL enabled;
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) BOOL serviceReady;
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) NSArray<NSDictionary *> *drives;
@property(nonatomic, copy) void (^changed)(void);
- (void)refreshInventory;
- (void)ejectDrive:(NSNumber *)mediaID completion:(void (^)(NSError *error))completion;
- (void)prepareService:(void (^)(BOOL ready))completion;
@end
