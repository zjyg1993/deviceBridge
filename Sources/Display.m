#import "Display.h"
#import "DisplayDDC.h"
#import "NativeBrightnessBridge.h"
#import "NativeProxyAudio.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <IOKit/i2c/IOI2CInterface.h>
#import <CoreAudio/CoreAudio.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <unistd.h>
#import <math.h>

// IOAVService is an undocumented userspace IOKit SPI. Resolve at runtime so an
// OS without these symbols still launches and reports an unavailable channel.
typedef CFTypeRef (*BBAVCreate)(CFAllocatorRef,io_service_t);
typedef IOReturn (*BBAVI2C)(CFTypeRef,uint32_t,uint32_t,void*,uint32_t);
static BBAVCreate avCreate;static BBAVI2C avRead,avWrite;
static CFDictionaryRef (*displayInfo)(CGDirectDisplayID);
static int (*nativeBrightness)(CGDirectDisplayID,float*);
static void BBLoadDisplayAPIs(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        avCreate=(BBAVCreate)dlsym(RTLD_DEFAULT,"IOAVServiceCreateWithService");
        avRead=(BBAVI2C)dlsym(RTLD_DEFAULT,"IOAVServiceReadI2C");avWrite=(BBAVI2C)dlsym(RTLD_DEFAULT,"IOAVServiceWriteI2C");
        void*core=dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",RTLD_LAZY|RTLD_LOCAL);
        if(core)displayInfo=dlsym(core,"CoreDisplay_DisplayCreateInfoDictionary");
        void*services=dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",RTLD_LAZY|RTLD_LOCAL);
        if(services)nativeBrightness=dlsym(services,"DisplayServicesGetBrightness");
    });
}
#if defined(__arm64__)
static id BBRegistryProperty(io_registry_entry_t entry,NSString*key) {
    return CFBridgingRelease(IORegistryEntryCreateCFProperty(entry,(__bridge CFStringRef)key,kCFAllocatorDefault,0));
}
static NSDictionary *BBRegistryIdentity(io_registry_entry_t entry) {
    NSDictionary*attrs=BBRegistryProperty(entry,@"DisplayAttributes");NSDictionary*p=attrs[@"ProductAttributes"];
    NSMutableDictionary*d=[NSMutableDictionary new];
    NSDictionary*edid=BBEDIDIdentity(BBRegistryProperty(entry,@"IODisplayEDID"));if(edid)[d addEntriesFromDictionary:edid];
    if([p[@"ProductName"] isKindOfClass:NSString.class])d[@"name"]=p[@"ProductName"];
    if([p[@"SerialNumber"] isKindOfClass:NSNumber.class])d[@"serial"]=p[@"SerialNumber"];
    if([p[@"AlphanumericSerialNumber"] isKindOfClass:NSString.class])d[@"textSerial"]=p[@"AlphanumericSerialNumber"];
    io_string_t path;if(IORegistryEntryGetPath(entry,kIOServicePlane,path)==KERN_SUCCESS)d[@"location"]=@(path);
    return d;
}

#endif

@interface BBDDCChannel:NSObject<DBBrightnessTransport>
@property id avService;
@property io_service_t framebuffer;
@property NSDictionary*identity;
@property CFTimeInterval lastOperation;
- (NSDictionary*)read:(uint8_t)code;
- (BOOL)write:(uint8_t)code value:(uint16_t)value;
@end
@implementation BBDDCChannel
- (NSData*)brightnessEDID {return DBBrightnessCopyEDID(_avService);}
- (IOReturn)setBrightnessEDID:(NSData*)edid {return DBBrightnessSetEDID(_avService,edid);}
- (void)dealloc {if(_framebuffer)IOObjectRelease(_framebuffer);}
- (void)gap {CFTimeInterval remaining=.05-(CFAbsoluteTimeGetCurrent()-_lastOperation);if(remaining>0)usleep((useconds_t)(remaining*1000000));}
- (BOOL)exchange:(NSData*)packet reply:(NSMutableData*)reply {
    [self gap];BOOL ok=NO;
    if(_avService&&avWrite&&avRead){
        // IOAVService's offset carries the source address (0x51). The GET
        // checksum omits 0x51 on this transport; SET includes it (MonitorControl).
        NSMutableData*payload=[[packet subdataWithRange:NSMakeRange(1,packet.length-1)] mutableCopy];
        if(reply.length)((uint8_t*)payload.mutableBytes)[payload.length-1]^=0x51;
        ok=avWrite((__bridge CFTypeRef)_avService,0x37,0x51,payload.mutableBytes,(uint32_t)payload.length)==KERN_SUCCESS;
        if(ok&&reply.length){usleep(50000);ok=avRead((__bridge CFTypeRef)_avService,0x37,0,reply.mutableBytes,(uint32_t)reply.length)==KERN_SUCCESS;}
    }else if(_framebuffer){
        IOItemCount count=0;IOFBGetI2CInterfaceCount(_framebuffer,&count);
        for(IOItemCount i=0;i<count&&!ok;i++){
            io_service_t bus=0;if(IOFBCopyI2CInterfaceForBus(_framebuffer,i,&bus)!=KERN_SUCCESS)continue;
            IOI2CConnectRef connection=NULL;
            if(IOI2CInterfaceOpen(bus,0,&connection)==KERN_SUCCESS){
                IOI2CRequest request={0};request.sendAddress=0x6e;request.sendTransactionType=kIOI2CSimpleTransactionType;
                request.sendBuffer=(vm_address_t)packet.bytes;request.sendBytes=(uint32_t)packet.length;
                request.replyTransactionType=kIOI2CNoTransactionType;
                ok=IOI2CSendRequest(connection,0,&request)==KERN_SUCCESS&&request.result==KERN_SUCCESS;
                if(ok&&reply.length){
                    usleep(50000);IOI2CRequest response={0};response.replyAddress=0x6f;response.replyTransactionType=kIOI2CDDCciReplyTransactionType;
                    response.replyBuffer=(vm_address_t)reply.mutableBytes;response.replyBytes=(uint32_t)reply.length;
                    ok=IOI2CSendRequest(connection,0,&response)==KERN_SUCCESS&&response.result==KERN_SUCCESS&&response.replyBytes==reply.length;
                    if(ok)ok=BBDDCParseReply(reply,((const uint8_t*)packet.bytes)[3])!=nil;
                }
                IOI2CInterfaceClose(connection,0);
            }IOObjectRelease(bus);
        }
    }
    _lastOperation=CFAbsoluteTimeGetCurrent();return ok;
}
- (NSDictionary*)read:(uint8_t)code {
    for(int i=0;i<3;i++){
        NSMutableData*reply=[NSMutableData dataWithLength:11];
        if([self exchange:BBDDCRequest(code,nil) reply:reply]){NSDictionary*r=BBDDCParseReply(reply,code);if(r)return r;}
    }return nil;
}
- (BOOL)write:(uint8_t)code value:(uint16_t)value {return [self exchange:BBDDCRequest(code,@(value)) reply:nil];}
@end

static NSArray<BBDDCChannel*> *BBDisplayChannels(void) {
    NSMutableArray*channels=[NSMutableArray new];
#if defined(__arm64__)
    if(!avCreate||!avRead||!avWrite)return channels;
    // Walk the actual registry hierarchy. Metadata belongs to the containing
    // framebuffer, never to an arbitrary first monitor or a USB receiver.
    io_registry_entry_t root=IORegistryGetRootEntry(kIOMainPortDefault);io_iterator_t it=0;
    if(IORegistryEntryCreateIterator(root,kIOServicePlane,kIORegistryIterateRecursively,&it)==KERN_SUCCESS){
        io_registry_entry_t entry;NSDictionary*metadata=@{};
        while((entry=IOIteratorNext(it))){
            io_name_t name;IORegistryEntryGetName(entry,name);
            if(strstr(name,"AppleCLCD2")||strstr(name,"IOMobileFramebufferShim"))metadata=BBRegistryIdentity(entry);
            if(IOObjectConformsTo(entry,"DCPAVServiceProxy")&&[BBRegistryProperty(entry,@"Location") isEqual:@"External"]){
                CFTypeRef service=avCreate(kCFAllocatorDefault,entry);
                if(service){BBDDCChannel*c=[BBDDCChannel new];c.avService=CFBridgingRelease(service);c.identity=metadata;[channels addObject:c];}
                metadata=@{};
            }IOObjectRelease(entry);
        }IOObjectRelease(it);
    }IOObjectRelease(root);
#else
    io_iterator_t it=0;if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOFramebuffer"),&it)==KERN_SUCCESS){
        io_service_t entry;while((entry=IOIteratorNext(it))){
            NSDictionary*info=CFBridgingRelease(IODisplayCreateInfoDictionary(entry,kIODisplayOnlyPreferredName));
            if(info[@"DisplayVendorID"]&&info[@"DisplayProductID"]){
                BBDDCChannel*c=[BBDDCChannel new];IOObjectRetain(entry);c.framebuffer=entry;
                NSDictionary*names=info[@"DisplayProductName"];
                c.identity=@{@"vendor":info[@"DisplayVendorID"],@"product":info[@"DisplayProductID"],@"serial":info[@"DisplaySerialNumber"]?:@0,@"name":names.allValues.firstObject?:@"",@"location":info[@"IODisplayLocation"]?:@""};[channels addObject:c];
            }IOObjectRelease(entry);
        }IOObjectRelease(it);
    }
