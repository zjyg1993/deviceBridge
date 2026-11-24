#import <Cocoa/Cocoa.h>
#import "Display.h"
#import "NativeBrightnessBridge.h"
@interface BBFakeDDC:NSObject<DBBrightnessTransport>
@property NSDictionary*identity;
@property int writes;
@property uint16_t value;
@property BOOL failedRead;
@property BOOL ignoreWrite;
@property BOOL noVolume;
@property BOOL failedWrite;
@property(copy) void(^onWrite)(uint16_t);
@property NSData *nativeEDID;
@property NSData *factoryEDID;
- (NSDictionary*)read:(uint8_t)code;
- (BOOL)write:(uint8_t)code value:(uint16_t)value;
@end
@implementation BBFakeDDC
- (NSData*)brightnessEDID {return _nativeEDID;}
- (IOReturn)setBrightnessEDID:(NSData*)edid {_nativeEDID=edid?:_factoryEDID;return kIOReturnSuccess;}
- (NSDictionary*)read:(uint8_t)code {return (_failedRead||(_noVolume&&code==0x62))?nil:@{@"current":@(_value),@"maximum":@255,@"percent":@(100.0*_value/255)};}
- (BOOL)write:(uint8_t)code value:(uint16_t)value {_writes++;if(_failedWrite)return NO;if(!_ignoreWrite)_value=value;if(_onWrite)_onWrite(value);return YES;}
@end
@interface BBMemoryDisplayDefaults:NSUserDefaults
@property NSMutableDictionary*values;
@end
@implementation BBMemoryDisplayDefaults
- (instancetype)init {if((self=[super init]))_values=[NSMutableDictionary new];return self;}
- (id)objectForKey:(NSString*)key {return _values[key];}
- (void)setObject:(id)value forKey:(NSString*)key {_values[key]=value;}
- (BOOL)synchronize {return YES;}
@end
@interface BBQuietDisplayController:BBDisplayController
@property NSArray*fixtureScreens;
@property NSArray*fixtureChannels;
@end
@interface BBDisplayController (Testing)
- (void)adjustKey:(int)key record:(NSDictionary*)record;
- (void)updateSystemControls;
- (BOOL)hasActiveMediaKeyTap;
- (void)rescanPeriodically:(NSTimer*)timer;
@end
@implementation BBQuietDisplayController
- (NSArray*)connectedScreens {return _fixtureScreens?:@[];}
- (NSArray*)displayChannels {return _fixtureChannels?:@[];}
- (NSArray*)audioOutputs {return @[];}
- (void)showHUD:(NSString*)name feature:(NSString*)feature percent:(double)percent {}
@end
@interface BBPermissionProbe:BBDisplayController
@property int permissionFixture;
@property int settingsOpened;
@property int accessRequested;
@end
@implementation BBPermissionProbe
- (int)deviceControlAccess {return _permissionFixture;}
- (BOOL)openMediaKeySettings {_settingsOpened++;return YES;}
- (void)requestMediaKeyAccess {_accessRequested++;}
- (BOOL)accessibilityAuthorized {return NO;}
- (BOOL)hasActiveMediaKeyTap {return NO;}
- (void)updateSystemControls {} // Never installs a real event tap during tests.
@end
@interface BBFixtureBrightnessEndpoint:NSObject<DBBrightnessEndpoint>
@property(copy) void(^handler)(double);
@property BOOL stopped;
@end
@implementation BBFixtureBrightnessEndpoint
- (BOOL)startWithContainer:(NSString*)uuid name:(NSString*)name percent:(double)percent handler:(void(^)(double))handler error:(NSError**)error {_handler=[handler copy];return YES;}
- (void)setConfirmedPercent:(double)percent {}
- (void)stop {_stopped=YES;_handler=nil;}
@end
@interface BBFixtureBrightnessBinding:DBNativeBrightnessBinding
@end
@implementation BBFixtureBrightnessBinding
- (NSDictionary*)systemCapability {return @{@"available":@YES};}
- (NSTimeInterval)verificationDelay {return .01;}
@end
@interface BBNativeDisplayFixture:BBQuietDisplayController
@property BBFixtureBrightnessEndpoint *nativeEndpoint;
@property BOOL denyEntitlement;
@property NSUserDefaults *testPreferences;
@end
@implementation BBNativeDisplayFixture
- (BOOL)nativeBrightnessEntitled {return !self.denyEntitlement;}
- (DBNativeBrightnessBinding*)newNativeBinding:(NSDictionary*)record {
    self.nativeEndpoint=[BBFixtureBrightnessEndpoint new];
    return [[BBFixtureBrightnessBinding alloc]initWithIdentity:record[@"identity"] displayID:[record[@"displayID"] unsignedIntValue] name:record[@"name"] preferences:_testPreferences queue:[self valueForKey:@"queue"] endpoint:_nativeEndpoint];
}
@end
static void check(BOOL ok,const char*message){if(!ok){fprintf(stderr,"FAIL: %s\n",message);exit(1);}}
static void settle(void){[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.25]];}
int main(void){@autoreleasepool{
    BBMemoryDisplayDefaults*preferences=[BBMemoryDisplayDefaults new];
    BBQuietDisplayController*c=[[BBQuietDisplayController alloc]initWithDefaults:preferences];[c setValue:@YES forKey:@"running"];
    BBFakeDDC*bus=[BBFakeDDC new];bus.value=128;
    NSMutableDictionary*record=[@{@"identity":@"display:test",@"name":@"DELL S2725QS",@"brightness":[bus read:0x10]} mutableCopy];
    NSMutableDictionary*channels=[c valueForKey:@"channels"],*records=[c valueForKey:@"records"];channels[@"display:test"]=bus;records[@"display:test"]=record;
    [c setPercent:10 code:0x10 identity:@"display:test"];[c setPercent:80 code:0x10 identity:@"display:test"];settle();
    check(bus.writes==1&&bus.value==204,"coalesce rapid slider changes and respect maximum 255");
    check([c.snapshot.firstObject[@"brightness"][@"current"] intValue]==204,"publish confirmed reading");
    NSDictionary*previous=c.snapshot.firstObject;
    [c setPercent:200 code:0x10 identity:@"display:test"];settle();
    check(bus.value==255,"clamp out-of-range request");
    check([previous[@"brightness"][@"current"] intValue]==204,"published snapshots stay immutable");
    int before=bus.writes;
    [c setPercent:20 code:0x62 identity:@"display:test"];[c setPercent:20 code:0x10 identity:@"missing"];[c setPercent:NAN code:0x10 identity:@"display:test"];settle();
    check(bus.writes==before,"unsupported controls, unknown displays and NaN never write");
    [c setPercent:10 code:0x10 identity:@"display:test"];[c setValue:@1 forKey:@"generation"];settle();
    check(bus.writes==before,"topology change cancels queued writes");
    bus.ignoreWrite=YES;[c setPercent:20 code:0x10 identity:@"display:test"];settle();
    check([c.snapshot.firstObject[@"status"] containsString:@"未应用"],"do not claim success when panel ignores write");
    check(!c.snapshot.firstObject[@"brightness"],"ignored write disables the feature");
    before=bus.writes;[c setPercent:30 code:0x10 identity:@"display:test"];settle();check(bus.writes==before,"blocked control cannot write again");
    record[@"brightness"]=[bus read:0x10];[record removeObjectForKey:@"brightnessError"];
    bus.failedRead=YES;[c setPercent:20 code:0x10 identity:@"display:test"];settle();
    check(!c.snapshot.firstObject[@"brightness"]&&[c.snapshot.firstObject[@"status"] containsString:@"失败"],"failed readback disables stale control");
    BBDisplayRow*row=[[BBDisplayRow alloc]initWithFrame:NSMakeRect(0,0,510,96) record:@{@"name":@"Dell",@"brightness":@{@"percent":@40}}];
    NSEvent *rightClick=[NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];
    NSMenu *injected=[NSMenu new];[injected addItemWithTitle:@"删除" action:NULL keyEquivalent:@""];row.menu=injected;
    check([row menuForEvent:rightClick]==nil,"online display never exposes a deletion menu");
    BBDisplayRow *offline=[[BBDisplayRow alloc]initWithFrame:NSMakeRect(0,0,510,96) record:@{@"connected":@NO,@"identity":@"display:test"}];offline.menu=injected;
    check([offline menuForEvent:rightClick]==nil,"disconnected display never exposes a deletion menu");
    check(row.brightnessSlider.enabled&&!row.volumeSlider.enabled,"brightness and volume capabilities are independent");
    // Reload through the same in-memory preference store; never modify real preferences.
    check(![c mappingEnabledForIdentity:@"display:test"],"new displays default to mapping disabled");
    [c setMappingEnabled:YES identity:@"display:test"];settle();
    BBDisplayController*reloaded=[[BBQuietDisplayController alloc]initWithDefaults:preferences];
    check([reloaded mappingEnabledForIdentity:@"display:test"],"mapping choice persists across controller restarts");
    bus.failedRead=NO;bus.ignoreWrite=NO;bus.identity=@{@"name":@"DELL S2725QS"};
    c.fixtureScreens=@[@{@"identity":@"display:test",@"name":@"DELL S2725QS",@"displayID":@1}];c.fixtureChannels=@[bus];
    [c refreshControls];check(c.snapshot.count==1,"refresh never clears the visible row");settle();
    check(c.snapshot.count==1&&[c.snapshot.firstObject[@"connected"] boolValue]&&c.snapshot.firstObject[@"volume"],"scan refreshes both capabilities in place");
    // Hold a rejected older write in flight while a drag supplies newer goals.
    dispatch_semaphore_t firstWrite=dispatch_semaphore_create(0),resumeWrite=dispatch_semaphore_create(0);
    bus.ignoreWrite=YES;
    bus.onWrite=^(uint16_t value){
        if(value!=51)return;
        dispatch_semaphore_signal(firstWrite);
        dispatch_semaphore_wait(resumeWrite,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC));
    };
    before=bus.writes;
    [c setPercent:20 code:0x10 identity:@"display:test"];
    check(!dispatch_semaphore_wait(firstWrite,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"older write starts");
    [c setPercent:55 code:0x10 identity:@"display:test"];
    [c rescanPeriodically:nil];
    [c setPercent:85 code:0x10 identity:@"display:test"];
    check(c.discoveryFinished&&[[c pendingBrightnessForIdentity:@"display:test"] isEqual:@85],"periodic scan waits and latest goal is exposed immediately");
    bus.ignoreWrite=NO;dispatch_semaphore_signal(resumeWrite);settle();
    check(bus.writes==before+2&&bus.value==217&&!c.snapshot.firstObject[@"brightnessError"]&&![c pendingBrightnessForIdentity:@"display:test"],"superseded write failure does not block the final goal or publish an error");
    check(c.discoveryFinished&&[c.snapshot.firstObject[@"brightness"][@"current"] intValue]==217,"deferred scan reads the final value without reverting");
    bus.onWrite=nil;
    before=bus.writes;
    [c rescanPeriodically:nil];
    check(!c.discoveryFinished&&[c.snapshot.firstObject[@"brightness"][@"current"] intValue]==217,"periodic scan keeps the last known brightness visible");
    [c setPercent:65 code:0x10 identity:@"display:test"];
    [c setPercent:70 code:0x10 identity:@"display:test"];settle();
    check(bus.writes==before+1&&bus.value==179&&[c.snapshot.firstObject[@"brightness"][@"current"] intValue]==179,"latest input during a scan writes through the rediscovered channel");
    [c rescan];[c rescan];check(c.snapshot.count==1,"overlapping reconfiguration scans keep rows visible");settle();settle();
    check(c.snapshot.count==1&&[c.snapshot.firstObject[@"mappingEnabled"] boolValue],"overlapping scans finish with the current mapping");
    c.fixtureScreens=@[];[c rescan];check(c.snapshot.count==1,"empty enumeration does not immediately hide a known display");settle();
    check(c.snapshot.count==1&&![c.snapshot.firstObject[@"connected"] boolValue]&&!c.snapshot.firstObject[@"brightness"],"offline row is retained without writable stale values");
    before=bus.writes;[c setPercent:50 code:0x10 identity:@"display:test"];settle();check(bus.writes==before,"offline retained row cannot write");
    c.fixtureScreens=@[@{@"identity":@"display:test",@"name":@"DELL S2725QS",@"displayID":@1}];[c rescan];settle();
    check(c.snapshot.count==1&&[c.snapshot.firstObject[@"connected"] boolValue]&&[c mappingEnabledForIdentity:@"display:test"],"reconnection restores the same row and mapping choice");
    before=bus.writes;[c adjustKey:3 record:c.snapshot.firstObject];[c setMappingEnabled:NO identity:@"display:test"];settle();
    check(bus.writes==before,"disabling mapping cancels pending media-key writes");
    [c adjustKey:3 record:c.snapshot.firstObject];settle();check(bus.writes==before,"disabled mapping never forwards media-key commands");
    [c setPercent:30 code:0x10 identity:@"display:test"];settle();check(bus.writes==before+1,"manual control stays available with mapping off");
    [c setMappingEnabled:YES identity:@"display:test"];settle();before=bus.writes;[c adjustKey:3 record:c.snapshot.firstObject];settle();
    check(bus.writes==before+1,"enabled mapping forwards media-key commands");
    // A brand with no volume VCP remains fully usable for brightness.
    bus.noVolume=YES;[c refreshControls];settle();
    BBDisplayRow *partial=[[BBDisplayRow alloc]initWithFrame:NSMakeRect(0,0,510,96) record:c.snapshot.firstObject];
    check(partial.brightnessSlider.enabled&&!partial.volumeSlider.enabled,"unsupported volume is visibly disabled");
    before=bus.writes;[c setPercent:80 code:0x62 identity:@"display:test"];[c adjustKey:0 record:c.snapshot.firstObject];[c adjustKey:7 record:c.snapshot.firstObject];settle();
    check(bus.writes==before,"no volume VCP blocks slider, media volume and mute");
    bus.noVolume=NO;[c refreshControls];settle();
    bus.ignoreWrite=YES;[c setPercent:95 code:0x62 identity:@"display:test"];settle();
    check(!c.snapshot.firstObject[@"volume"]&&c.snapshot.firstObject[@"volumeError"],"ignored volume SET removes control");
    before=bus.writes;[c rescan];settle();
    check(c.snapshot.firstObject[@"volumeError"]!=nil,"automatic scan preserves rejected-write lockout");
    partial=[[BBDisplayRow alloc]initWithFrame:NSMakeRect(0,0,510,96) record:c.snapshot.firstObject];
    check(!partial.volumeSlider.enabled&&partial.brightnessSlider.enabled,"readable but rejected volume stays disabled independently");
    [c setPercent:50 code:0x62 identity:@"display:test"];[c adjustKey:1 record:c.snapshot.firstObject];[c adjustKey:7 record:c.snapshot.firstObject];settle();
    check(bus.writes==before,"all volume entry points respect write lockout");
    bus.ignoreWrite=NO;[c refreshControls];settle();
    check(!c.snapshot.firstObject[@"volumeError"],"explicit refresh retries rejected feature");
    bus.failedWrite=YES;[c setPercent:25 code:0x62 identity:@"display:test"];settle();
    check(!c.snapshot.firstObject[@"volume"]&&c.snapshot.firstObject[@"volumeError"],"transport write failure blocks volume");
    bus.failedWrite=NO;[c refreshControls];settle();
    bus.failedRead=YES;[c setPercent:70 code:0x62 identity:@"display:test"];settle();
    check(!c.snapshot.firstObject[@"volume"],"failed volume readback disables volume");
    before=bus.writes;[c setPercent:30 code:0x62 identity:@"display:test"];[c adjustKey:7 record:c.snapshot.firstObject];settle();
    check(bus.writes==before,"failed readback blocks subsequent volume and mute writes");
    bus.failedRead=NO;[c refreshControls];
    partial=[[BBDisplayRow alloc]initWithFrame:NSMakeRect(0,0,510,96) record:c.snapshot.firstObject];
    check(!partial.volumeSlider.enabled&&!partial.brightnessSlider.enabled,"scan visibly disables stale controls");settle();
    // Anonymous fallback cannot override a known physical identity conflict.
    bus.identity=@{@"serial":@99};c.fixtureScreens=@[@{@"identity":@"display:test",@"serial":@42}];[c rescan];settle();
    check(!records[@"display:test"][@"volume"],"single port fallback rejects conflicting serial");
    // Identical models are controllable only with unique physical locations.
    BBFakeDDC *second=[BBFakeDDC new];second.identity=@{@"name":@"Generic Monitor",@"location":@"port-B"};
    bus.identity=@{@"name":@"Generic Monitor",@"location":@"port-A"};
    c.fixtureScreens=@[@{@"identity":@"display:A",@"name":@"Generic Monitor",@"location":@"port-A"},@{@"identity":@"display:B",@"name":@"Generic Monitor",@"location":@"port-B"}];
    c.fixtureChannels=@[second,bus];[c rescan];settle();
    check(records[@"display:A"][@"brightness"]&&records[@"display:B"][@"brightness"],"identical models matched by location regardless of port order");
    bus.identity=@{@"name":@"Generic Monitor"};second.identity=bus.identity;[c rescan];settle();
    check(!records[@"display:A"][@"brightness"]&&!records[@"display:B"][@"brightness"],"ambiguous identical monitors never acquire writable channels");
    [c setValue:@NO forKey:@"running"];
    BBPermissionProbe *probe=[[BBPermissionProbe alloc]initWithDefaults:[BBMemoryDisplayDefaults new]];[probe setValue:@YES forKey:@"running"];
    probe.permissionFixture=0;[probe refreshMediaKeyAuthorization];settle();check(probe.mediaKeysAuthorized,"asynchronous IOKit grant recognized with AX false");
    probe.permissionFixture=1;[probe setValue:@0 forKey:@"lastPermissionCheck"];[probe refreshMediaKeyAuthorization];settle();check(!probe.mediaKeysAuthorized,"asynchronous revocation recognized");
    [probe authorizeMediaKeys];settle();
    check(probe.settingsOpened==1&&probe.accessRequested==1,"denied authorization opens Settings and requests access without blocking UI");
    probe.permissionFixture=0;[probe setValue:@0 forKey:@"lastPermissionCheck"];[probe refreshMediaKeyAuthorization];settle();
    [probe authorizeMediaKeys];settle();
    check(probe.settingsOpened==1&&probe.accessRequested==1,"granted authorization does not reopen Settings or request again");
    [probe setValue:@NO forKey:@"running"];
    BBMemoryDisplayDefaults *firstLaunchDefaults=[BBMemoryDisplayDefaults new];
    BBPermissionProbe *firstLaunch=[[BBPermissionProbe alloc]initWithDefaults:firstLaunchDefaults];[firstLaunch setValue:@YES forKey:@"running"];firstLaunch.permissionFixture=1;
    [firstLaunch beginMediaKeyOnboarding];[firstLaunch beginMediaKeyOnboarding];settle();settle();
    check(firstLaunch.accessRequested==1&&firstLaunch.settingsOpened==0,"first launch requests shortcut permission once without forcing Settings open");
    [firstLaunch beginMediaKeyOnboarding];settle();check(firstLaunch.accessRequested==1,"refreshes cannot repeat first-launch system prompt");
    BBPermissionProbe *nextLaunch=[[BBPermissionProbe alloc]initWithDefaults:firstLaunchDefaults];[nextLaunch setValue:@YES forKey:@"running"];nextLaunch.permissionFixture=1;[nextLaunch beginMediaKeyOnboarding];settle();
    check(nextLaunch.accessRequested==0,"completed onboarding persists across app launches and upgrades");
    BBMemoryDisplayDefaults *upgradeDefaults=[BBMemoryDisplayDefaults new];
    [upgradeDefaults setObject:@"42" forKey:@"MediaKeyPermissionRequestedBuild"];
    BBPermissionProbe *upgrade=[[BBPermissionProbe alloc]initWithDefaults:upgradeDefaults];[upgrade setValue:@YES forKey:@"running"];upgrade.permissionFixture=1;
    [upgrade beginMediaKeyOnboarding];settle();
    check(upgrade.accessRequested==0&&[[upgradeDefaults objectForKey:@"MediaKeyPermissionOnboardingCompleted"] boolValue],"older build marker prevents a startup permission request after upgrade");
    BBPermissionProbe *alreadyGranted=[[BBPermissionProbe alloc]initWithDefaults:[BBMemoryDisplayDefaults new]];[alreadyGranted setValue:@YES forKey:@"running"];alreadyGranted.permissionFixture=0;[alreadyGranted beginMediaKeyOnboarding];settle();
    check(alreadyGranted.accessRequested==0,"already granted shortcut permission causes no startup prompt");
    BBPermissionProbe *readOnly=[[BBPermissionProbe alloc]initWithDefaults:[BBMemoryDisplayDefaults new]];[readOnly setValue:@YES forKey:@"running"];[readOnly setValue:@YES forKey:@"readOnly"];readOnly.permissionFixture=1;[readOnly beginMediaKeyOnboarding];settle();
    check(readOnly.accessRequested==0,"read-only diagnostics never request shortcut permission");
    for(BBPermissionProbe *fixture in @[firstLaunch,nextLaunch,upgrade,alreadyGranted,readOnly])[fixture setValue:@NO forKey:@"running"];
    BBMemoryDisplayDefaults *nativeDefaults=[BBMemoryDisplayDefaults new];[nativeDefaults setObject:@{@"display:native":@YES} forKey:@"MappedDisplays"];
    BBNativeDisplayFixture *nativeController=[[BBNativeDisplayFixture alloc]initWithDefaults:nativeDefaults];nativeController.testPreferences=nativeDefaults;[nativeController setValue:@YES forKey:@"running"];
    uint8_t rawEDID[128]={0,255,255,255,255,255,255,0};rawEDID[8]=0x10;rawEDID[9]=0xac;rawEDID[10]=7;rawEDID[12]=42;uint8_t sum=0;for(int i=0;i<127;i++)sum+=rawEDID[i];rawEDID[127]=-sum;
    NSData *nativeEDID=[NSData dataWithBytes:rawEDID length:128];BBFakeDDC *nativeBus=[BBFakeDDC new];nativeBus.value=128;nativeBus.identity=@{@"vendor":@0x10ac,@"product":@7,@"serial":@42};nativeBus.nativeEDID=nativeBus.factoryEDID=nativeEDID;
    nativeController.fixtureChannels=@[nativeBus];nativeController.fixtureScreens=@[@{@"identity":@"display:native",@"displayID":@999,@"name":@"Test Monitor",@"vendor":@0x10ac,@"product":@7,@"serial":@42}];
    [nativeController rescan];settle();settle();
    check([nativeController.snapshot.firstObject[@"nativeBrightness"][@"available"] boolValue],"native brightness binding integrates with discovered mapped DDC display");
    nativeController.nativeEndpoint.handler(40);settle();settle();
    check(nativeBus.writes==1&&nativeBus.value==102&&[nativeController.snapshot.firstObject[@"nativeBrightness"][@"hardwareWriteConfirmed"] boolValue],"system HID request flows through actual DDC queue, write coalescing and readback acknowledgment");
    __block BOOL nativeRestored=NO;[nativeController prepareForTermination:^(BOOL restored){nativeRestored=restored;}];settle();
    check(nativeRestored&&[nativeBus.nativeEDID isEqual:nativeEDID]&&nativeController.nativeEndpoint.stopped,"app termination waits for native HID removal and EDID restoration");
    [nativeController setValue:@NO forKey:@"running"];
    BBNativeDisplayFixture *unsignedController=[[BBNativeDisplayFixture alloc]initWithDefaults:nativeDefaults];
    unsignedController.denyEntitlement=YES;unsignedController.testPreferences=nativeDefaults;
    unsignedController.fixtureChannels=@[nativeBus];unsignedController.fixtureScreens=nativeController.fixtureScreens;
    [unsignedController setValue:@YES forKey:@"running"];[unsignedController rescan];settle();settle();
    NSDictionary *unsignedState=unsignedController.snapshot.firstObject;
    check(![unsignedState[@"brightnessBridgeAvailable"] boolValue]&&![unsignedState[@"brightnessBridgeEnabled"] boolValue]&&[unsignedState[@"mappingEnabled"] boolValue],"unsigned build reports unavailable bridge while preserving the saved request");
    check(!unsignedController.nativeEndpoint&&[nativeBus.nativeEDID isEqual:nativeEDID]&&[unsignedState[@"nativeBrightness"][@"reason"] length]>0,"missing HID entitlement prevents endpoint creation and EDID mutation and publishes the cause");
    [unsignedController setValue:@NO forKey:@"running"];
    BBMemoryDisplayDefaults *splitDefaults=[BBMemoryDisplayDefaults new];[splitDefaults setObject:@{@"display:split":@YES} forKey:@"MappedDisplays"];
    BBQuietDisplayController *split=[[BBQuietDisplayController alloc]initWithDefaults:splitDefaults];[split setValue:@YES forKey:@"running"];
    [split setValue:@[@{@"identity":@"display:split",@"connected":@YES,@"audioOutputUID":@"hdmi"}] forKey:@"snapshot"];
    [split setVolumeBridgeEnabled:NO identity:@"display:split"];
    check([split mappingEnabledForIdentity:@"display:split"]&&![split volumeBridgeEnabledForIdentity:@"display:split"],"volume switch never disables brightness mapping");
    [split setMappingEnabled:NO identity:@"display:split"];[split setVolumeBridgeEnabled:YES identity:@"display:split"];
    check(![split mappingEnabledForIdentity:@"display:split"]&&[split volumeBridgeEnabledForIdentity:@"display:split"],"brightness switch never disables volume bridge");
    BBQuietDisplayController *persisted=[[BBQuietDisplayController alloc]initWithDefaults:splitDefaults];
    check(![persisted mappingEnabledForIdentity:@"display:split"]&&[persisted volumeBridgeEnabledForIdentity:@"display:split"],"independent bridge states persist across controller creation");
    [split setValue:@NO forKey:@"running"];
    puts("Display controller tests passed");return 0;
}}
