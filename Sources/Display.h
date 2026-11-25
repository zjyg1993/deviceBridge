#import <Cocoa/Cocoa.h>

@interface BBDisplayController : NSObject
@property(nonatomic,copy,readonly) NSArray<NSDictionary*> *snapshot;
@property(nonatomic,readonly) BOOL mediaKeysAuthorized;
@property(nonatomic,readonly) BOOL discoveryFinished;
@property(nonatomic,copy) void(^volumeBridgesChanged)(NSArray<NSDictionary*> *rows,BOOL userInitiated);
- (instancetype)initWithDefaults:(NSUserDefaults*)defaults;
- (void)setMappingEnabled:(BOOL)enabled identity:(NSString*)identity;
- (BOOL)mappingEnabledForIdentity:(NSString*)identity;
- (void)setBrightnessBridgeEnabled:(BOOL)enabled identity:(NSString*)identity;
- (void)setVolumeBridgeEnabled:(BOOL)enabled identity:(NSString*)identity;
- (BOOL)volumeBridgeEnabledForIdentity:(NSString*)identity;
- (void)start;
- (void)startReadOnly;
- (void)prepareForTermination:(void(^)(BOOL restored))completion;
- (void)stop;
- (void)rescan;
- (void)refreshControls;
- (void)beginMediaKeyOnboarding;
- (void)authorizeMediaKeys;
- (void)refreshMediaKeyAuthorization;
- (void)setPercent:(double)percent code:(uint8_t)code identity:(NSString*)identity;
- (NSNumber*)pendingBrightnessForIdentity:(NSString*)identity;
@end

@interface BBDisplayRow : NSView
@property NSDictionary *record;
@property(nonatomic,weak) BBDisplayController *controller;
@property NSSlider *brightnessSlider;
@property NSSlider *volumeSlider;
@property NSSwitch *mappingSwitch; // compatibility alias for brightness switch
@property NSSwitch *brightnessBridgeSwitch;
@property NSSwitch *volumeBridgeSwitch;
@property NSButton *refreshButton;
@property BOOL showsSeparator;
@property(nonatomic,readonly,getter=isTrackingBrightness) BOOL trackingBrightness;
@property(nonatomic,readonly,getter=isEditingPercent) BOOL editingPercent;
- (instancetype)initWithFrame:(NSRect)frame record:(NSDictionary*)record;
@end