#endif
    return channels;
}

// Screen enumeration and AppKit stay on the main thread; all I2C runs on queue.
static NSArray<NSDictionary*> *BBConnectedScreens(void) {
    NSMutableArray*result=[NSMutableArray new];
    uint32_t count=0;if(CGGetOnlineDisplayList(0,NULL,&count)!=kCGErrorSuccess||!count)return result;
    NSMutableData*storage=[NSMutableData dataWithLength:count*sizeof(CGDirectDisplayID)];
    if(CGGetOnlineDisplayList(count,storage.mutableBytes,&count)!=kCGErrorSuccess)return result;
    CGDirectDisplayID*displays=storage.mutableBytes;
    for(uint32_t i=0;i<count;i++){
        CGDirectDisplayID display=displays[i];
        if(CGDisplayIsBuiltin(display)||CGDisplayVendorNumber(display)==0x610)continue;
        NSDictionary*info=displayInfo?CFBridgingRelease(displayInfo(display)):@{};
        CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display);NSString*key=uuid?CFBridgingRelease(CFUUIDCreateString(NULL,uuid)):[NSString stringWithFormat:@"session-%u",display];if(uuid)CFRelease(uuid);
        NSDictionary*names=info[@"DisplayProductName"];NSString*model=names[@"en_US"]?:names.allValues.firstObject;
        NSDictionary *edid=BBEDIDIdentity(info[@"IODisplayEDID"]);
        if(!model.length)model=edid[@"name"];
        [result addObject:@{@"identity":[@"display:" stringByAppendingString:key],@"displayID":@(display),@"name":model?:@"外接显示器",@"vendor":@(CGDisplayVendorNumber(display)),@"product":@(CGDisplayModelNumber(display)),@"serial":@(CGDisplaySerialNumber(display)),@"location":info[@"IODisplayLocation"]?:@"",@"textSerial":edid[@"textSerial"]?:@""}];
    }return result;
}

static NSString *BBDefaultDisplayAudioName(void) {
    AudioObjectPropertyAddress a={kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    AudioDeviceID device=0;UInt32 size=sizeof device;if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&size,&device)!=noErr||!device)return nil;
    a.mSelector=kAudioDevicePropertyTransportType;UInt32 transport=0;size=sizeof transport;
    if(AudioObjectGetPropertyData(device,&a,0,NULL,&size,&transport)!=noErr||(transport!=kAudioDeviceTransportTypeHDMI&&transport!=kAudioDeviceTransportTypeDisplayPort))return nil;
    a.mSelector=kAudioDevicePropertyVolumeScalar;a.mScope=kAudioDevicePropertyScopeOutput;
    // A natively controllable output should keep the system's normal handling.
    for(UInt32 element=0;element<=2;element++){a.mElement=element;Boolean settable=false;if(AudioObjectIsPropertySettable(device,&a,&settable)==noErr&&settable)return nil;}
    a=(AudioObjectPropertyAddress){kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    CFStringRef name=NULL;size=sizeof name;if(AudioObjectGetPropertyData(device,&a,0,NULL,&size,&name)!=noErr)return nil;return CFBridgingRelease(name);
}

@interface BBBrightnessRequest : NSObject
@property double percent;
@property NSUInteger generation;
@property BOOL scheduled;
@property NSDictionary *readingBeforeFailure;
@end
@implementation BBBrightnessRequest
@end

@interface BBDisplayController ()
@property(nonatomic,copy,readwrite) NSArray<NSDictionary*> *snapshot;
@property dispatch_queue_t queue;
@property NSMutableDictionary<NSString*,BBDDCChannel*>*channels;
@property NSMutableDictionary<NSString*,NSMutableDictionary*>*records;
@property NSMutableDictionary<NSString*,NSDictionary*>*pending;
// Request replacement, scheduling, and failure handoff share this lock.
@property NSMutableDictionary<NSString*,BBBrightnessRequest*>*brightnessRequests;
@property NSMutableDictionary<NSString*,NSNumber*>*unmuted;
@property NSMutableDictionary<NSString*,NSMutableDictionary*>*controlErrors;
@property NSUserDefaults*preferences;
@property NSMutableDictionary<NSString*,NSNumber*>*mappingChoices;
@property NSMutableDictionary<NSString*,NSNumber*>*volumeChoices;
@property NSTimer*discoveryTimer;
@property NSTimer*systemTimer;
@property BOOL scanning;
@property BOOL periodicScan;
@property BOOL periodicScanDeferred;
@property BOOL readOnly;
@property(nonatomic,readwrite) BOOL discoveryFinished;
@property(atomic) BOOL running;
@property BOOL needsRescan;
@property(atomic) NSUInteger generation;
@property CFMachPortRef eventTap;
@property CFTimeInterval lastEventTapAttempt;
@property dispatch_queue_t permissionQueue;
@property BOOL permissionCheckInFlight;
@property BOOL permissionCheckComplete;
@property IOHIDAccessType deviceControlStatus;
@property BOOL mediaKeyOnboardingPending;
@property CFTimeInterval lastPermissionCheck;
@property CFRunLoopSourceRef eventSource;
@property NSMutableSet<NSNumber*>*consumedKeys;
@property CGDirectDisplayID nativeSource;
@property float nativeLevel;
@property NSPanel*hud;
@property NSTimer*hudTimer;
@property NSMutableDictionary<NSString*,DBNativeBrightnessBinding*> *nativeBindings;
@property NSMutableDictionary<NSString*,NSNumber*> *nativePendingRequests;
@property BOOL nativeBrightnessStopping;
@property NSMutableDictionary<NSString*,NSDate*> *nativeMissingSince;
@end
static CGEventRef BBDisplayKeyEvent(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void*context);
static void BBDisplayReconfigured(CGDirectDisplayID display,CGDisplayChangeSummaryFlags flags,void*context) {
    if(flags&kCGDisplayBeginConfigurationFlag)return;
    BBDisplayController*controller=(__bridge BBDisplayController*)context;
    dispatch_async(dispatch_get_main_queue(),^{[controller rescan];});
}
@implementation BBDisplayController
- (instancetype)init {return [self initWithDefaults:NSUserDefaults.standardUserDefaults];}
- (instancetype)initWithDefaults:(NSUserDefaults*)defaults {
    if((self=[super init])){BBLoadDisplayAPIs();_snapshot=@[];_nativeMissingSince=[NSMutableDictionary new];_nativeBindings=[NSMutableDictionary new];_nativePendingRequests=[NSMutableDictionary new];_queue=dispatch_queue_create("local.devicebridge.ddc",DISPATCH_QUEUE_SERIAL);_channels=[NSMutableDictionary new];_records=[NSMutableDictionary new];_pending=[NSMutableDictionary new];_brightnessRequests=[NSMutableDictionary new];_unmuted=[NSMutableDictionary new];_controlErrors=[NSMutableDictionary new];_consumedKeys=[NSMutableSet new];_nativeLevel=-1;_preferences=defaults;_permissionQueue=dispatch_queue_create("local.devicebridge.permissions",DISPATCH_QUEUE_SERIAL);_deviceControlStatus=kIOHIDAccessTypeUnknown;
        id stored=[defaults objectForKey:@"BrightnessBridgeDisplays"]?:[defaults objectForKey:@"MappedDisplays"];id volume=[defaults objectForKey:@"VolumeBridgeDisplays"];_volumeChoices=[volume isKindOfClass:NSDictionary.class]?[volume mutableCopy]:[NSMutableDictionary new];_mappingChoices=[stored isKindOfClass:NSDictionary.class]?[stored mutableCopy]:[NSMutableDictionary new];
    }return self;
}
- (BOOL)mappingEnabledForIdentity:(NSString*)identity {return [_mappingChoices[identity] boolValue];}
- (void)setMappingEnabled:(BOOL)enabled identity:(NSString*)identity {
    if(_readOnly||!identity.length)return;
    _mappingChoices[identity]=@(enabled);[_preferences setObject:[_mappingChoices copy] forKey:@"BrightnessBridgeDisplays"];
    // Change targeting immediately, including while a slow scan is finishing.
    NSMutableArray*rows=[NSMutableArray new];for(NSDictionary*r in _snapshot){NSMutableDictionary*copy=[r mutableCopy];if([r[@"identity"] isEqual:identity]){copy[@"mappingEnabled"]=@(enabled);copy[@"brightnessBridgeEnabled"]=@(enabled&&[self nativeBrightnessEntitled]);}[rows addObject:copy];}self.snapshot=rows;
    dispatch_async(_queue,^{
        self.records[identity][@"mappingEnabled"]=@(enabled);
        if(!enabled)for(NSString*key in self.pending.allKeys.copy)if([self.pending[key][@"identity"] isEqual:identity]&&[key hasSuffix:@"/16"]&&[self.pending[key][@"bridged"] boolValue])[self.pending removeObjectForKey:key];
        [self publish];
    });
}
- (void)setBrightnessBridgeEnabled:(BOOL)enabled identity:(NSString*)identity {[self setMappingEnabled:enabled identity:identity];}
- (BOOL)volumeBridgeEnabledForIdentity:(NSString*)identity {@synchronized(_volumeChoices){NSNumber *stored=_volumeChoices[identity];return stored?stored.boolValue:YES;}}
- (void)setVolumeBridgeEnabled:(BOOL)enabled identity:(NSString*)identity {
    if(_readOnly||!identity.length)return;
    NSDictionary *found=nil;for(NSDictionary *row in _snapshot)if([row[@"identity"] isEqual:identity])found=row;
    if(enabled&&![found[@"audioOutputUID"] length])return;
    @synchronized(_volumeChoices){_volumeChoices[identity]=@(enabled);[_preferences setObject:[_volumeChoices copy] forKey:@"VolumeBridgeDisplays"];}
    NSMutableArray *rows=[NSMutableArray new];for(NSDictionary *record in _snapshot){NSMutableDictionary *row=[record mutableCopy];if([row[@"identity"] isEqual:identity])row[@"volumeBridgeEnabled"]=@(enabled&&[row[@"audioOutputUID"] length]>0);[rows addObject:row];}self.snapshot=rows;
    if(_volumeBridgesChanged)_volumeBridgesChanged(rows,YES);
    dispatch_async(_queue,^{self.records[identity][@"volumeBridgeEnabled"]=@(enabled);[self publish];});
}
- (NSArray*)audioOutputs {return [[DBSystemAudioBackend new] outputs];}
- (NSArray*)connectedScreens {return BBConnectedScreens();}
- (NSArray*)displayChannels {return BBDisplayChannels();}
- (BOOL)accessibilityAuthorized {return AXIsProcessTrusted();}
- (BOOL)inputMonitoringAuthorized {return CGPreflightListenEventAccess();}
- (BOOL)hasActiveMediaKeyTap {return _eventTap&&CFMachPortIsValid(_eventTap)&&CGEventTapIsEnabled(_eventTap);}
- (IOHIDAccessType)deviceControlAccess {return IOHIDCheckAccess(kIOHIDRequestTypePostEvent);}
- (BOOL)mediaKeysAuthorized {
    // These APIs cover different TCC services. A PostEvent denial must not
    // override Accessibility or a filtering tap that is actually working.
    return [self accessibilityAuthorized]||[self hasActiveMediaKeyTap]||
        (_permissionCheckComplete&&_deviceControlStatus==kIOHIDAccessTypeGranted);
}
- (void)refreshMediaKeyAuthorization {
    if(!_running||_readOnly)return;
    CFTimeInterval now=CFAbsoluteTimeGetCurrent();
    if(!_permissionCheckInFlight&&now-_lastPermissionCheck>=1){
        _permissionCheckInFlight=YES;_lastPermissionCheck=now;
        // TCC IPC must not run inside an event tap callback or block AppKit.
        dispatch_async(_permissionQueue,^{IOHIDAccessType status=[self deviceControlAccess];
            dispatch_async(dispatch_get_main_queue(),^{
                self.permissionCheckInFlight=NO;if(!self.running)return;
                BOOL changed=!self.permissionCheckComplete||self.deviceControlStatus!=status;
                self.deviceControlStatus=status;self.permissionCheckComplete=YES;
                if(changed)self.lastEventTapAttempt=0;
                [self updateSystemControls];
            });
        });
    }
    [self updateSystemControls];
}
- (BOOL)nativeBrightnessEntitled {return DBBrightnessHIDEntitled();}
- (DBNativeBrightnessBinding*)newNativeBinding:(NSDictionary*)record {
    return [[DBNativeBrightnessBinding alloc]initWithIdentity:record[@"identity"] displayID:[record[@"displayID"] unsignedIntValue] name:record[@"name"] preferences:_preferences queue:_queue endpoint:[DBHIDBrightnessEndpoint new]];
}
- (void)publishNativeState:(NSDictionary*)state identity:(NSString*)identity {
    NSMutableArray *rows=[NSMutableArray new];for(NSDictionary *record in _snapshot){NSMutableDictionary *row=[record mutableCopy];if([row[@"identity"] isEqual:identity])row[@"nativeBrightness"]=state;[rows addObject:row];}self.snapshot=rows;
    if([state[@"phase"] isEqual:@"active"])[self flushNativeBrightnessRequests];
}
- (void)requestNativePercent:(double)percent identity:(NSString*)identity {
    if(!_running||_readOnly||_nativeBrightnessStopping||![self mappingEnabledForIdentity:identity])return;
    NSDictionary *record=nil;for(NSDictionary *row in _snapshot)if([row[@"identity"] isEqual:identity])record=row;
    if(_scanning||!BBDisplayControlAvailable(record,0x10)){_nativePendingRequests[identity]=@(percent);return;}
    NSUInteger generation=_generation;
    dispatch_async(_queue,^{if(self.running&&generation==self.generation)[self enqueuePercent:percent code:0x10 identity:identity generation:generation bridged:YES];});
}
- (void)flushNativeBrightnessRequests {
    if(_scanning||_nativeBrightnessStopping)return;
    NSDictionary *pending=[_nativePendingRequests copy];[_nativePendingRequests removeAllObjects];
    for(NSString *identity in pending)[self requestNativePercent:[pending[identity] doubleValue] identity:identity];
}
- (void)syncNativeBrightness:(NSDictionary*)candidates {
    if(_readOnly||_nativeBrightnessStopping||!_running)return;
    for(NSString *identity in _nativeBindings.allKeys.copy)if(!candidates[identity]){
        DBNativeBrightnessBinding *binding=_nativeBindings[identity];
        // EDID application briefly removes the CG/AV endpoints. Keep the HID
        // alive through re-enumeration instead of immediately undoing our bind.
        if([self mappingEnabledForIdentity:identity]){
            NSDate *missing=_nativeMissingSince[identity];
            if(!missing){_nativeMissingSince[identity]=NSDate.date;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(self.running&&self.nativeMissingSince[identity]&&self.nativeBindings[identity]==binding)[self rescan];});continue;}
            if(-missing.timeIntervalSinceNow<15)continue;
        }
        [binding stopWithCompletion:^(BOOL restored){if(restored&&self.nativeBindings[identity]==binding){[self.nativeBindings removeObjectForKey:identity];[self.nativeMissingSince removeObjectForKey:identity];}}];
    }
    for(NSString *identity in candidates){
        [_nativeMissingSince removeObjectForKey:identity];
        NSDictionary *candidate=candidates[identity],*record=candidate[@"record"];DBNativeBrightnessBinding *binding=_nativeBindings[identity];
        if(binding){[binding updateTransport:candidate[@"transport"] edid:candidate[@"edid"] displayID:[record[@"displayID"] unsignedIntValue]];[self publishNativeState:binding.state identity:identity];continue;}
        if(!BBDisplayControlAvailable(record,0x10))continue;
        binding=[self newNativeBinding:record];_nativeBindings[identity]=binding;__weak BBDisplayController *weak=self;
        binding.onPercent=^(double percent){[weak requestNativePercent:percent identity:identity];};
        binding.onState=^(NSDictionary *state){[weak publishNativeState:state identity:identity];};
        [binding startWithEDID:candidate[@"edid"] transport:candidate[@"transport"] percent:[record[@"brightness"][@"percent"] doubleValue]];
    }
}
- (void)prepareForTermination:(void(^)(BOOL))completion {
    _nativeBrightnessStopping=YES;[_nativePendingRequests removeAllObjects];
    NSArray *bindings=_nativeBindings.allValues.copy;dispatch_group_t group=dispatch_group_create();__block BOOL restored=YES;
    for(DBNativeBrightnessBinding *binding in bindings){dispatch_group_enter(group);[binding stopWithCompletion:^(BOOL ok){restored=restored&&ok;dispatch_group_leave(group);}];}
    dispatch_group_notify(group,dispatch_get_main_queue(),^{if(!restored)self.nativeBrightnessStopping=NO;if(completion)completion(restored);});
}
- (void)publish {[self publishForGeneration:self.generation];}
- (void)publishForGeneration:(NSUInteger)generation {
    [self publishForGeneration:generation manualRequest:nil identity:nil];
}
- (void)publishForGeneration:(NSUInteger)generation manualRequest:(BBBrightnessRequest*)request identity:(NSString*)identity {
    NSMutableArray*copies=[NSMutableArray new];for(NSDictionary*r in _records.allValues)[copies addObject:[r copy]];
    NSArray*rows=[copies sortedArrayUsingComparator:^NSComparisonResult(NSDictionary*a,NSDictionary*b){return [a[@"name"] compare:b[@"name"]];}];
    NSMutableDictionary *nativeCandidates=[NSMutableDictionary new];
    if(!_readOnly&&[self nativeBrightnessEntitled])for(NSDictionary *record in rows){
        NSString *identity=record[@"identity"];id channel=_channels[identity];
        if([record[@"mappingEnabled"] boolValue]&&[channel conformsToProtocol:@protocol(DBBrightnessTransport)]){
            NSData *edid=[channel brightnessEDID];
            if(edid&&BBDisplayIdentityMatches(record,BBEDIDIdentity(edid)))nativeCandidates[identity]=@{@"record":record,@"transport":channel,@"edid":edid};
        }
    }
    dispatch_async(dispatch_get_main_queue(),^{if(self.running&&generation==self.generation){
        if(request&&request!=[self brightnessRequestForIdentity:identity generation:generation])return;
        BOOL brightnessCapable=[self nativeBrightnessEntitled];
        NSMutableArray *published=[NSMutableArray new];
        for(NSDictionary *record in rows){
            NSMutableDictionary *copy=[record mutableCopy];
            BOOL requested=[self mappingEnabledForIdentity:record[@"identity"]];
            copy[@"mappingEnabled"]=@(requested); // Preserve the user's saved preference.
            copy[@"brightnessBridgeAvailable"]=@(brightnessCapable);
            copy[@"brightnessBridgeEnabled"]=@(requested&&brightnessCapable);
            if(!brightnessCapable)copy[@"nativeBrightness"]=@{
                @"phase":@"unavailable",@"available":@NO,
                @"reason":@"当前构建缺少 Apple 授权的虚拟 HID 签名，无法接入系统亮度滑块；应用内 DDC 调节仍可使用。"
            };
            copy[@"volumeBridgeEnabled"]=@([copy[@"audioOutputUID"] length]>0&&[self volumeBridgeEnabledForIdentity:record[@"identity"]]);
            [published addObject:copy];
        }
        self.snapshot=published;self.discoveryFinished=YES;[self syncNativeBrightness:nativeCandidates];if(self.volumeBridgesChanged)self.volumeBridgesChanged(self.snapshot,NO);
    }});
}
- (void)startReadOnly {if(_running)return;_readOnly=YES;_running=YES;[self rescan];}
- (void)start {
    if(_running)return;_readOnly=NO;_running=YES;
    CGDisplayRegisterReconfigurationCallback(BBDisplayReconfigured,(__bridge void*)self);
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(woke:) name:NSWorkspaceDidWakeNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(woke:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    self.discoveryTimer=[NSTimer timerWithTimeInterval:30 target:self selector:@selector(rescanPeriodically:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_discoveryTimer forMode:NSRunLoopCommonModes];
    if(!_readOnly){self.systemTimer=[NSTimer timerWithTimeInterval:.25 target:self selector:@selector(refreshMediaKeyAuthorization) userInfo:nil repeats:YES];[NSRunLoop.mainRunLoop addTimer:_systemTimer forMode:NSRunLoopCommonModes];}
    [self rescan];if(!_readOnly)[self updateSystemControls];
}
- (void)woke:(NSNotification*)n {_nativeSource=0;_nativeLevel=-1;[self rescan];}
- (void)stop {
    if(!_running)return;[self prepareForTermination:nil];_running=NO;_generation++;[_discoveryTimer invalidate];[_systemTimer invalidate];[_hudTimer invalidate];[_hud orderOut:nil];
    [self clearBrightnessRequests];
    if(!_readOnly){CGDisplayRemoveReconfigurationCallback(BBDisplayReconfigured,(__bridge void*)self);[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];}
    if(_eventTap){CGEventTapEnable(_eventTap,false);CFRunLoopRemoveSource(CFRunLoopGetMain(),_eventSource,kCFRunLoopCommonModes);CFRelease(_eventSource);CFRelease(_eventTap);_eventSource=NULL;_eventTap=NULL;}
    dispatch_async(_queue,^{[self.pending removeAllObjects];[self.channels removeAllObjects];[self.records removeAllObjects];});self.snapshot=@[];
}
- (void)beginMediaKeyOnboarding {
    if(!_running||_readOnly||_mediaKeyOnboardingPending)return;
    NSString *onboardingKey=@"MediaKeyPermissionOnboardingCompleted";
    if([[_preferences objectForKey:onboardingKey] boolValue])return;
    // Older releases stored the last build that checked permission.
    if([_preferences objectForKey:@"MediaKeyPermissionRequestedBuild"]){
        [_preferences setObject:@YES forKey:onboardingKey];
        return;
    }
    _mediaKeyOnboardingPending=YES;NSUInteger generation=_generation;
    // Preflight off the AppKit thread; wait for the real PostEvent result before
    // deciding whether a first-launch request is needed. The OS owns consent.
    dispatch_async(_permissionQueue,^{IOHIDAccessType status=[self deviceControlAccess];
        dispatch_async(dispatch_get_main_queue(),^{
            self.mediaKeyOnboardingPending=NO;
            if(!self.running||self.readOnly||self.generation!=generation)return;
            self.deviceControlStatus=status;self.permissionCheckComplete=YES;
            [self.preferences setObject:@YES forKey:onboardingKey];
            if(self.mediaKeysAuthorized)return;
            dispatch_async(self.permissionQueue,^{
                if(!self.running)return;
                [self requestMediaKeyAccess];
                dispatch_async(dispatch_get_main_queue(),^{if(!self.running)return;self.lastPermissionCheck=0;self.lastEventTapAttempt=0;[self refreshMediaKeyAuthorization];});
            });
        });
    });
}
- (void)requestMediaKeyAccess {
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString*)kAXTrustedCheckOptionPrompt:@YES});
    IOHIDRequestAccess(kIOHIDRequestTypePostEvent);
}
- (BOOL)openMediaKeySettings {
    return [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
- (void)authorizeMediaKeys {
    _lastPermissionCheck=0;_lastEventTapAttempt=0;
    [self refreshMediaKeyAuthorization];
    if(self.mediaKeysAuthorized)return;
    // A previously denied request may silently return false. Always provide
    // a visible route to Settings; keep TCC requests off the AppKit thread.
    dispatch_async(_permissionQueue,^{[self requestMediaKeyAccess];});
    if(![self openMediaKeySettings]){
        NSAlert *alert=[NSAlert new];alert.messageText=@"请在系统设置中授权快捷键";
        alert.informativeText=@"打开系统设置 → 隐私与安全性 → 设备控制和数据访问（旧版 macOS 为辅助功能），允许当前 DeviceBridge。返回应用后会自动重新检测。";
        [alert runModal];
    }
}
- (void)refreshControls {
    // Only an explicit refresh retries features whose writes were rejected.
    dispatch_async(_queue,^{[self.controlErrors removeAllObjects];});
    for(NSString *identity in _nativeBindings.allKeys.copy){NSDictionary *state=_nativeBindings[identity].state;if([state[@"phase"] isEqual:@"failed"]&&![state[@"edidApplied"] boolValue])[_nativeBindings removeObjectForKey:identity];}
    [self rescan];
}
- (void)rescan {
    if(!_running)return;
    // Topology changes retire old channels and their pending writes.
    _generation++;self.discoveryFinished=NO;
    _periodicScan=NO;_periodicScanDeferred=NO;
    [self clearBrightnessRequests];
    NSMutableArray *busy=[NSMutableArray new];for(NSDictionary *row in _snapshot){NSMutableDictionary *copy=[row mutableCopy];copy[@"scanning"]=@YES;[busy addObject:copy];}self.snapshot=busy;
    if(_scanning){_needsRescan=YES;return;}
    [self scanDisplaysPeriodically:NO];
}
- (void)rescanPeriodically:(NSTimer*)timer {
    if(!_running||_scanning)return;
    @synchronized(_brightnessRequests){
        _periodicScanDeferred=_brightnessRequests.count>0;
    }
    if(!_periodicScanDeferred)[self scanDisplaysPeriodically:YES];
}
- (void)scanDisplaysPeriodically:(BOOL)periodic {
    _scanning=YES;_periodicScan=periodic;self.discoveryFinished=NO;
    NSUInteger generation=_generation;NSArray*screens=[self connectedScreens];NSDictionary*choices=[_mappingChoices copy];
    dispatch_async(_queue,^{
        if(!periodic)[self.pending removeAllObjects];
        NSDictionary *previousChannels=periodic?[self.channels copy]:nil;
        [self.channels removeAllObjects];
        // Keep known rows even if enumeration is transiently empty. Old control
        // capabilities are removed, so a retained row never writes stale data.
        for(NSMutableDictionary*r in self.records.allValues){r[@"connected"]=@NO;r[@"status"]=@"显示器未连接 · 等待重新发现";[r removeObjectForKey:@"brightness"];[r removeObjectForKey:@"volume"];[r removeObjectForKey:@"audioOutputUID"];r[@"audioBridgeAvailable"]=@NO;}
        NSArray *audioOutputs=[self audioOutputs];
        NSArray<BBDDCChannel*>*ports=[self displayChannels];NSMutableSet*used=[NSMutableSet new];
        for(NSDictionary*s in screens){
            NSMutableDictionary*r=[s mutableCopy];r[@"category"]=@"Display";r[@"connected"]=@YES;r[@"mappingEnabled"]=choices[s[@"identity"]]?:@NO;
            NSString *audioUID=DBDisplayAudioOutputUID(r,screens,audioOutputs);if(audioUID)r[@"audioOutputUID"]=audioUID;r[@"audioBridgeAvailable"]=@(audioUID.length>0);
            NSMutableArray*candidates=[NSMutableArray new];
            for(BBDDCChannel*c in ports)if(![used containsObject:c]&&BBDisplayIdentityMatches(s,c.identity))[candidates addObject:c];
            BBDDCChannel*channel=nil;
            if(candidates.count==1){
                // Reject a port that matches multiple active screens (identical
                // monitors without distinct serials). Never fall back to order.
                BBDDCChannel*c=candidates.firstObject;NSUInteger matches=0;for(NSDictionary*other in screens)if(BBDisplayIdentityMatches(other,c.identity))matches++;
                if(matches==1)channel=c;
            }else if(screens.count==1&&ports.count==1&&!candidates.count){
                NSDictionary *port=ports.firstObject.identity;
                // Anonymous single-channel fallback must never bypass known
                // serial or location conflicts.
                BOOL anonymous=![port[@"name"] length]&&!port[@"vendor"]&&!port[@"product"]&&![port[@"serial"] unsignedIntValue]&&![port[@"textSerial"] length];
                BOOL locationConflict=[s[@"location"] length]&&[port[@"location"] length]&&![s[@"location"] isEqual:port[@"location"]];
                if(anonymous&&!locationConflict)channel=ports.firstObject;
            }
            if(channel){
                BBDDCChannel *previous=previousChannels[s[@"identity"]];
                if([previous isKindOfClass:BBDDCChannel.class]&&[channel isKindOfClass:BBDDCChannel.class]){
                    channel.lastOperation=previous.lastOperation;
                }
                [used addObject:channel];self.channels[s[@"identity"]]=channel;
                if([channel.identity[@"name"] length])r[@"name"]=channel.identity[@"name"];
                for(NSNumber*code in @[@0x10,@0x62]){NSDictionary*v=[channel read:code.unsignedCharValue];if(v)r[code.intValue==0x10?@"brightness":@"volume"]=v;}
                for(NSString *feature in self.controlErrors[s[@"identity"]])r[[feature stringByAppendingString:@"Error"]]=self.controlErrors[s[@"identity"]][feature];
                if(!r[@"brightness"])r[@"brightnessError"]=@"亮度不可用 · 未取得有效 DDC 读数";
                if(!r[@"volume"])r[@"volumeError"]=@"音量不可用 · 未取得有效 DDC 读数";
                if(r[@"brightness"]||r[@"volume"])r[@"updated"]=@(NSDate.date.timeIntervalSince1970);
                r[@"status"]=(r[@"brightness"]||r[@"volume"])?@"DDC 已读取":@"DDC 无响应 · 请开启显示器 DDC/CI，检查线缆或转接器";
                NSDictionary *errors=self.controlErrors[s[@"identity"]];
                if(errors.count)r[@"status"]=errors[@"volume"]?:errors[@"brightness"];
            }else r[@"status"]=@"未找到可唯一匹配的 DDC 通道 · 可尝试直连后刷新";
            self.records[s[@"identity"]]=r;
        }
        [self publishForGeneration:generation];
        dispatch_async(dispatch_get_main_queue(),^{
            self.scanning=NO;self.periodicScan=NO;[self flushNativeBrightnessRequests];
            if(self.needsRescan&&self.running){self.needsRescan=NO;[self rescan];}
        });
    });
}
- (void)enqueuePercent:(double)percent code:(uint8_t)code identity:(NSString*)identity generation:(NSUInteger)generation bridged:(BOOL)bridged {
    if(code==0x10&&[self brightnessRequestForIdentity:identity generation:generation])return;
    NSString*key=[NSString stringWithFormat:@"%@/%u",identity,code];
    BOOL scheduled=self.pending[key]!=nil;self.pending[key]=@{@"percent":@(percent),@"generation":@(generation),@"bridged":@(bridged),@"identity":identity};
    if(scheduled)return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,80*NSEC_PER_MSEC),self.queue,^{
        NSDictionary*request=self.pending[key];[self.pending removeObjectForKey:key];
        if(!request||!self.running||[request[@"generation"] unsignedIntegerValue]!=self.generation)return;
        if([request[@"bridged"] boolValue]&&(code==0x10?![self.records[identity][@"mappingEnabled"] boolValue]:![self volumeBridgeEnabledForIdentity:identity]))return;
        [self applyPercent:[request[@"percent"] doubleValue] code:code identity:identity generation:[request[@"generation"] unsignedIntegerValue] manualRequest:nil];
    });
}
- (void)setPercent:(double)percent code:(uint8_t)code identity:(NSString*)identity {
    if((_scanning&&!_periodicScan)||_readOnly||!_running||!isfinite(percent)||(code!=0x10&&code!=0x62)||!identity.length)return;
    percent=fmax(0,fmin(100,percent));NSUInteger generation=_generation;
    if(code==0x10){
        BOOL alreadyScheduled;
        @synchronized(_brightnessRequests){
            BBBrightnessRequest *previous=_brightnessRequests[identity];
            BOOL sameGeneration=previous&&previous.generation==generation;
            if(sameGeneration&&previous.percent==percent)return;
            alreadyScheduled=sameGeneration&&previous.scheduled;
            BBBrightnessRequest *request=[BBBrightnessRequest new];
            request.percent=percent;request.generation=generation;request.scheduled=YES;
            if(sameGeneration)request.readingBeforeFailure=previous.readingBeforeFailure;
            _brightnessRequests[identity]=request;
        }
        if(!alreadyScheduled)[self scheduleBrightnessForIdentity:identity generation:generation delay:40*NSEC_PER_MSEC];
        return;
    }
    dispatch_async(_queue,^{if(self.running&&generation==self.generation)[self enqueuePercent:percent code:code identity:identity generation:generation bridged:NO];});
}
- (void)clearBrightnessRequests {
    @synchronized(_brightnessRequests){[_brightnessRequests removeAllObjects];}
}
- (BBBrightnessRequest*)brightnessRequestForIdentity:(NSString*)identity generation:(NSUInteger)generation {
    if(!identity.length)return nil;
    @synchronized(_brightnessRequests){
        BBBrightnessRequest *request=_brightnessRequests[identity];
        return request.generation==generation?request:nil;
    }
}
- (NSNumber*)pendingBrightnessForIdentity:(NSString*)identity {
    BBBrightnessRequest *request=[self brightnessRequestForIdentity:identity generation:self.generation];
    return request?@(request.percent):nil;
}
- (void)scheduleBrightnessForIdentity:(NSString*)identity generation:(NSUInteger)generation delay:(int64_t)delay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,delay),_queue,^{
        BBBrightnessRequest *request=[self brightnessRequestForIdentity:identity generation:generation];
        if(!request||!self.running||generation!=self.generation)return;
        [self.pending removeObjectForKey:[NSString stringWithFormat:@"%@/%u",identity,0x10u]];
        [self applyPercent:request.percent code:0x10 identity:identity generation:generation manualRequest:request];
        BOOL newer;
        @synchronized(self.brightnessRequests){
            if(!self.running||generation!=self.generation)return;
            newer=self.brightnessRequests[identity]!=request;
            if(!newer)request.scheduled=NO;
        }
        if(newer){[self scheduleBrightnessForIdentity:identity generation:generation delay:0];return;}
        // Retire the goal after the confirmed snapshot has reached the main
        // queue. Hardware can continue processing while AppKit tracks a drag.
        dispatch_async(dispatch_get_main_queue(),^{
            if(!self.running||generation!=self.generation)return;
            @synchronized(self.brightnessRequests){
                if(self.brightnessRequests[identity]!=request)return;
                [self.brightnessRequests removeObjectForKey:identity];
            }
            if(self.periodicScanDeferred)[self rescanPeriodically:nil];
        });
    });
}
- (void)applyPercent:(double)percent code:(uint8_t)code identity:(NSString*)identity generation:(NSUInteger)generation manualRequest:(BBBrightnessRequest*)request {
    if(_readOnly||!self.running||generation!=self.generation)return;
    if(code==0x10&&request!=[self brightnessRequestForIdentity:identity generation:generation])return;
    BBDDCChannel*c=_channels[identity];NSMutableDictionary*r=_records[identity];NSString*feature=code==0x10?@"brightness":@"volume";
    // A drag received before an earlier failure reached the UI can still use
    // that request's last known reading on the same display generation.
    NSDictionary *before=r[feature]?:request.readingBeforeFailure;
    if(!c||(!BBDisplayControlAvailable(r,code)&&!request.readingBeforeFailure)||![before[@"maximum"] unsignedIntValue])return;
    uint16_t value=(uint16_t)lround(percent*[before[@"maximum"] doubleValue]/100.0);
    BOOL sent=[c write:code value:value];
    if(code==0x10&&request!=[self brightnessRequestForIdentity:identity generation:generation])return;
    NSDictionary*after=sent?[c read:code]:nil;
    // An adjacent reading can be the previous slider setting.
    int tolerance=request?0:1;
    BOOL verified=after&&abs([after[@"current"] intValue]-value)<=tolerance;
    // Some panels apply SET asynchronously. Retry readback once, never send a
    // second write merely because the first read returned the old value.
    if(sent&&after&&!verified){
        if(code==0x10&&request!=[self brightnessRequestForIdentity:identity generation:generation])return;
        usleep(100000);after=[c read:code];
        verified=after&&abs([after[@"current"] intValue]-value)<=tolerance;
    }
    @synchronized(_brightnessRequests){
        if(generation!=self.generation||(code==0x10&&request!=_brightnessRequests[identity]))return;
        if(verified){
            if(request.readingBeforeFailure){
                [r removeObjectForKey:@"brightnessError"];
                [self.controlErrors[identity] removeObjectForKey:feature];
            }
            request.readingBeforeFailure=nil;
            r[feature]=after;r[@"status"]=@"DDC 调节已确认";r[@"updated"]=@(NSDate.date.timeIntervalSince1970);
        }else{
            NSString *reason=after?@"显示器未应用目标值 · 请检查 HDR / 显示模式，刷新后重试":@"DDC 写入或回读失败 · 请刷新后重试";
            if(!self.controlErrors[identity])self.controlErrors[identity]=[NSMutableDictionary new];
            self.controlErrors[identity][feature]=reason;r[[feature stringByAppendingString:@"Error"]]=reason;
            [r removeObjectForKey:feature];r[@"status"]=reason;
            request.readingBeforeFailure=before;
            if(code==0x62)[self.unmuted removeObjectForKey:identity];
        }
    }
    if(verified){
        NSString *name=r[@"name"];double confirmed=[after[@"percent"] doubleValue];
        dispatch_async(dispatch_get_main_queue(),^{
            if(self.running&&self.generation==generation&&(code!=0x10||request==[self brightnessRequestForIdentity:identity generation:generation]))[self showHUD:name feature:feature percent:confirmed];
        });
    }
    if(code==0x10)dispatch_async(dispatch_get_main_queue(),^{
        if(self.running&&self.generation==generation&&request==[self brightnessRequestForIdentity:identity generation:generation])[self.nativeBindings[identity] acknowledgePercent:verified?[after[@"percent"] doubleValue]:percent success:verified];
    });
    [self publishForGeneration:generation manualRequest:request identity:identity];
}
- (void)showHUD:(NSString*)name feature:(NSString*)feature percent:(double)percent {
    if(!_hud){self.hud=[[NSPanel alloc]initWithContentRect:NSMakeRect(0,0,310,64) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];_hud.level=NSStatusWindowLevel;_hud.ignoresMouseEvents=YES;_hud.backgroundColor=NSColor.windowBackgroundColor;_hud.hasShadow=YES;_hud.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;}
    for(NSView*v in _hud.contentView.subviews.copy)[v removeFromSuperview];
    NSTextField*l=[NSTextField labelWithString:[NSString stringWithFormat:@"%@\n%@ %.0f%%",name,[feature isEqual:@"brightness"]?@"亮度":@"音量",percent]];l.frame=NSMakeRect(16,10,278,44);l.alignment=NSTextAlignmentCenter;[_hud.contentView addSubview:l];
    NSRect area=NSScreen.mainScreen.visibleFrame;[_hud setFrameOrigin:NSMakePoint(NSMidX(area)-155,NSMinY(area)+80)];[_hud orderFrontRegardless];[_hudTimer invalidate];
    __weak BBDisplayController*weak=self;self.hudTimer=[NSTimer scheduledTimerWithTimeInterval:1.2 repeats:NO block:^(NSTimer*t){[weak.hud orderOut:nil];}];
}
- (void)updateSystemControls {
    if(!_running||_readOnly)return;
    BOOL permissionDenied=![self accessibilityAuthorized]&&![self hasActiveMediaKeyTap]&&_permissionCheckComplete&&_deviceControlStatus!=kIOHIDAccessTypeGranted;
    if(_eventTap&&(!CFMachPortIsValid(_eventTap)||permissionDenied)){
        CGEventTapEnable(_eventTap,false);[_consumedKeys removeAllObjects];
        CFRunLoopRemoveSource(CFRunLoopGetMain(),_eventSource,kCFRunLoopCommonModes);CFRelease(_eventSource);CFRelease(_eventTap);_eventSource=NULL;_eventTap=NULL;
    }
    CFTimeInterval now=CFAbsoluteTimeGetCurrent();
    // Try the real filtering tap even when preflight caches have not caught up.
    // PostEvent preflight alone cannot rule out filtering-tap access.
    if(!_eventTap&&now-_lastEventTapAttempt>=2){
        _lastEventTapAttempt=now;
        _eventTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,CGEventMaskBit(NX_SYSDEFINED),BBDisplayKeyEvent,(__bridge void*)self);
        if(_eventTap){
            _eventSource=CFMachPortCreateRunLoopSource(NULL,_eventTap,0);
            if(_eventSource){CFRunLoopAddSource(CFRunLoopGetMain(),_eventSource,kCFRunLoopCommonModes);CGEventTapEnable(_eventTap,true);}
            else{CFRelease(_eventTap);_eventTap=NULL;}
        }
    }
    // Follow changes from an EXISTING native built-in slider. Establish a
    // baseline at startup/wake without overwriting the external monitor.
    CGDirectDisplayID source=0;float level=-1;
    if(nativeBrightness)for(NSScreen*s in NSScreen.screens){CGDirectDisplayID d=[s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];if(CGDisplayIsBuiltin(d)&&nativeBrightness(d,&level)==0&&isfinite(level)&&level>=0&&level<=1){source=d;break;}}
    if(source&&source==_nativeSource&&_nativeLevel>=0&&fabsf(level-_nativeLevel)>.002){for(NSDictionary*r in _snapshot)if(!_scanning&&BBDisplayControlAvailable(r,0x10)&&[self mappingEnabledForIdentity:r[@"identity"]]){
        NSString*identity=r[@"identity"];NSUInteger generation=self.generation;
        dispatch_async(_queue,^{if(self.running&&generation==self.generation&&[self.records[identity][@"mappingEnabled"] boolValue])[self enqueuePercent:level*100 code:0x10 identity:identity generation:generation bridged:YES];});
    }}
    _nativeSource=source;_nativeLevel=level;
}
- (NSDictionary*)targetForKey:(int)key {
    if(_scanning)return nil;
    if(key==0||key==1||key==7){
        // Read output routing at the moment of the key event, not a stale timer.
        NSString*name=BBDisplayNameKey(BBDefaultDisplayAudioName());NSMutableArray*matches=[NSMutableArray new];
        for(NSDictionary*r in _snapshot)if(BBDisplayControlAvailable(r,0x62)&&[r[@"audioOutputUID"] length]&&[self volumeBridgeEnabledForIdentity:r[@"identity"]]&&[BBDisplayNameKey(r[@"name"]) isEqual:name])[matches addObject:r];return matches.count==1?matches.firstObject:nil;
    }
    if(key!=2&&key!=3)return nil;
    // On a MacBook the OS handles the built-in brightness; synchronization above
    // follows it. On a desktop use the screen under the pointer, then main.
    if(_nativeSource)return nil;
    NSPoint mouse=NSEvent.mouseLocation;CGDirectDisplayID selected=CGMainDisplayID();
    for(NSScreen*s in NSScreen.screens)if(NSPointInRect(mouse,s.frame)){selected=[s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];break;}
    for(NSDictionary*r in _snapshot)if([r[@"displayID"] unsignedIntValue]==selected&&![r[@"nativeBrightness"][@"available"] boolValue]&&BBDisplayControlAvailable(r,0x10)&&[self mappingEnabledForIdentity:r[@"identity"]])return r;return nil;
}
- (void)adjustKey:(int)key record:(NSDictionary*)record {
    NSString*identity=record[@"identity"];uint8_t code=(key==2||key==3)?0x10:0x62;NSUInteger generation=_generation;
    dispatch_async(_queue,^{
        if(!self.running||generation!=self.generation)return;
        NSDictionary*r=self.records[identity];NSString*feature=code==0x10?@"brightness":@"volume";
        if(!BBDisplayControlAvailable(r,code)||(code==0x10?![r[@"mappingEnabled"] boolValue]:![self volumeBridgeEnabledForIdentity:identity]))return;NSString*pendingKey=[NSString stringWithFormat:@"%@/%u",identity,code];
        NSNumber*pendingValue=self.pending[pendingKey][@"percent"];
        double current=pendingValue?pendingValue.doubleValue:[r[feature][@"percent"] doubleValue],next=current;
        if(key==7){if(current>0){self.unmuted[identity]=@(current);next=0;}else{NSNumber*restore=self.unmuted[identity];if(!restore)return;next=restore.doubleValue;}}
        else next=fmax(0,fmin(100,current+((key==0||key==2)?6.25:-6.25)));
        [self enqueuePercent:next code:code identity:identity generation:generation bridged:YES];
    });
}
@end
static CGEventRef BBDisplayKeyEvent(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void*context) {
    BBDisplayController*c=(__bridge BBDisplayController*)context;
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){if(c.running&&c.eventTap&&c.mediaKeysAuthorized)CGEventTapEnable(c.eventTap,true);return event;}
    if(type!=NX_SYSDEFINED)return event;NSEvent*e=[NSEvent eventWithCGEvent:event];if(e.subtype!=8)return event;
    int key=(int)((e.data1>>16)&0xffff),state=(int)((e.data1>>8)&0xff);
    if(state==0x0b){if([c.consumedKeys containsObject:@(key)]){[c.consumedKeys removeObject:@(key)];return NULL;}return event;}
    if(state!=0x0a)return event;NSDictionary*r=[c targetForKey:key];if(!r)return event;
    [c.consumedKeys addObject:@(key)];[c adjustKey:key record:r];return NULL;
}

static NSTextField *BBDisplayLabel(NSString*text,NSRect frame,CGFloat size,NSColor*color) {
    NSTextField*l=[NSTextField labelWithString:text];l.frame=frame;l.font=[NSFont systemFontOfSize:size];l.textColor=color;l.lineBreakMode=NSLineBreakByTruncatingTail;return l;
}
@interface BBBrightnessSlider : NSSlider
@property(nonatomic) BOOL tracking;
@end
@implementation BBBrightnessSlider
- (void)mouseDown:(NSEvent*)event {
    self.tracking=YES;
    [super mouseDown:event];
    self.tracking=NO;
}
@end

@interface BBDisplayRow () <NSTextFieldDelegate>
@property NSTextField *brightnessValueLabel;
@property NSTextField *volumeValueLabel;
@property BOOL hasUncommittedPercent;
@end
@implementation BBDisplayRow
@synthesize controller=_controller;
- (instancetype)initWithFrame:(NSRect)frame record:(NSDictionary*)record {
    if((self=[super initWithFrame:frame])){
        _record=record;CGFloat w=frame.size.width;CGFloat sliderWidth=MIN(220,MAX(110,w*.23)),sliderX=w-240-sliderWidth;BOOL connected=![record[@"connected"] isEqual:@NO];
        CGFloat iconSize=40;
        NSImageView*icon=[[NSImageView alloc]initWithFrame:NSMakeRect(16,NSMidY(self.bounds)-iconSize/2,iconSize,iconSize)];icon.imageAlignment=NSImageAlignCenter;icon.autoresizingMask=NSViewMinYMargin|NSViewMaxYMargin;icon.image=[NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:@"显示器"];icon.symbolConfiguration=[NSImageSymbolConfiguration configurationWithPointSize:28 weight:NSFontWeightRegular];icon.contentTintColor=connected?NSColor.secondaryLabelColor:NSColor.tertiaryLabelColor;[self addSubview:icon];
        NSTextField*name=BBDisplayLabel(record[@"name"]?:@"外接显示器",NSMakeRect(72,56,MAX(1,sliderX-100),20),13,NSColor.labelColor);name.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium];name.toolTip=name.stringValue;[self addSubview:name];
        NSString *connection=!connected?@"未连接":((record[@"brightness"]||record[@"volume"])?@"已连接":@"显示器在线 · 等待读取");
        NSString*time=@"尚未读取";if([record[@"updated"] doubleValue]>0)time=[NSString stringWithFormat:@"%@ %@",connected?@"更新于":@"上次读取",[NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[record[@"updated"] doubleValue]] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle]];
        NSTextField *status=BBDisplayLabel(@"",NSMakeRect(72,35,MAX(1,sliderX-100),17),11,NSColor.secondaryLabelColor);
        NSMutableAttributedString *statusText=[[NSMutableAttributedString alloc]initWithString:connection attributes:@{NSFontAttributeName:status.font,NSForegroundColorAttributeName:NSColor.secondaryLabelColor}];
        [statusText appendAttributedString:[[NSAttributedString alloc]initWithString:[@"  " stringByAppendingString:time] attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:10],NSForegroundColorAttributeName:NSColor.tertiaryLabelColor}]];
        status.attributedStringValue=statusText;status.toolTip=[NSString stringWithFormat:@"%@  %@",connection,time];[self addSubview:status];
        for(NSUInteger i=0;i<2;i++){
            NSString*f=i?@"volume":@"brightness";NSDictionary*v=record[f];CGFloat y=i?24:52;
            NSImageView*symbol=[[NSImageView alloc]initWithFrame:NSMakeRect(sliderX-20,y+2,16,16)];symbol.image=[NSImage imageWithSystemSymbolName:i?@"speaker.wave.2":@"sun.max" accessibilityDescription:i?@"音量":@"亮度"];symbol.contentTintColor=NSColor.secondaryLabelColor;[self addSubview:symbol];
            Class sliderClass=i?NSSlider.class:BBBrightnessSlider.class;
            NSSlider*slider=[[sliderClass alloc]initWithFrame:NSMakeRect(sliderX,y,sliderWidth,20)];
            slider.minValue=0;slider.maxValue=100;slider.doubleValue=[v[@"percent"] doubleValue];slider.target=self;slider.action=i?@selector(volumeChanged:):@selector(brightnessChanged:);
            slider.controlSize=NSControlSizeSmall;slider.enabled=BBDisplayControlAvailable(record,i?0x62:0x10);slider.continuous=!i;slider.accessibilityLabel=[NSString stringWithFormat:@"%@%@",name.stringValue,i?@"音量":@"亮度"];slider.toolTip=slider.enabled?slider.accessibilityLabel:(record[[f stringByAppendingString:@"Error"]]?:([record[@"scanning"] boolValue]?@"正在探测显示器，请稍候":@"此控制不可用 · 请启用 DDC/CI 后刷新"));[self addSubview:slider];
            if(i)_volumeSlider=slider;else _brightnessSlider=slider;
            NSTextField *value = [[NSTextField alloc] initWithFrame:NSMakeRect(w-236,y-1,42,22)];
            value.stringValue = slider.enabled ? [NSString stringWithFormat:@"%.0f%%",slider.doubleValue] : @"—";
            value.alignment = NSTextAlignmentRight;
            value.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
            value.controlSize = NSControlSizeSmall;
            value.cell.usesSingleLineMode = YES;
            value.enabled = value.editable = value.selectable = slider.enabled;
            value.accessibilityLabel = [slider.accessibilityLabel stringByAppendingString:@"百分比"];
            value.toolTip = slider.enabled ? @"输入 0–100，按回车确认" : slider.toolTip;
            value.delegate = self;
            [self addSubview:value];
            if (i) _volumeValueLabel = value; else _brightnessValueLabel = value;
        }
        BOOL brightnessAvailable=[record[@"brightnessBridgeAvailable"] boolValue];
        BOOL brightnessEnabled=brightnessAvailable&&[record[@"brightnessBridgeEnabled"]?:record[@"mappingEnabled"] boolValue];
        BOOL audioAvailable=connected&&[record[@"audioOutputUID"] length]>0&&![record[@"scanning"] boolValue];
        BOOL volumeEnabled=audioAvailable&&[record[@"volumeBridgeEnabled"] boolValue];
        for(NSUInteger i=0;i<2;i++){
            CGFloat y=i?24:52;NSString *title=i?@"音量桥接":@"亮度桥接";
            NSTextField *label=BBDisplayLabel(title,NSMakeRect(w-190,y+2,66,16),10,NSColor.secondaryLabelColor);[self addSubview:label];
            NSSwitch *toggle=[[NSSwitch alloc]initWithFrame:NSMakeRect(w-120,y-1,44,24)];toggle.controlSize=NSControlSizeSmall;toggle.target=self;toggle.action=i?@selector(volumeBridgeChanged:):@selector(brightnessBridgeChanged:);
            toggle.state=(i?volumeEnabled:brightnessEnabled)?NSControlStateValueOn:NSControlStateValueOff;
            toggle.enabled=i?audioAvailable:(brightnessAvailable&&[record[@"identity"] length]>0&&(brightnessEnabled||BBDisplayControlAvailable(record,0x10)));
            toggle.accessibilityLabel=[NSString stringWithFormat:@"%@的%@",name.stringValue,title];
            toggle.toolTip=i?(audioAvailable?@"单独启停此显示器的系统音量代理；关闭不影响亮度桥接":@"没有可唯一匹配的 HDMI / DisplayPort 音频输出，音量桥接不可用"):[NSString stringWithFormat:@"单独启停亮度桥接和亮度键；首次绑定可能短暂黑屏。%@",record[@"nativeBrightness"][@"reason"]?:@""];
            [self addSubview:toggle];if(i)_volumeBridgeSwitch=toggle;else{_brightnessBridgeSwitch=toggle;_mappingSwitch=toggle;}
        }
        if(!brightnessAvailable){
            NSTextField *hint=BBDisplayLabel(@"系统亮度暂不可用",NSMakeRect(w-198,79,152,12),8.5,NSColor.secondaryLabelColor);
            hint.toolTip=record[@"nativeBrightness"][@"reason"];hint.accessibilityIdentifier=@"BrightnessBridgeUnavailable";[self addSubview:hint];
        }
        self.refreshButton=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"刷新显示器"] target:self action:@selector(refreshDisplay:)];_refreshButton.frame=NSMakeRect(w-50,33,30,28);_refreshButton.bezelStyle=NSBezelStyleRounded;_refreshButton.toolTip=@"重新发现显示器并读取亮度、音量";_refreshButton.accessibilityIdentifier=@"DisplayRefresh";[self addSubview:_refreshButton];
        self.toolTip=[NSString stringWithFormat:@"%@%@",record[@"status"]?:@"",record[@"nativeBrightness"][@"reason"]?[@"\n系统亮度：" stringByAppendingString:record[@"nativeBrightness"][@"reason"]]:@""];
    }return self;
}
- (BOOL)isTrackingBrightness {
    return [_brightnessSlider isKindOfClass:BBBrightnessSlider.class]&&((BBBrightnessSlider*)_brightnessSlider).tracking;
}
- (BOOL)isEditingPercent {
    return _hasUncommittedPercent;
}
- (void)controlTextDidChange:(NSNotification *)notification {
    _hasUncommittedPercent = YES;
}
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (selector != @selector(cancelOperation:)) return NO;
    _hasUncommittedPercent = NO;
    [control abortEditing];
    NSSlider *slider = control == _brightnessValueLabel ? _brightnessSlider : _volumeSlider;
    control.stringValue = [NSString stringWithFormat:@"%.0f%%",slider.doubleValue];
    return YES;
}
- (void)controlTextDidEndEditing:(NSNotification *)notification {
    BOOL changed = _hasUncommittedPercent;
    _hasUncommittedPercent = NO;
    NSTextField *field = notification.object;
    NSSlider *slider = field == _brightnessValueLabel ? _brightnessSlider : _volumeSlider;
    NSString *previous = [NSString stringWithFormat:@"%.0f%%",slider.doubleValue];
    if (!changed || [notification.userInfo[@"NSTextMovement"] integerValue] == NSCancelTextMovement ||
        [field.stringValue isEqualToString:previous]) {
        field.stringValue = previous;
        return;
    }

    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSString *input = [field.stringValue stringByTrimmingCharactersInSet:spaces];
    if ([input hasSuffix:@"%"] || [input hasSuffix:@"％"])
        input = [[input substringToIndex:input.length-1] stringByTrimmingCharactersInSet:spaces];
    NSInteger percent = input.integerValue;
    if (!input.length || [input rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound || percent > 100) {
        field.stringValue = previous;
        NSBeep();
        return;
    }
    slider.doubleValue = percent;
    field.stringValue = [NSString stringWithFormat:@"%ld%%",(long)percent];
    [slider sendAction:slider.action to:slider.target];
}
- (void)setController:(BBDisplayController*)controller {
    _controller=controller;
    NSNumber *pending=[controller pendingBrightnessForIdentity:_record[@"identity"]];
    if(pending&&_brightnessSlider.enabled){
        _brightnessSlider.doubleValue=pending.doubleValue;
        _brightnessValueLabel.stringValue=[NSString stringWithFormat:@"%.0f%%",pending.doubleValue];
    }
}
// Display discovery owns these rows, including retained disconnected rows.
// Do not inherit an injected context menu from a parent view.
- (NSMenu*)menuForEvent:(NSEvent*)event {return nil;}
- (void)mappingChanged:(NSSwitch*)sender {[self brightnessBridgeChanged:sender];}
- (void)brightnessBridgeChanged:(NSSwitch*)sender {[_controller setBrightnessBridgeEnabled:sender.state==NSControlStateValueOn identity:_record[@"identity"]];}
- (void)volumeBridgeChanged:(NSSwitch*)sender {if(sender.enabled)[_controller setVolumeBridgeEnabled:sender.state==NSControlStateValueOn identity:_record[@"identity"]];}
- (void)refreshDisplay:(id)sender {[_controller refreshControls];}
- (void)brightnessChanged:(NSSlider*)sender {
    if(!sender.enabled)return;
    if(!_brightnessValueLabel.currentEditor)_brightnessValueLabel.stringValue=[NSString stringWithFormat:@"%.0f%%",sender.doubleValue];
    [_controller setPercent:sender.doubleValue code:0x10 identity:_record[@"identity"]];
}
- (void)volumeChanged:(NSSlider*)sender {
    if(!sender.enabled)return;
    if(!_volumeValueLabel.currentEditor)_volumeValueLabel.stringValue=[NSString stringWithFormat:@"%.0f%%",sender.doubleValue];
    [_controller setPercent:sender.doubleValue code:0x62 identity:_record[@"identity"]];
}
- (void)drawRect:(NSRect)dirty {if(_showsSeparator){[[NSColor separatorColor] setFill];NSRectFill(NSMakeRect(72,0,MAX(0,self.bounds.size.width-88),.5));}}
@end
