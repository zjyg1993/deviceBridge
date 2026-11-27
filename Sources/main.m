#import <Cocoa/Cocoa.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <ServiceManagement/ServiceManagement.h>
#import <dlfcn.h>
#import <sys/file.h>
#import "Protocol.h"
#import "Policy.h"
#import "Brand.h"
#import "Display.h"
#import "NativeAudioSetup.h"
#import "DisplayDDC.h"
#import "USBSmart.h"

// Retained across the DeviceBridge rename for preferences, login items and permissions.
static NSString *const BundleID=@"local.batterybridge.agent";
static NSString *const Version=@"1.0.0";
static NSString *BBApplicationTitle(void){return [NSString stringWithFormat:@"DeviceBridge %@",Version];}
static NSString *const InstallPath=@"/Applications/DeviceBridge.app";

static BOOL BBTestingUI=NO;
@interface BBPreferenceStore:NSObject
@property NSMutableDictionary*memory;
- (id)objectForKey:(NSString*)key;
- (NSDictionary*)dictionaryForKey:(NSString*)key;
- (BOOL)boolForKey:(NSString*)key;
- (void)setObject:(id)value forKey:(NSString*)key;
- (void)setBool:(BOOL)value forKey:(NSString*)key;
- (void)registerDefaults:(NSDictionary*)values;
@end
@implementation BBPreferenceStore
- (instancetype)init {if((self=[super init])&&BBTestingUI)_memory=[NSMutableDictionary new];return self;}
- (id)objectForKey:(NSString*)key {return _memory?_memory[key]:[NSUserDefaults.standardUserDefaults objectForKey:key];}
- (NSDictionary*)dictionaryForKey:(NSString*)key {id v=[self objectForKey:key];return [v isKindOfClass:NSDictionary.class]?v:nil;}
- (BOOL)boolForKey:(NSString*)key {return [[self objectForKey:key] boolValue];}
- (void)setObject:(id)value forKey:(NSString*)key {if(_memory)_memory[key]=value;else[NSUserDefaults.standardUserDefaults setObject:value forKey:key];}
- (void)setBool:(BOOL)value forKey:(NSString*)key {[self setObject:@(value) forKey:key];}
- (void)registerDefaults:(NSDictionary*)values {if(_memory){for(NSString*k in values)if(!_memory[k])_memory[k]=values[k];}else[NSUserDefaults.standardUserDefaults registerDefaults:values];}
@end
static BBPreferenceStore *BBPreferences(void){static BBPreferenceStore*p;static dispatch_once_t once;dispatch_once(&once,^{p=[BBPreferenceStore new];});return p;}

static NSString *errorText(IOReturn e){return [NSString stringWithFormat:@"0x%08x",e];}
static NSDictionary *property(IOHIDDeviceRef d){
    NSMutableDictionary *v=[NSMutableDictionary new];
    for(NSString *k in @[@"VendorID",@"ProductID",@"Product",@"Transport",@"LocationID",@"PrimaryUsagePage",@"PrimaryUsage",@"ReportDescriptor"]){id x=(__bridge id)IOHIDDeviceGetProperty(d,(__bridge CFStringRef)k);if(x)v[k]=x;}
    // Match the actual USB control interface rather than a product-name guess.
    id interface=CFBridgingRelease(IORegistryEntrySearchCFProperty(IOHIDDeviceGetService(d),kIOServicePlane,CFSTR("bInterfaceNumber"),kCFAllocatorDefault,kIORegistryIterateRecursively|kIORegistryIterateParents));
    if([interface isKindOfClass:NSNumber.class])v[@"USBInterfaceNumber"]=interface;
    return v;
}
// USB describes the host connection, not whether the peripheral is wireless.
// Only admit interfaces belonging to a receiver whose protocol we recognize.
typedef NS_ENUM(NSUInteger, BBReceiverKind) { BBReceiverNone, BBReceiverQHW, BBReceiverLogitech, BBReceiverYJX, BBReceiverAulaF75, BBReceiverAulaSC580, BBReceiverRazer, BBReceiverKeychron, BBReceiverGlorious, BBReceiverSteelSeries, BBReceiverCompx, BBReceiverMchose, BBReceiverATKKeyboard, BBReceiverASUSMouse, BBReceiverASUSOmni };
#import "ModernReceivers.h"
// Exact receiver IDs only. Wired IDs and Bluetooth transports are deliberately absent.
static NSDictionary *receiverProfile(NSDictionary*p){
    if(![p[@"Transport"] isEqual:@"USB"])return nil;
    unsigned vid=[p[@"VendorID"] intValue],pid=[p[@"ProductID"] intValue];
    unsigned page=[p[@"PrimaryUsagePage"] intValue];
    NSNumber*interface=p[@"USBInterfaceNumber"];NSData*desc=p[@"ReportDescriptor"];
    if(vid==0x1532){
        NSString*name=nil;int control=2;BOOL keyboard=YES;
        switch(pid){
            case 0x025c:name=@"Razer BlackWidow V3 Pro";break;
            case 0x0271:name=@"Razer BlackWidow V3 Mini HyperSpeed";control=3;break;
            case 0x02ba:name=@"Razer BlackWidow V4 Mini HyperSpeed";control=3;break;
            case 0x02d5:name=@"Razer BlackWidow V4 Tenkeyless HyperSpeed";break;
            case 0x0290:name=@"Razer DeathStalker V2 Pro";break;
            case 0x0296:name=@"Razer DeathStalker V2 Pro TKL";break;
            case 0x00a6:name=@"Razer Viper V2 Pro";control=0;keyboard=NO;break;
            case 0x00c1:name=@"Razer Viper V3 Pro";control=0;keyboard=NO;break;
            case 0x00b7:name=@"Razer DeathAdder V3 Pro";control=0;keyboard=NO;break;
            case 0x00c5:name=@"Razer DeathAdder V3 HyperSpeed";control=0;keyboard=NO;break;
            case 0x00e6:name=@"Razer Viper V4 Pro";control=0;keyboard=NO;break;
            case 0x00f0:name=@"Razer DeathAdder V4 Pro Carbon Fiber";control=0;keyboard=NO;break;
            case 0x00ab:name=@"Razer Basilisk V3 Pro";control=0;keyboard=NO;break;
            case 0x00cd:name=@"Razer Basilisk V3 Pro 35K";control=0;keyboard=NO;break;
            case 0x00d7:name=@"Razer Basilisk V3 Pro 35K Phantom Green";control=0;keyboard=NO;break;
            case 0x00b0:name=@"Razer Cobra Pro";control=0;keyboard=NO;break;
            case 0x009f:name=@"Razer Viper Mini Signature Edition";control=0;keyboard=NO;break;
            case 0x00bf:name=@"Razer DeathAdder V4 Pro";control=0;keyboard=NO;break;
        }
        if(name&&interface&&interface.intValue==control)return @{@"kind":@(BBReceiverRazer),@"name":name,@"category":keyboard?@"Keyboard":@"Mouse",@"transaction":keyboard?@0x9f:@0x1f};
    }
    if(vid==0x3434&&pid==0xd028&&interface&&interface.intValue==4&&page>=0xff00&&BBHIDReportMatches(desc,0xb3,9,63)&&BBHIDReportMatches(desc,0xb4,8,63))
        return @{@"kind":@(BBReceiverKeychron),@"name":@"Keychron Ultra-Link 8K (M5 / M6 8K)",@"category":@"Mouse"};
    if(vid==0x258a&&pid==0x2022&&(page==0xffa0||page==0xffff)&&BBHIDReportMatches(desc,0,11,64))
        return @{@"kind":@(BBReceiverGlorious),@"name":@"Glorious Model O Wireless",@"category":@"Mouse"};
    if(vid==0x1038&&page==0xffc0&&BBHIDReportMatches(desc,0,9,64)){
        NSString*name=nil;
        switch(pid){case 0x1838:case 0x1878:name=@"SteelSeries Aerox 3 Wireless";break;
            case 0x1852:case 0x185c:case 0x1860:name=@"SteelSeries Aerox 5 Wireless";break;
            case 0x1858:case 0x1874:name=@"SteelSeries Aerox 9 Wireless";break;}
        if(name)return @{@"kind":@(BBReceiverSteelSeries),@"name":name,@"category":@"Mouse"};
    }
    return BBModernReceiverProfile(p);
}
static BBReceiverKind receiverKind(NSDictionary*p){
    if(![p[@"Transport"] isEqual:@"USB"])return BBReceiverNone;
    unsigned vid=[p[@"VendorID"] intValue],pid=[p[@"ProductID"] intValue],page=[p[@"PrimaryUsagePage"] intValue],usage=[p[@"PrimaryUsage"] intValue];
    if(vid==0x3837&&pid==0x1015&&[p[@"Product"] isEqual:@"MCHOSE K87 V3 2.4G"]&&page==0xff80&&usage==1)return BBReceiverQHW;
    NSString*name=p[@"Product"];
    BOOL namedReceiver=[name isKindOfClass:NSString.class]&&[name rangeOfString:@"receiver" options:NSCaseInsensitiveSearch].location!=NSNotFound;
    BOOL superstrike=pid==0xc54d&&BBHIDReportMatches(p[@"ReportDescriptor"],0x10,9,6);
    if(vid==0x046d&&page==0xff00&&usage==1&&(namedReceiver||superstrike))return BBReceiverLogitech;
    if(vid==0xa8a5&&pid==0x2255&&page==1&&usage==2&&BBYJXDescriptorMatches(p[@"ReportDescriptor"]))return BBReceiverYJX;
    if(vid==0x3554&&pid==0xfa09&&page==0xff02&&BBHIDReportMatches(p[@"ReportDescriptor"],0x13,9,19)&&BBHIDReportMatches(p[@"ReportDescriptor"],0x13,8,19))return BBReceiverAulaF75;
    if(vid==0x089d&&pid==0x062f&&page==0xff00&&usage==1&&BBHIDReportMatches(p[@"ReportDescriptor"],0x0f,11,32))return BBReceiverAulaSC580;
    return (BBReceiverKind)[receiverProfile(p)[@"kind"] unsignedIntegerValue];
}
static NSString *physicalID(NSDictionary*p){return [NSString stringWithFormat:@"%04x:%04x:%@",[p[@"VendorID"] intValue],[p[@"ProductID"] intValue],p[@"LocationID"]?:@0];}

@interface BBChannel:NSObject {
    IOHIDDeviceRef _device; uint8_t _buffer[512]; BOOL _opened;
}
@property NSMutableArray<NSDictionary*> *frames;
@property NSSet<NSNumber*> *allowedInputReports;
@property IOReturn lastError;
@property uint8_t logitechSoftwareID;
@property(copy) void(^inputHandler)(NSDictionary*);
- (instancetype)initWithDevice:(IOHIDDeviceRef)d;
- (BOOL)open;
- (NSDictionary*)exchange:(uint8_t)rid payload:(NSData*)data matching:(BOOL(^)(NSDictionary*))match;
- (NSData*)sc580Status:(uint8_t)sequence;
- (NSData*)featureQuery:(NSData*)query delay:(NSTimeInterval)delay;
- (NSNumber*)razerValue:(uint8_t)command transaction:(uint8_t)transaction;
- (NSData*)featureQuery:(NSData*)query reportID:(uint8_t)rid delay:(NSTimeInterval)delay;
@end
static void reportCallback(void *ctx,IOReturn result,void *sender,IOHIDReportType type,uint32_t rid,uint8_t*p,CFIndex n){
    BBChannel*c=(__bridge BBChannel*)ctx;
    if(type!=kIOHIDReportTypeInput||result!=0||n<1||n>512||![c.allowedInputReports containsObject:@(rid)])return;
    NSDictionary*f=@{@"id":@(rid),@"data":[NSData dataWithBytes:p length:n]};
    if(c.inputHandler)c.inputHandler(f);
    if(c.frames.count<64)[c.frames addObject:f];
}
@implementation BBChannel
- (instancetype)initWithDevice:(IOHIDDeviceRef)d {if((self=[super init])){_device=(IOHIDDeviceRef)CFRetain(d);_frames=[NSMutableArray new];
    BBReceiverKind kind=receiverKind(property(d));NSArray*ids=@[];
    switch(kind){
        case BBReceiverLogitech:ids=@[@0x10,@0x11];break;
        case BBReceiverQHW:ids=@[@0x4d];break;
        case BBReceiverYJX:ids=@[@0xab,@0xf0];break;
        case BBReceiverAulaF75:ids=@[@0x13];break;
        case BBReceiverKeychron:ids=@[@0xb4];break;
        case BBReceiverSteelSeries:ids=@[@0];break;
        case BBReceiverCompx:ids=@[@8];break;
        case BBReceiverATKKeyboard:ids=@[@4];break;
        case BBReceiverASUSMouse:ids=@[@3];break;
        case BBReceiverASUSOmni:ids=@[@1];break;
        default:break; // Feature-only protocols never consume input reports.
    }
    _allowedInputReports=[NSSet setWithArray:ids];
}return self;}
- (BOOL)open {
    _lastError=IOHIDDeviceOpen(_device,kIOHIDOptionsTypeNone);if(_lastError)return NO;
    _opened=YES;IOHIDDeviceRegisterInputReportCallback(_device,_buffer,sizeof(_buffer),reportCallback,(__bridge void*)self);
    IOHIDDeviceScheduleWithRunLoop(_device,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);return YES;
}
- (NSDictionary*)exchange:(uint8_t)rid payload:(NSData*)data matching:(BOOL(^)(NSDictionary*))match {
    if(!_opened)return nil;[_frames removeAllObjects];
    NSMutableData*packet=[NSMutableData new];if(rid)[packet appendBytes:&rid length:1];[packet appendData:data];
    _lastError=IOHIDDeviceSetReport(_device,kIOHIDReportTypeOutput,rid,packet.bytes,packet.length);if(_lastError)return nil;
    CFAbsoluteTime until=CFAbsoluteTimeGetCurrent()+0.65;
    while(CFAbsoluteTimeGetCurrent()<until){
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,true);
        for(NSDictionary*f in [_frames copy]){if(match(f))return f;}
        [_frames removeAllObjects];
    }
    _lastError=kIOReturnTimeout;return nil;
}
// Unnumbered feature reports have no leading zero in IOHID's buffer.
- (NSData*)featureQuery:(NSData*)query delay:(NSTimeInterval)delay {
    return [self featureQuery:query reportID:0 delay:delay];
}
- (NSData*)featureQuery:(NSData*)query reportID:(uint8_t)rid delay:(NSTimeInterval)delay {
    if(!_opened||!query.length||query.length+1>sizeof _buffer)return nil;
    NSMutableData*packet=[NSMutableData new];if(rid)[packet appendBytes:&rid length:1];[packet appendData:query];
    _lastError=IOHIDDeviceSetReport(_device,kIOHIDReportTypeFeature,rid,packet.bytes,packet.length);
    if(_lastError)return nil;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,delay,false);
    uint8_t b[512]={0};b[0]=rid;CFIndex n=packet.length;
    _lastError=IOHIDDeviceGetReport(_device,kIOHIDReportTypeFeature,rid,b,&n);
    return _lastError?nil:[NSData dataWithBytes:b length:n];
}
- (NSNumber*)razerValue:(uint8_t)command transaction:(uint8_t)transaction {
    for(int attempt=0;attempt<3;attempt++){
        NSData*reply=[self featureQuery:BBRazerQuery(transaction,command) delay:0.1];
        NSNumber*value=BBRazerDecode(reply,transaction,command);if(value)return value;
        if(_lastError&&_lastError!=kIOReturnTimeout)return nil;
    }
    _lastError=kIOReturnTimeout;return nil;
}
- (NSData*)sc580Status:(uint8_t)sequence {
    if(!_opened)return nil;NSData*q=BBAulaSC580Query(sequence);
    _lastError=IOHIDDeviceSetReport(_device,kIOHIDReportTypeFeature,0x0f,q.bytes,q.length);
    if(_lastError)return nil;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.015,false);
    for(int attempt=0;attempt<3;attempt++){
        uint8_t b[33]={0x0f};CFIndex n=sizeof b;
        _lastError=IOHIDDeviceGetReport(_device,kIOHIDReportTypeFeature,0x0f,b,&n);
        if(_lastError)return nil;
        NSData*r=[NSData dataWithBytes:b length:n];if(BBAulaSC580Decode(r,sequence))return r;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.1,false);
    }
    _lastError=kIOReturnTimeout;return nil;
}
- (void)dealloc {if(_opened){IOHIDDeviceRegisterInputReportCallback(_device,_buffer,sizeof(_buffer),NULL,NULL);IOHIDDeviceUnscheduleFromRunLoop(_device,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);IOHIDDeviceClose(_device,0);}if(_device)CFRelease(_device);}
@end

static NSDictionary *BBCompxBattery(BBChannel*c){
    __block NSDictionary*link=nil,*reading=nil;
    [c exchange:8 payload:BBCompxQuery(3) matching:^BOOL(NSDictionary*f){link=BBCompxDecode(f[@"data"],[f[@"id"] intValue],3);return link!=nil;}];
    if(![link[@"online"] boolValue])return nil;
    [c exchange:8 payload:BBCompxQuery(4) matching:^BOOL(NSDictionary*f){reading=BBCompxDecode(f[@"data"],[f[@"id"] intValue],4);return reading!=nil;}];
    return reading;
}
static BOOL BBASUSKeyboardInterfaceMatches(NSDictionary*p,NSString*physical){
    return [p[@"Transport"] isEqual:@"USB"]&&p[@"LocationID"]&&[physicalID(p) isEqual:physical]&&p[@"USBInterfaceNumber"]&&[p[@"USBInterfaceNumber"] intValue]==2&&[p[@"PrimaryUsagePage"] intValue]==0xff00&&[p[@"PrimaryUsage"] intValue]==2&&BBHIDReportMatches(p[@"ReportDescriptor"],2,9,63)&&BBHIDReportMatches(p[@"ReportDescriptor"],2,8,63);
}

static NSData *hpp(BBChannel*c,uint8_t slot,uint8_t feature,uint8_t function,NSData*params){
    // Root replies do not echo the requested feature ID. Distinguish consecutive requests by their software IDs.
    uint8_t softwareID=c.logitechSoftwareID;
    c.logitechSoftwareID=softwareID?softwareID%15+1:arc4random_uniform(15)+1;
    uint8_t fn=(uint8_t)((function<<4)|c.logitechSoftwareID);
    uint8_t bytes[6]={slot,feature,fn,0,0,0};
    if(params.length>3)return nil;if(params.length)memcpy(bytes+3,params.bytes,params.length);
    NSDictionary*f=[c exchange:0x10 payload:[NSData dataWithBytes:bytes length:6] matching:^BOOL(NSDictionary*f){
        NSDictionary*e=BBLogitechEnvelope(f[@"data"],[f[@"id"] intValue]);
        return [e[@"slot"] intValue]==slot&&[e[@"feature"] intValue]==feature&&[e[@"function"] intValue]==fn;
    }];
    if(!f)return nil;return BBLogitechEnvelope(f[@"data"],[f[@"id"] intValue])[@"payload"];
}
static NSNumber *featureIndex(BBChannel*c,uint8_t slot,uint16_t feature){
    uint8_t bytes[3]={feature>>8,feature&255,0};
    NSData*d=hpp(c,slot,0,0,[NSData dataWithBytes:bytes length:3]);
    return d.length?@(((const uint8_t*)d.bytes)[0]):nil;
}
static NSDictionary *BBLogitechBattery(BBChannel*c,uint8_t slot){
    uint16_t feature=0x1004;
    NSNumber*index=featureIndex(c,slot,feature);
    if(!index&&c.lastError==kIOReturnTimeout)index=featureIndex(c,slot,feature);
    if(!index)return nil;
    // Only an explicit zero means the mouse does not support the unified battery feature.
    if(index.unsignedCharValue==0){
        feature=0x1000;
        index=featureIndex(c,slot,feature);
    }
    if(index.unsignedCharValue==0)return nil;
    NSData*payload=hpp(c,slot,index.unsignedCharValue,feature==0x1004?1:0,[NSData data]);
    return BBLogitechDecodeBattery(payload,feature);
}
static NSDictionary *logitechName(BBChannel*c,uint8_t slot,uint8_t index){
    if(!index)return nil;
    NSData*len=hpp(c,slot,index,0,[NSData data]);if(!len.length)return nil;
    int count=((uint8_t*)len.bytes)[0];if(count<1||count>96)return nil;
    NSMutableData*name=[NSMutableData new];
    while(name.length<(NSUInteger)count){uint8_t offset=name.length;NSData*part=hpp(c,slot,index,1,[NSData dataWithBytes:&offset length:1]);if(!part.length)return nil;[name appendBytes:part.bytes length:MIN(part.length,count-name.length)];}
    NSString*s=[[NSString alloc]initWithData:name encoding:NSUTF8StringEncoding];if(!s.length)return nil;
    NSData*type=hpp(c,slot,index,2,[NSData data]);int kind=type.length?((uint8_t*)type.bytes)[0]:-1;
    NSString*category=(kind==0||kind==2)?@"Keyboard":((kind>=3&&kind<=5)?@"Mouse":@"Unknown");
    return @{@"name":s,@"category":category};
}

static NSDictionary *BBPowerDetails(NSString*identity,NSString*name,NSString*category,NSDictionary*reading){
    BOOL charging=[reading[@"charging"] boolValue];
    return @{@"Name":name,@"Type":@"Accessory Source",@"Accessory Category":category,@"Accessory Identifier":identity,@"Transport Type":@"USB",@"Current Capacity":reading[@"percent"],@"Max Capacity":@100,@"Power Source State":charging?@"AC Power":@"Battery Power",@"Is Charging":@(charging),@"Is Charged":@(!charging&&[reading[@"full"] boolValue]),@"Is Present":@YES,@"Low Warn Level":@15};
}
static NSString *BBChargeStatus(NSDictionary*record){
    if(![record[@"connected"] boolValue]||![record[@"fresh"] boolValue]||!record[@"charging"])return @"充电状态未知";
    if([record[@"charging"] boolValue])return @"正在充电";
    return [record[@"full"] boolValue]?@"未充电 · 已充满":@"未充电";
}

@interface BBSource:NSObject {void *_handle;}
@property NSString *identity;
@property NSString *name;
@property NSString *category;
@property NSString *physical;
@property NSDictionary *reading;
@property NSDate *updated;
- (BOOL)publish:(NSString*)identity name:(NSString*)name category:(NSString*)category reading:(NSDictionary*)reading;
@end
@implementation BBSource
- (BOOL)publish:(NSString*)identity name:(NSString*)name category:(NSString*)category reading:(NSDictionary*)reading {
    static int(*create)(void**);static int(*set)(void*,CFDictionaryRef);static dispatch_once_t once;
    dispatch_once(&once,^{void*lib=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY);create=dlsym(lib,"IOPSCreatePowerSource");set=dlsym(lib,"IOPSSetPowerSourceDetails");});
    if(!create||!set)return NO;if(!_handle&&create(&_handle)!=0)return NO;
    NSDictionary*d=BBPowerDetails(identity,name,category,reading);
    if(set(_handle,(__bridge CFDictionaryRef)d)!=0)return NO;
    self.identity=identity;self.name=name;self.category=category;self.reading=reading;self.updated=[NSDate date];return YES;
}
- (void)dealloc {if(_handle){int(*release)(void*)=dlsym(RTLD_DEFAULT,"IOPSReleasePowerSource");if(release)release(_handle);}}
@end

@interface BBEngine:NSObject
@property NSMutableDictionary<NSString*,BBSource*> *sources;
@property NSMutableDictionary<NSString*,NSDictionary*> *samples;
@property NSMutableDictionary<NSString*,NSDictionary*> *known;
@property NSMutableDictionary<NSString*,NSString*> *errors;
@property NSMutableDictionary<NSString*,BBChannel*> *listeners;
@property NSMutableDictionary<NSString*,NSMutableDictionary*> *yjxDiagnostics;
@property NSSet *previousPresent;
@property NSArray *snapshot;
@property NSLock *lock;
@property BOOL stopping;
@property BOOL urgent;
@property BOOL forcePoll;
@property NSMutableSet<NSString*>*refreshTargets;
@property NSMutableSet<NSString*>*deletionTargets;
@property BOOL diagnostic;
@property NSTimeInterval lastQuery;
@property IOHIDAccessType lastAccess;
- (void)scan;
- (void)run;
- (NSArray*)status;
- (void)kick;
- (void)settingsChanged;
- (void)refreshIdentity:(NSString*)identity;
- (void)forgetIdentity:(NSString*)identity;
- (void)applyDeletions:(NSSet*)present;
@end
static NSString *logicalID(NSString *physical,int slot){return [NSString stringWithFormat:@"local.batterybridge.%@.%d",physical,slot];}
static BOOL mappingEnabled(NSString *identity){return [[BBPreferences() dictionaryForKey:@"MappedDevices"][identity] boolValue];}
@implementation BBEngine
- (instancetype)init {if((self=[super init])){_sources=[NSMutableDictionary new];_samples=[NSMutableDictionary new];_known=[[BBPreferences() dictionaryForKey:@"KnownDevices"] mutableCopy]?:[NSMutableDictionary new];_errors=[NSMutableDictionary new];_listeners=[NSMutableDictionary new];_yjxDiagnostics=[NSMutableDictionary new];_snapshot=@[];_previousPresent=[NSSet set];_lock=[NSLock new];_forcePoll=YES;_refreshTargets=[NSMutableSet new];_deletionTargets=[NSMutableSet new];_lastAccess=IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);}return self;}
- (NSArray*)status {[_lock lock];NSArray*r=[_snapshot copy];[_lock unlock];return r;}
- (void)kick {[_lock lock];_urgent=YES;_forcePoll=YES;[_lock unlock];}
- (void)settingsChanged {[_lock lock];_urgent=YES;[_lock unlock];}
- (void)refreshIdentity:(NSString*)identity {if(!identity.length)return;[_lock lock];[_refreshTargets addObject:identity];_urgent=YES;[_lock unlock];}
- (void)forgetIdentity:(NSString*)identity {
    if(!identity.length)return;
    [_lock lock];[_deletionTargets addObject:identity];_urgent=YES;[_lock unlock];
}
- (void)applyDeletions:(NSSet*)present {
    [_lock lock];NSSet*targets=[_deletionTargets copy];[_deletionTargets removeAllObjects];[_lock unlock];
    for(NSString*identity in targets){
        NSDictionary*info=_known[identity];if(!info||[present containsObject:info[@"physical"]])continue;
        [_known removeObjectForKey:identity];[_samples removeObjectForKey:identity];[_sources removeObjectForKey:identity];
        void(^clearMapping)(void)=^{NSMutableDictionary*choices=[[BBPreferences() dictionaryForKey:@"MappedDevices"] mutableCopy];[choices removeObjectForKey:identity];if(choices)[BBPreferences() setObject:choices forKey:@"MappedDevices"];};
        if(NSThread.isMainThread)clearMapping();else dispatch_async(dispatch_get_main_queue(),clearMapping);
    }
}
- (void)remember:(NSString*)identity physical:(NSString*)physical name:(NSString*)name category:(NSString*)category {
    if([category isEqual:@"Unknown"])return;
    _known[identity]=@{@"identity":identity,@"physical":physical,@"name":name,@"category":category};
}
- (void)storeReading:(NSDictionary*)reading physical:(NSString*)physical slot:(int)slot name:(NSString*)name category:(NSString*)category {
    if(!reading||[category isEqual:@"Unknown"])return;
    NSString*identity=logicalID(physical,slot);[self remember:identity physical:physical name:name category:category];
    _samples[identity]=@{@"reading":reading,@"updated":@([NSDate.date timeIntervalSince1970])};
}
- (void)reconcile:(NSSet*)present interval:(NSTimeInterval)interval {
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    for(NSString*k in [_sources.allKeys copy]){NSDictionary*info=_known[k],*sample=_samples[k];if(!mappingEnabled(k)||![present containsObject:info[@"physical"]]||!BBReadingFresh([sample[@"updated"] doubleValue],now,interval))[_sources removeObjectForKey:k];}
    for(NSString*k in _known){
        NSDictionary*info=_known[k],*sample=_samples[k];if(!mappingEnabled(k)||![present containsObject:info[@"physical"]]||!BBReadingFresh([sample[@"updated"] doubleValue],now,interval))continue;
        BBSource*s=_sources[k];if(s&&s.updated.timeIntervalSince1970>=[sample[@"updated"] doubleValue])continue;
        s=s?:[BBSource new];s.physical=info[@"physical"];
        if([s publish:k name:info[@"name"] category:info[@"category"] reading:sample[@"reading"]])_sources[k]=s;else _errors[info[@"physical"]]=@"电量已读取，系统电源发布失败";
    }
}
- (void)scan {
    @autoreleasepool {
    IOHIDManagerRef manager=IOHIDManagerCreate(kCFAllocatorDefault,0);IOHIDManagerSetDeviceMatching(manager,NULL);
    NSSet*devices=CFBridgingRelease(IOHIDManagerCopyDevices(manager));NSMutableSet*present=[NSMutableSet new];NSMutableArray*rows=[NSMutableArray new];NSMutableSet*seen=[NSMutableSet new];
    for(id obj in devices){NSDictionary*p=property((__bridge IOHIDDeviceRef)obj);if(receiverKind(p)!=BBReceiverNone)[present addObject:physicalID(p)];}
    [self applyDeletions:present];
    NSTimeInterval interval=BBInterval([BBPreferences() objectForKey:@"ReportInterval"]);
    IOHIDAccessType access=IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    [_lock lock];BOOL forced=_forcePoll;_forcePoll=NO;NSSet*targets=[_refreshTargets copy];[_refreshTargets removeAllObjects];[_lock unlock];forced=forced||(access==kIOHIDAccessTypeGranted&&_lastAccess!=access);_lastAccess=access;
    NSMutableSet*newReceivers=[present mutableCopy];[newReceivers minusSet:_previousPresent];
    // Losing a receiver invalidates its cache immediately, even if it is reinserted before the next period.
    for(NSString*k in [_samples.allKeys copy])if(![present containsObject:_known[k][@"physical"]])[_samples removeObjectForKey:k];
    for(NSString*k in [_listeners.allKeys copy])if(![present containsObject:k])[_listeners removeObjectForKey:k];
    _previousPresent=[present copy];NSTimeInterval queryStarted=NSDate.date.timeIntervalSince1970;
    BOOL due=BBQueryDue(_lastQuery,queryStarted,interval,forced,newReceivers.count>0);
    if(due)_lastQuery=queryStarted;
    [self reconcile:present interval:interval];
    for(id obj in devices){
        IOHIDDeviceRef dev=(__bridge IOHIDDeviceRef)obj;NSDictionary*p=property(dev);if(![p[@"Transport"] isEqual:@"USB"])continue;
        BBReceiverKind kind=receiverKind(p);
        if(kind==BBReceiverNone)continue;
        BOOL qhw=kind==BBReceiverQHW,yjx=kind==BBReceiverYJX,aulaF75=kind==BBReceiverAulaF75,aulaSC580=kind==BBReceiverAulaSC580;
        NSString*physical=physicalID(p);if([seen containsObject:physical])continue;[seen addObject:physical];
        NSString*name=qhw?@"MCHOSE K87 V3":(yjx?@"USB Receiver (YJX)":p[@"Product"]?:@"Logitech Receiver");
        if(aulaF75)name=@"AULA F75";if(aulaSC580)name=@"AULA SC580";
        NSDictionary*profile=receiverProfile(p);
        if(profile){name=profile[@"name"];[self remember:logicalID(physical,0) physical:physical name:name category:profile[@"category"]];}
        if(qhw)[self remember:logicalID(physical,0) physical:physical name:name category:@"Keyboard"];
        if(aulaF75||aulaSC580)[self remember:logicalID(physical,0) physical:physical name:name category:aulaF75?@"Keyboard":@"Mouse"];
        BOOL targeted=NO;for(NSString*identity in targets)if([identity hasPrefix:[NSString stringWithFormat:@"local.batterybridge.%@.",physical]]){targeted=YES;break;}
        if(yjx){
            if(!_yjxDiagnostics[physical])_yjxDiagnostics[physical]=[NSMutableDictionary new];
            NSMutableDictionary*health=_yjxDiagnostics[physical];
            [self remember:logicalID(physical,0) physical:physical name:name category:@"Mouse"];
            BBChannel*listener=_listeners[physical];
            if(!listener){
                listener=[[BBChannel alloc]initWithDevice:dev];
                if(![listener open]){health[@"openError"]=errorText(listener.lastError);_errors[physical]=[NSString stringWithFormat:@"设备访问被拒绝 %@；请检查输入监控权限",errorText(listener.lastError)];continue;}
                health[@"openError"]=@"0x00000000";
                __weak BBEngine*weakSelf=self;
                listener.inputHandler=^(NSDictionary*f){
                    BBEngine*engine=weakSelf;if(!engine)return;
                    NSMutableDictionary*stats=engine.yjxDiagnostics[physical];NSData*d=f[@"data"];const uint8_t*b=d.bytes;
                    NSUInteger offset=(d.length&&b[0]==[f[@"id"] intValue])?1:0;
                    stats[@"receivedVendorReports"]=@([stats[@"receivedVendorReports"] unsignedIntegerValue]+1);
                    stats[@"lastReportID"]=f[@"id"];stats[@"lastReportLength"]=@(d.length);
                    if(d.length>offset){stats[@"lastCommand"]=@(b[offset]);if(b[offset]==0x30){
                        NSMutableString*hex=[NSMutableString new];for(NSUInteger j=offset;j<MIN(d.length,offset+12);j++)[hex appendFormat:@"%02x ",b[j]];stats[@"lastBatteryFrame"]=hex;
                    }}
                    NSDictionary*reading=BBYJXDecode(d,[f[@"id"] intValue]);if(!reading)return;
                    stats[@"lastValidBattery"]=reading;stats[@"lastBatteryTime"]=@(NSDate.date.timeIntervalSince1970);
                    [engine storeReading:reading physical:physical slot:0 name:name category:@"Mouse"];
                    [engine.errors removeObjectForKey:physical];[engine.lock lock];engine.urgent=YES;[engine.lock unlock];
                };
                _listeners[physical]=listener;
            }
            if(due||targeted){
                [listener exchange:0xf0 payload:BBYJXOnlineQuery() matching:^BOOL(NSDictionary*f){
                    NSData*d=f[@"data"];const uint8_t*b=d.bytes;NSUInteger offset=(d.length&&b[0]==[f[@"id"] intValue])?1:0;
                    return d.length>offset&&b[offset]==0xed;
                }];
                __block NSDictionary*reading=nil;
                for(int attempt=0;attempt<2&&!reading;attempt++){
                    health[@"batteryQueries"]=@([health[@"batteryQueries"] unsignedIntegerValue]+1);
                    [listener exchange:0xf0 payload:BBYJXBatteryQuery() matching:^BOOL(NSDictionary*f){reading=BBYJXDecode(f[@"data"],[f[@"id"] intValue]);return reading!=nil;}];
                    health[@"lastQueryError"]=errorText(listener.lastError);health[@"lastQueryTime"]=@(NSDate.date.timeIntervalSince1970);
                }
                if(reading)[_errors removeObjectForKey:physical];
                else _errors[physical]=[NSString stringWithFormat:@"接口已打开，未收到有效 0x30 电量回复（%@）；请唤醒设备或关闭占用接收器的网页驱动",errorText(listener.lastError)];
            }
            continue;
        }
        if(!due&&!targeted)continue;
        BBChannel*c=[[BBChannel alloc]initWithDevice:dev];
        if(![c open]){
            if(profile){NSString*identity=logicalID(physical,0);[_samples removeObjectForKey:identity];[_sources removeObjectForKey:identity];}
            _errors[physical]=[NSString stringWithFormat:@"设备访问被拒绝 %@；请检查输入监控权限",errorText(c.lastError)];continue;
        }
        if(profile){
            __block NSDictionary*reading=nil;
            if(kind==BBReceiverRazer){
                uint8_t transaction=[profile[@"transaction"] intValue];
                NSNumber*level=[c razerValue:0x80 transaction:transaction];
                if(level){
                    NSNumber*charge=[c razerValue:0x84 transaction:transaction];
                    // Both reads must succeed before publishing a current sample.
                    if(charge)reading=@{@"percent":level,@"charging":@(charge.boolValue),@"full":@(level.intValue==100&&!charge.boolValue),@"approximate":@NO};
                }
            }else if(kind==BBReceiverASUSOmni){
                __block NSDictionary*paired=nil;
                [c exchange:1 payload:BBASUSPairQuery() matching:^BOOL(NSDictionary*f){paired=BBASUSPairedKeyboard(f[@"data"],[f[@"id"] intValue]);return paired!=nil;}];
                if(paired){
                    // Resolve the keyboard channel on THIS physical receiver only.
                    for(id sibling in devices){
                        IOHIDDeviceRef keyboardDev=(__bridge IOHIDDeviceRef)sibling;NSDictionary*kp=property(keyboardDev);
                        if(!BBASUSKeyboardInterfaceMatches(kp,physical))continue;
                        BBChannel*keyboardChannel=[[BBChannel alloc]initWithDevice:keyboardDev];keyboardChannel.allowedInputReports=[NSSet setWithObject:@2];
                        if(![keyboardChannel open]){c.lastError=keyboardChannel.lastError;break;}
                        for(int attempt=0;attempt<2&&!reading;attempt++)[keyboardChannel exchange:2 payload:BBASUSQuery(YES) matching:^BOOL(NSDictionary*f){reading=BBASUSDecode(f[@"data"],[f[@"id"] intValue],YES);return reading!=nil;}];
                        c.lastError=keyboardChannel.lastError;if(reading)name=[@"ASUS " stringByAppendingString:paired[@"name"]];break;
                    }
                }
            }else for(int attempt=0;attempt<3&&!reading;attempt++){
                if(kind==BBReceiverCompx){
                    reading=BBCompxBattery(c);
                    if(!reading)break; // Never use a receiver's cached percentage while offline.
                }else if(kind==BBReceiverMchose){
                    uint8_t rid=[profile[@"reportID"] intValue];
                    reading=BBMchoseDecode([c featureQuery:BBMchoseQuery(rid==0x11?20:64) reportID:rid delay:0.03],rid);
                }else if(kind==BBReceiverATKKeyboard){
                    uint16_t seq=1+arc4random_uniform(65535);
                    [c exchange:4 payload:BBATKKeyboardQuery(seq) matching:^BOOL(NSDictionary*f){reading=BBATKKeyboardDecode(f[@"data"],[f[@"id"] intValue],seq);return reading!=nil;}];
                }else if(kind==BBReceiverASUSMouse)[c exchange:3 payload:BBASUSQuery(NO) matching:^BOOL(NSDictionary*f){reading=BBASUSDecode(f[@"data"],[f[@"id"] intValue],NO);return reading!=nil;}];
                else if(kind==BBReceiverGlorious)reading=BBGloriousDecode([c featureQuery:BBGloriousQuery() delay:0.1]);
                else if(kind==BBReceiverKeychron)[c exchange:0xb3 payload:BBKeychronQuery() matching:^BOOL(NSDictionary*f){reading=BBKeychronDecode(f[@"data"],[f[@"id"] intValue]);return reading!=nil;}];
                else if(kind==BBReceiverSteelSeries)[c exchange:0 payload:BBSteelSeriesQuery() matching:^BOOL(NSDictionary*f){if([f[@"id"] intValue]!=0)return NO;reading=BBSteelSeriesDecode(f[@"data"]);return reading!=nil;}];
                if(!reading&&attempt<2)CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.1,false);
            }
            if(reading){[self storeReading:reading physical:physical slot:0 name:name category:profile[@"category"]];[_errors removeObjectForKey:physical];}
            else {
                // A sleeping/off receiver must not keep publishing its last reading.
                NSString*identity=logicalID(physical,0);[_samples removeObjectForKey:identity];[_sources removeObjectForKey:identity];
                _errors[physical]=[NSString stringWithFormat:@"预览适配：未收到有效电量（%@）；请确认 2.4G 模式、唤醒设备后刷新",(c.lastError?errorText(c.lastError):@"回复格式不匹配")];
            }
        }else if(aulaF75||aulaSC580){
            __block NSDictionary*reading=nil;
            for(int attempt=0;attempt<2&&!reading;attempt++){
                if(aulaF75)[c exchange:0x13 payload:BBAulaF75Query() matching:^BOOL(NSDictionary*f){reading=BBAulaF75Decode(f[@"data"],[f[@"id"] intValue]);return reading!=nil;}];
                else {uint8_t seq=arc4random_uniform(256);reading=BBAulaSC580Decode([c sc580Status:seq],seq);}
                if(!reading&&attempt==0)CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.2,false);
            }
            if(reading[@"percent"]){[self storeReading:reading physical:physical slot:0 name:name category:aulaF75?@"Keyboard":@"Mouse"];[_errors removeObjectForKey:physical];}
            else if(reading){
                // Never retain/publish a previous percentage after a cable-mode reply.
                NSString*identity=logicalID(physical,0);[_samples removeObjectForKey:identity];[_sources removeObjectForKey:identity];
                _errors[physical]=@"设备已连接充电线，接收器不提供真实百分比；切回 2.4G 后刷新";
            }else _errors[physical]=[NSString stringWithFormat:@"未收到有效电量（%@）；请切到 2.4G、唤醒设备并关闭其他驱动",errorText(c.lastError)];
        }else if(qhw){
            uint8_t seq=arc4random_uniform(256);__block NSDictionary*reading=nil;
            [c exchange:0x4d payload:BBQHWQuery(seq) matching:^BOOL(NSDictionary*f){reading=BBQHWDecode(f[@"data"],[f[@"id"] intValue],seq);return reading!=nil;}];
            if(reading){[self storeReading:reading physical:physical slot:0 name:name category:@"Keyboard"];[_errors removeObjectForKey:physical];}
            else _errors[physical]=@"未收到有效电量；可能休眠或官方驱动正在使用设备";
        }else{
            BOOL found=NO;
            for(uint8_t slot=1;slot<=6&&!self.stopping;slot++){
                if(!due&&![targets containsObject:logicalID(physical,slot)])continue;
                NSDictionary*reading=BBLogitechBattery(c,slot);if(!reading)continue;
                NSDictionary*info=logitechName(c,slot,featureIndex(c,slot,0x0005).unsignedCharValue);if(![info[@"name"] length]||[info[@"category"] isEqual:@"Unknown"]){_errors[physical]=@"已读到电量，设备名称或类型尚未确认";continue;}
                [self storeReading:reading physical:physical slot:slot name:info[@"name"] category:info[@"category"]];found=YES;
            }
            if(found)[_errors removeObjectForKey:physical];else if(!_errors[physical])_errors[physical]=@"未找到支持的电量回复；可能休眠或协议尚未适配";
        }
    }
    // Querying can take seconds. Reconcile a second time to honour selection changes made during a query.
    [self reconcile:present interval:interval];
    if(!self.diagnostic)[BBPreferences() setObject:_known forKey:@"KnownDevices"];
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    for(NSString*k in [[_known allKeys] sortedArrayUsingSelector:@selector(compare:)]){
        NSDictionary*info=_known[k],*sample=_samples[k];NSString*physical=info[@"physical"];BOOL connected=[present containsObject:physical];BOOL selected=mappingEnabled(k);BOOL fresh=BBReadingFresh([sample[@"updated"] doubleValue],now,interval);BOOL published=_sources[k]!=nil;
        NSString*state=!connected?@"接收器未连接":(published?@"已映射到系统电量":(fresh?(selected?@"等待系统接收":@"已读取，未选择映射"):(sample?@"上次电量已过期":@"等待有效电量")));
        if(connected&&_errors[physical])state=[state stringByAppendingFormat:@"；%@",_errors[physical]];
        NSMutableDictionary*row=[info mutableCopy];row[@"selectable"]=@YES;row[@"mapped"]=@(selected);row[@"connected"]=@(connected);row[@"status"]=state;row[@"published"]=@(published);
        if(sample){row[@"updated"]=sample[@"updated"];row[@"percent"]=sample[@"reading"][@"percent"];row[@"fresh"]=@(fresh);row[@"charging"]=sample[@"reading"][@"charging"]?:@NO;row[@"full"]=sample[@"reading"][@"full"]?:@NO;}
        [rows addObject:row];
    }
    NSMutableSet*unknown=[NSMutableSet new];
    for(id obj in devices){NSDictionary*p=property((__bridge IOHIDDeviceRef)obj);if(![p[@"Transport"] isEqual:@"USB"])continue;NSString*k=physicalID(p);BOOL hasKnown=NO;for(NSDictionary*info in _known.allValues)if([info[@"physical"] isEqual:k]){hasKnown=YES;break;}if(hasKnown||[unknown containsObject:k])continue;
        BOOL supported=[seen containsObject:k];if(!supported)continue;[unknown addObject:k];
        [rows addObject:@{@"name":p[@"Product"]?:@"USB 输入设备",@"physical":k,@"selectable":@NO,@"connected":@YES,@"status":(_errors[k]?:@"等待读取实际设备名称，读取后可选择映射")}];
    }
    [_lock lock];_snapshot=[rows copy];[_lock unlock];CFRelease(manager);
    if(!BBTestingUI&&!_diagnostic){
        NSString*directory=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/BatteryBridge"];
        NSDictionary*report=@{@"version":Version,@"time":@(now),@"hidAccess":@(access),@"devices":rows,@"yjx":_yjxDiagnostics};
        NSData*data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[directory stringByAppendingPathComponent:@"diagnostics.json"] atomically:YES];
    }
    if(_diagnostic){NSData*json=[NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:nil];puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);}
    }
}
- (void)run {
    while(!self.stopping){[self scan];for(int i=0;i<10&&!self.stopping;i++){[_lock lock];BOOL urgent=_urgent;_urgent=NO;[_lock unlock];if(urgent)break;NSTimeInterval started=NSDate.date.timeIntervalSince1970;CFRunLoopRunInMode(kCFRunLoopDefaultMode,1,false);NSTimeInterval remaining=1-(NSDate.date.timeIntervalSince1970-started);if(remaining>0)[NSThread sleepForTimeInterval:remaining];}}
    [_listeners removeAllObjects];[_sources removeAllObjects];
}
@end


static NSColor*BBGroupedColor(BOOL separator) {
    return [NSColor colorWithName:separator?@"BBGroupSeparator":@"BBGroupedBackground" dynamicProvider:^NSColor*(NSAppearance*appearance){
        BOOL dark=[[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua];
        return [NSColor colorWithWhite:separator?(dark?0.28:0.88):(dark?0.17:0.96) alpha:1];
    }];
}
static void BBDrawDeviceSeparator(CGFloat width, CGFloat y) {
    [BBGroupedColor(YES) setFill];
    NSRectFill(NSMakeRect(72,y,MAX(0,width-88),0.5));
}
@interface BBFlippedView:NSView
@property CGFloat groupHeight;
@property BOOL settingsGroup;
@end
@implementation BBFlippedView
- (BOOL)isFlipped{return YES;}
- (void)drawRect:(NSRect)dirty {
    NSRect rect=NSMakeRect(0,0,self.bounds.size.width,_groupHeight);
    [BBGroupedColor(NO) setFill];[[NSBezierPath bezierPathWithRoundedRect:rect xRadius:12 yRadius:12] fill];
    if(_settingsGroup){[BBGroupedColor(YES) setFill];NSRectFill(NSMakeRect(16,56,MAX(0,rect.size.width-32),0.5));}
}
@end
@protocol BBMappingTarget <NSObject>
- (void)setDeviceMapping:(NSMenuItem*)sender;
- (void)refreshDevice:(NSMenuItem*)sender;
- (void)deleteDevice:(NSMenuItem*)sender;
- (void)permission:(id)sender;
@end
@interface BBDeviceRow:NSView
@property NSDictionary*record;
@property(weak) id<BBMappingTarget> menuTarget;
@property NSSwitch*mappingSwitch;
@property NSButton*refreshButton;
@property NSButton*deleteButton;
@property BOOL showsSeparator;
- (instancetype)initWithFrame:(NSRect)frame record:(NSDictionary*)r;
@end
static NSTextField*cardLabel(NSString*text,NSRect frame,NSFont*font,NSColor*color){NSTextField*l=[NSTextField labelWithString:text];l.frame=frame;l.font=font;l.textColor=color;l.lineBreakMode=NSLineBreakByTruncatingTail;l.maximumNumberOfLines=1;return l;}
@interface BBDriveRow:NSView
@property BOOL showsSeparator;
@property(copy) void (^ejectAction)(NSNumber *mediaID);
@property NSNumber *ejectID;
- (instancetype)initWithFrame:(NSRect)frame record:(NSDictionary*)drive;
@end

static NSNumber *driveNumber(NSDictionary *record, NSString *key) {
    id value=record[key];
    return [value isKindOfClass:NSNumber.class]?value:nil;
}
static NSString *driveBytes(NSNumber *value) {
    return value?[NSByteCountFormatter stringFromByteCount:value.longLongValue countStyle:NSByteCountFormatterCountStyleDecimal]:nil;
}

static const CGFloat BBDriveRowHeight=128;

@interface BBDriveProgress : NSView
@property NSNumber *fraction;
@property NSColor *fillColor;
@end

@implementation BBDriveProgress
- (void)drawRect:(NSRect)dirtyRect {
    NSRect track=self.bounds;
    [NSColor.separatorColor setFill];
    NSBezierPath *outline=[NSBezierPath bezierPathWithRoundedRect:track xRadius:2 yRadius:2];
    [outline fill];
    BOOL depleted=self.fraction&&self.fraction.doubleValue==0&&[self.fillColor isEqual:NSColor.systemRedColor];
    if(self.fraction.doubleValue>0||depleted){
        [NSGraphicsContext saveGraphicsState];
        [outline addClip];
        track.size.width=depleted?4:track.size.width*self.fraction.doubleValue;
        [self.fillColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2 yRadius:2] fill];
        [NSGraphicsContext restoreGraphicsState];
    }
}
@end

static NSAttributedString *BBDriveMetric(NSString *name, NSString *value, CGFloat size) {
    NSFont *font=[NSFont systemFontOfSize:size];
    NSMutableAttributedString *text=[[NSMutableAttributedString alloc]initWithString:[name stringByAppendingString:@": "]
        attributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:NSColor.secondaryLabelColor}];
    [text appendAttributedString:[[NSAttributedString alloc]initWithString:value
        attributes:@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightRegular],
                     NSForegroundColorAttributeName:NSColor.labelColor}]];
    return text;
}

@implementation BBDriveRow
- (instancetype)initWithFrame:(NSRect)frame record:(NSDictionary*)drive {
    if(!(self=[super initWithFrame:frame]))return nil;
    CGFloat width=frame.size.width;
    CGFloat metricsWidth=MIN(320,floor(width*0.56));
    CGFloat metricsX=width-metricsWidth-62;
    CGFloat titleWidth=MAX(1,metricsX-84);
    NSImageView *icon=[[NSImageView alloc]initWithFrame:NSMakeRect(16,NSMidY(self.bounds)-20,40,40)];
    icon.image=[NSImage imageWithSystemSymbolName:@"internaldrive" accessibilityDescription:@"硬盘"];
    icon.imageAlignment=NSImageAlignCenter;
    icon.symbolConfiguration=[NSImageSymbolConfiguration configurationWithPointSize:28 weight:NSFontWeightRegular];
    icon.contentTintColor=NSColor.secondaryLabelColor;
    [self addSubview:icon];

    NSString *name=drive[@"name"]?:drive[@"id"]?:@"硬盘";
    NSTextField *title=cardLabel(name,NSMakeRect(72,72,titleWidth,20),[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],NSColor.labelColor);
    title.toolTip=name;[self addSubview:title];
    NSString *summary=[drive[@"internal"] boolValue]?@"内置硬盘":@"外置硬盘";
    NSArray<NSDictionary *> *volumes=drive[@"volumes"];
    BOOL hasStartupVolume=NO;
    for(NSDictionary *volume in volumes){
        if([volume[@"mount"] isEqual:@"/"]){hasStartupVolume=YES;break;}
    }
    NSMutableOrderedSet<NSString *> *volumeNames=[NSMutableOrderedSet orderedSet];
    for(NSDictionary *volume in volumes){
        NSString *volumeName=volume[@"name"];
        if(!volumeName.length||[volumeName isEqual:volume[@"id"]])continue;
        if(hasStartupVolume&&[volume[@"mount"] isEqual:@"/System/Volumes/Data"])continue;
        [volumeNames addObject:volumeName];
    }
    if(volumeNames.count)summary=[summary stringByAppendingFormat:@" ｜ %@",[volumeNames.array componentsJoinedByString:@"、"]];
    NSTextField *status=cardLabel(summary,NSMakeRect(72,51,titleWidth,17),[NSFont systemFontOfSize:11],NSColor.secondaryLabelColor);
    status.toolTip=summary;[self addSubview:status];
    NSString *update=drive[@"captureStatus"];
    if(!update&&([drive[@"usbSnapshot"] boolValue]||[drive[@"internal"] boolValue])){
        NSTimeInterval captured=[drive[@"captured_unix"] doubleValue];
        if(captured>0){
            NSString *time=[NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:captured] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
            update=[NSString stringWithFormat:@"更新于 %@",time];
        }
    }else if([update isEqual:@"插入时已读取"]&&[drive[@"usbSnapshot"] boolValue]){
        NSDate *captured=[NSDate dateWithTimeIntervalSince1970:[drive[@"captured_unix"] doubleValue]];
        update=[NSString stringWithFormat:@"插入时读取 · %@",[NSDateFormatter localizedStringFromDate:captured dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle]];
    }
    if(update.length){
        NSTextField *updated=cardLabel(update,NSMakeRect(72,34,titleWidth,15),[NSFont systemFontOfSize:10],NSColor.tertiaryLabelColor);
        updated.toolTip=update;[self addSubview:updated];
    }

    NSDictionary *health=drive[@"health"];
    NSString *healthStatus=health[@"status"],*healthText=nil;
    if([healthStatus isEqual:@"Verified"]||[healthStatus isEqual:@"Passed"])healthText=@"正常";
    else if([healthStatus isEqual:@"Failing"]||[healthStatus isEqual:@"Failed"])healthText=@"异常";

    NSNumber *temperature=driveNumber(health,@"temperature_c");
    NSNumber *capacity=driveNumber(drive,@"capacity"),*used=driveNumber(drive,@"used");
    NSString *capacityText=capacity.unsignedLongLongValue?driveBytes(capacity):@"—";
    NSString *storage=[NSString stringWithFormat:@"%@ / %@",driveBytes(used)?:@"—",capacityText];
    NSNumber *usageFraction=used&&capacity.doubleValue>0?@(used.doubleValue/capacity.doubleValue):nil;

    NSDictionary *raw=health[@"raw"];
    NSNumber *life=driveNumber(raw,@"SSD_Life_Left"),*wear=driveNumber(health,@"percentage_used");
    if(!life&&wear)life=@(MAX(0,100-wear.doubleValue));
    NSString *lifeText=life?[NSString stringWithFormat:@"%.0f%%",life.doubleValue]:@"—";
    NSColor *usageColor=NSColor.controlAccentColor;
    if(usageFraction.doubleValue>=0.90)usageColor=NSColor.systemRedColor;
    else if(usageFraction.doubleValue>=0.80)usageColor=NSColor.systemYellowColor;
    NSColor *lifeColor=NSColor.controlAccentColor;
    if(life&&life.doubleValue<=10)lifeColor=NSColor.systemRedColor;
    else if(life&&life.doubleValue<=20)lifeColor=NSColor.systemYellowColor;
    [self addProgress:@"已用/总计" value:storage fraction:usageFraction color:usageColor frame:NSMakeRect(metricsX,99,metricsWidth,20)];
    [self addProgress:@"剩余寿命" value:lifeText fraction:life?@(life.doubleValue/100):nil color:lifeColor frame:NSMakeRect(metricsX,76,metricsWidth,20)];

    NSNumber *read=driveNumber(raw,@"Lifetime_Reads_GiB"),*written=driveNumber(raw,@"Lifetime_Writes_GiB");
    const double bytesPerGiB=1073741824.0;
    NSString *readText=driveBytes(read?@(read.doubleValue*bytesPerGiB):driveNumber(health,@"bytes_read"));
    NSString *writtenText=driveBytes(written?@(written.doubleValue*bytesPerGiB):driveNumber(health,@"bytes_written"));
    NSString *transfer=[NSString stringWithFormat:@"%@ / %@",writtenText?:@"—",readText?:@"—"];

    CGFloat columnGap=16;
    CGFloat columnWidth=(metricsWidth-columnGap)/2;
    CGFloat rightColumn=metricsX+columnWidth+columnGap;
    [self addMetric:BBDriveMetric(@"总写入/总读取",transfer,11) frame:NSMakeRect(metricsX,45,metricsWidth,16)];
    if(temperature)
        [self addMetric:BBDriveMetric(@"温度",[NSString stringWithFormat:@"%.0f °C",temperature.doubleValue],10)
                   frame:NSMakeRect(metricsX,26,columnWidth,14)];
    if(healthText)
        [self addMetric:BBDriveMetric(@"SMART",healthText,10) frame:NSMakeRect(rightColumn,26,columnWidth,14)];

    NSNumber *hours=driveNumber(health,@"power_on_hours"),*cycles=driveNumber(health,@"power_cycles");
    if(hours)
        [self addMetric:BBDriveMetric(@"通电时长",[NSString stringWithFormat:@"%@ 小时",hours],10)
                   frame:NSMakeRect(metricsX,7,columnWidth,14)];
    if(cycles)
        [self addMetric:BBDriveMetric(@"通电次数",[NSString stringWithFormat:@"%@ 次",cycles],10)
                   frame:NSMakeRect(rightColumn,7,columnWidth,14)];
    NSNumber *ejectID=driveNumber(drive,@"ejectID");
    if(![drive[@"internal"] boolValue]&&ejectID){
        NSString *action=[drive[@"ejecting"] boolValue]?@"正在弹出…":@"弹出硬盘";
        NSButton *eject=[NSButton buttonWithTitle:@"弹出" target:self action:@selector(eject:)];
        eject.frame=NSMakeRect(width-54,NSMidY(self.bounds)-14,42,28);
        eject.font=[NSFont systemFontOfSize:11];
        eject.accessibilityLabel=action;
        eject.bezelStyle=NSBezelStyleRounded;
        eject.enabled=![drive[@"ejectDisabled"] boolValue];
        self.ejectID=ejectID;
        eject.accessibilityIdentifier=@"DriveEject";
        eject.toolTip=action;
        [self addSubview:eject];
    }
    return self;
}
- (void)addMetric:(NSAttributedString *)text frame:(NSRect)frame {
    NSTextField *label=cardLabel(@"",frame,[NSFont systemFontOfSize:11],NSColor.secondaryLabelColor);
    label.attributedStringValue=text;
    label.toolTip=text.string;
    [self addSubview:label];
}
- (void)addProgress:(NSString *)name value:(NSString *)value fraction:(NSNumber *)fraction color:(NSColor *)color frame:(NSRect)frame {
    NSFont *font=[NSFont systemFontOfSize:11];
    NSFont *valueFont=[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    CGFloat nameWidth=ceil([name sizeWithAttributes:@{NSFontAttributeName:font}].width)+4;
    NSTextField *title=cardLabel(name,NSMakeRect(frame.origin.x,frame.origin.y+6,nameWidth,15),font,NSColor.secondaryLabelColor);
    [self addSubview:title];
    NSTextField *amount=cardLabel(value,NSMakeRect(frame.origin.x+nameWidth+6,frame.origin.y+6,frame.size.width-nameWidth-6,15),valueFont,NSColor.labelColor);
    amount.alignment=NSTextAlignmentRight;
    amount.toolTip=value;
    [self addSubview:amount];

    BBDriveProgress *progress=[[BBDriveProgress alloc]initWithFrame:NSMakeRect(frame.origin.x,frame.origin.y,frame.size.width,4)];
    progress.fillColor=color;
    if(fraction)progress.fraction=@(MIN(1,MAX(0,fraction.doubleValue)));
    [self addSubview:progress];
}
- (void)eject:(NSButton *)sender {
    if(sender.enabled&&self.ejectAction)self.ejectAction(self.ejectID);
}
- (void)drawRect:(NSRect)dirty {
    if(_showsSeparator)BBDrawDeviceSeparator(self.bounds.size.width,0);
}
@end

@implementation BBDeviceRow
- (instancetype)initWithFrame:(NSRect)frame record:(NSDictionary*)r {
    if((self=[super initWithFrame:frame])){
        self.record=[r copy];
        BOOL connected=[r[@"connected"] boolValue];BOOL needsPermission=[r[@"status"] containsString:@"访问被拒绝"];BOOL fresh=[r[@"fresh"] boolValue];NSTimeInterval updated=[r[@"updated"] doubleValue];
        CGFloat w=frame.size.width;
        BOOL supported=[r[@"selectable"] boolValue]&&[r[@"identity"] length]>0;
        NSString*symbol=[r[@"category"] isEqual:@"Keyboard"]?@"keyboard":([r[@"category"] isEqual:@"Mouse"]?@"computermouse":@"cable.connector");
        CGFloat iconSize=40;
        NSImageView*icon=[[NSImageView alloc]initWithFrame:NSMakeRect(16,NSMidY(self.bounds)-iconSize/2,iconSize,iconSize)];icon.imageAlignment=NSImageAlignCenter;icon.autoresizingMask=NSViewMinYMargin|NSViewMaxYMargin;icon.image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:r[@"category"]];icon.symbolConfiguration=[NSImageSymbolConfiguration configurationWithPointSize:28 weight:NSFontWeightRegular];icon.contentTintColor=connected?NSColor.secondaryLabelColor:NSColor.tertiaryLabelColor;[self addSubview:icon];
        NSTextField*name=cardLabel(r[@"name"]?:@"USB 设备",NSMakeRect(72,56,w-368,20),[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],NSColor.labelColor);name.toolTip=r[@"name"];[self addSubview:name];
        NSString*connection=!connected?@"未连接":(needsPermission?@"需要输入监控授权":(fresh?@"已连接":@"接收器在线 · 等待电量"));
        NSColor*stateColor=connected&&needsPermission?NSColor.systemOrangeColor:NSColor.secondaryLabelColor;

        NSString*time=@"尚未读取";if(updated>0){NSString*clock=[NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:updated] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];time=[NSString stringWithFormat:@"%@%@",connected&&fresh?@"更新于 ":@"上次读取 ",clock];}
        NSTextField *status=cardLabel(@"",NSMakeRect(72,35,w-368,17),[NSFont systemFontOfSize:11],stateColor);
        NSMutableAttributedString *statusText=[[NSMutableAttributedString alloc]initWithString:connection attributes:@{NSFontAttributeName:status.font,NSForegroundColorAttributeName:stateColor}];
        [statusText appendAttributedString:[[NSAttributedString alloc]initWithString:[@"  " stringByAppendingString:time] attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:10],NSForegroundColorAttributeName:NSColor.tertiaryLabelColor}]];
        status.attributedStringValue=statusText;status.toolTip=[NSString stringWithFormat:@"%@  %@",connection,time];[self addSubview:status];
        NSString*percent=(connected&&fresh&&r[@"percent"])?[NSString stringWithFormat:@"%@%%",r[@"percent"]]:@"—";
        NSTextField*battery=cardLabel(percent,NSMakeRect(w-286,48,80,26),[NSFont monospacedDigitSystemFontOfSize:20 weight:NSFontWeightRegular],connected?NSColor.labelColor:NSColor.secondaryLabelColor);battery.alignment=NSTextAlignmentRight;[self addSubview:battery];
        NSTextField*charge=cardLabel(BBChargeStatus(r),NSMakeRect(w-306,27,100,16),[NSFont systemFontOfSize:10],connected&&fresh&&[r[@"charging"] boolValue]?NSColor.systemGreenColor:NSColor.secondaryLabelColor);charge.alignment=NSTextAlignmentRight;charge.accessibilityIdentifier=@"DeviceChargingStatus";[self addSubview:charge];
        NSTextField*mapLabel=cardLabel(@"映射",NSMakeRect(w-154,60,64,15),[NSFont systemFontOfSize:10],NSColor.secondaryLabelColor);mapLabel.alignment=NSTextAlignmentCenter;[self addSubview:mapLabel];
        self.mappingSwitch=[[NSSwitch alloc]initWithFrame:NSMakeRect(w-144,29,44,24)];_mappingSwitch.controlSize=NSControlSizeSmall;_mappingSwitch.target=self;_mappingSwitch.action=@selector(mappingChanged:);_mappingSwitch.state=mappingEnabled(r[@"identity"]?:@"")?NSControlStateValueOn:NSControlStateValueOff;_mappingSwitch.enabled=supported;_mappingSwitch.accessibilityLabel=[NSString stringWithFormat:@"%@的电量映射到mac系统",r[@"name"]?:@"设备"];[self addSubview:_mappingSwitch];
        self.refreshButton=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:needsPermission?@"lock.open":@"arrow.clockwise" accessibilityDescription:needsPermission?@"授权读取":@"刷新此设备"] target:self action:@selector(performDeviceAction:)];_refreshButton.frame=NSMakeRect(w-88,33,30,28);_refreshButton.bezelStyle=NSBezelStyleRounded;_refreshButton.enabled=connected&&(supported||needsPermission);_refreshButton.toolTip=needsPermission?@"授权读取此设备电量":@"刷新此设备电量";_refreshButton.accessibilityIdentifier=@"DeviceRefresh";[self addSubview:_refreshButton];
        self.deleteButton=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"trash" accessibilityDescription:@"删除设备"] target:self action:@selector(deleteDeviceRecord:)];
        _deleteButton.frame=NSMakeRect(w-50,33,30,28);
        _deleteButton.bezelStyle=NSBezelStyleRounded;
        _deleteButton.enabled=!connected&&[r[@"identity"] length]>0;
        _deleteButton.toolTip=@"删除设备";
        _deleteButton.accessibilityIdentifier=@"DeviceDelete";
        [self addSubview:_deleteButton];
        self.toolTip=r[@"status"];
    }return self;
}
- (void)performDeviceAction:(id)sender {
    if(!_refreshButton.enabled)return;
    if([_record[@"status"] containsString:@"访问被拒绝"]){[_menuTarget permission:sender];return;}
    NSMenuItem*item=[NSMenuItem new];item.representedObject=_record[@"identity"];
    [_menuTarget refreshDevice:item];
}
- (void)mappingChanged:(NSSwitch*)sender {
    NSMenuItem*item=[NSMenuItem new];item.representedObject=@{@"identity":_record[@"identity"]?:@"",@"enabled":@(sender.state==NSControlStateValueOn)};
    [_menuTarget setDeviceMapping:item];
}
- (void)deleteDeviceRecord:(id)sender {
    if(!_deleteButton.enabled)return;
    NSMenuItem*item=[NSMenuItem new];
    item.representedObject=_record[@"identity"];
    [_menuTarget deleteDevice:item];
}
- (NSMenu*)menuForEvent:(NSEvent*)event {
    NSString*identity=_record[@"identity"];
    id<BBMappingTarget> target=_menuTarget;
    if(!_deleteButton.enabled||!target)return nil;

    NSMenu*menu=[NSMenu new];
    NSMenuItem*item=[menu addItemWithTitle:@"删除设备" action:@selector(deleteDevice:) keyEquivalent:@""];
    item.target=target;
    item.representedObject=identity;
    return menu;
}
- (void)drawRect:(NSRect)dirty {
    if(_showsSeparator) BBDrawDeviceSeparator(self.bounds.size.width,0);
}
@end

// Menu sliders keep the menu open while AppKit tracks the drag. Snapshot
// refreshes may update availability, but must not move a thumb under the mouse.
@interface BBMenuSlider:NSSlider
@property BOOL dragging;
@end
@implementation BBMenuSlider
- (void)mouseDown:(NSEvent*)event {_dragging=YES;@try{[super mouseDown:event];}@finally{_dragging=NO;}}
@end

// Draw the value inside a battery silhouette, keeping text legible at menu size.
@interface BBMenuBatteryLabel:NSTextField
@property(nonatomic) NSNumber *percent;
@end
@implementation BBMenuBatteryLabel
- (void)drawRect:(NSRect)dirty {
    NSRect body=NSMakeRect(1,3,self.bounds.size.width-5,self.bounds.size.height-6);
    [NSColor.secondaryLabelColor setStroke];
    NSBezierPath *outline=[NSBezierPath bezierPathWithRoundedRect:body xRadius:3 yRadius:3];outline.lineWidth=1;[outline stroke];
    [NSColor.secondaryLabelColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMaxX(body)+1,NSMidY(body)-3,2,6) xRadius:1 yRadius:1] fill];
    NSRect interior=NSInsetRect(body,2,2);
    NSRect fill=interior;fill.size.width*=MAX(0,MIN(100,_percent.doubleValue))/100.0;
    NSBezierPath *fillPath=[NSBezierPath bezierPathWithRoundedRect:fill xRadius:1 yRadius:1];
    [NSColor.secondaryLabelColor setFill];if(_percent&&fill.size.width>0)[fillPath fill];
    NSDictionary *attributes=@{NSFontAttributeName:self.font,NSForegroundColorAttributeName:self.textColor};
    NSSize size=[self.stringValue sizeWithAttributes:attributes];
    NSPoint textOrigin=NSMakePoint(NSMidX(body)-size.width/2,NSMidY(body)-size.height/2);
    [self.stringValue drawAtPoint:textOrigin withAttributes:attributes];
    if(_percent&&fill.size.width>0){
        [NSGraphicsContext saveGraphicsState];[fillPath addClip];
        [self.stringValue drawAtPoint:textOrigin withAttributes:@{NSFontAttributeName:self.font,NSForegroundColorAttributeName:NSColor.windowBackgroundColor}];
        [NSGraphicsContext restoreGraphicsState];
    }
}
- (void)setStringValue:(NSString*)value {[super setStringValue:value];self.needsDisplay=YES;}
- (void)setPercent:(NSNumber*)percent {_percent=percent;self.needsDisplay=YES;}
@end

@interface BBStatusDeviceView:NSView
@property NSDictionary *record;
@property(weak) BBDisplayController *controller;
@property NSTextField *nameLabel;
@property NSTextField *stateLabel;
@property NSTextField *batteryLabel;
@property NSArray<BBMenuSlider*> *sliders;
@property NSArray<NSTextField*> *values;
- (instancetype)initWithRecord:(NSDictionary*)record controller:(BBDisplayController*)controller;
- (void)updateRecord:(NSDictionary*)record;
@end
@implementation BBStatusDeviceView
- (BOOL)isFlipped {return YES;}
- (instancetype)initWithRecord:(NSDictionary*)record controller:(BBDisplayController*)controller {
    BOOL display=[record[@"category"] isEqual:@"Display"];
    if((self=[super initWithFrame:NSMakeRect(0,0,432,display?96:40)])){
        _controller=controller;
        NSImageView *icon=[[NSImageView alloc]initWithFrame:NSMakeRect(14,10,20,20)];
        NSString *symbol=display?@"display":([record[@"category"] isEqual:@"Keyboard"]?@"keyboard":([record[@"category"] isEqual:@"Mouse"]?@"computermouse":@"cable.connector"));
        icon.image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:record[@"category"]];icon.contentTintColor=NSColor.secondaryLabelColor;[self addSubview:icon];
        self.nameLabel=cardLabel(@"",NSMakeRect(42,9,288,20),[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],NSColor.labelColor);[self addSubview:_nameLabel];
        self.stateLabel=cardLabel(@"",NSMakeRect(42,31,288,17),[NSFont systemFontOfSize:11],NSColor.secondaryLabelColor);[self addSubview:_stateLabel];
        if(!display){
            _nameLabel.frame=NSMakeRect(42,9,234,20);
            _nameLabel.lineBreakMode=NSLineBreakByTruncatingTail;
            self.batteryLabel=[[BBMenuBatteryLabel alloc]initWithFrame:NSMakeRect(286,9,46,22)];
            _batteryLabel.editable=NO;_batteryLabel.selectable=NO;_batteryLabel.bordered=NO;_batteryLabel.drawsBackground=NO;
            _batteryLabel.font=[NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium];_batteryLabel.textColor=NSColor.labelColor;
            _stateLabel.frame=NSMakeRect(344,11,74,17);_stateLabel.font=[NSFont systemFontOfSize:10];_stateLabel.lineBreakMode=NSLineBreakByTruncatingTail;
            _batteryLabel.alignment=NSTextAlignmentCenter;_batteryLabel.accessibilityIdentifier=@"MenuDeviceBattery";[self addSubview:_batteryLabel];
        }
        NSMutableArray *sliders=[NSMutableArray new],*values=[NSMutableArray new];
        if(display)for(NSUInteger i=0;i<2;i++){
            CGFloat y=37+i*28;NSString *title=i?@"音量":@"亮度";
            [self addSubview:cardLabel(title,NSMakeRect(16,y,34,20),[NSFont systemFontOfSize:11],NSColor.secondaryLabelColor)];
            BBMenuSlider *slider=[[BBMenuSlider alloc]initWithFrame:NSMakeRect(55,y,300,20)];slider.minValue=0;slider.maxValue=100;slider.controlSize=NSControlSizeSmall;slider.continuous=YES;slider.target=self;slider.action=@selector(changeLevel:);slider.tag=i?0x62:0x10;slider.accessibilityIdentifier=i?@"MenuDisplayVolume":@"MenuDisplayBrightness";
            [sliders addObject:slider];[self addSubview:slider];
            NSTextField *value=cardLabel(@"",NSMakeRect(362,y,54,20),[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],NSColor.labelColor);value.alignment=NSTextAlignmentRight;[values addObject:value];[self addSubview:value];
        }
        self.sliders=sliders;self.values=values;[self updateRecord:record];
    }return self;
}
- (void)updateRecord:(NSDictionary*)record {
    self.record=[record copy];BOOL display=[record[@"category"] isEqual:@"Display"],connected=[record[@"connected"] boolValue];
    _nameLabel.stringValue=record[@"name"]?:@"设备";_nameLabel.toolTip=_nameLabel.stringValue;
    if(display){_stateLabel.stringValue=@"";_stateLabel.hidden=YES;}
    else{
        BOOL fresh=connected&&[record[@"fresh"] boolValue]&&record[@"percent"]!=nil;
        _stateLabel.stringValue=fresh?BBChargeStatus(record):([record[@"status"] containsString:@"访问被拒绝"]?@"需要输入监控授权":@"等待电量");
        // Share the display value's right edge, sizing the trailing status to its text.
        CGFloat rightEdge=416;
        CGFloat statusWidth=ceil([_stateLabel.stringValue sizeWithAttributes:@{NSFontAttributeName:_stateLabel.font}].width)+4;
        _stateLabel.frame=NSMakeRect(rightEdge-statusWidth,11,statusWidth,17);
        _stateLabel.alignment=NSTextAlignmentRight;
        _batteryLabel.frame=NSMakeRect(NSMinX(_stateLabel.frame)-12-46,9,46,22);
        NSRect nameFrame=_nameLabel.frame;nameFrame.size.width=NSMinX(_batteryLabel.frame)-12-nameFrame.origin.x;_nameLabel.frame=nameFrame;
        ((BBMenuBatteryLabel*)_batteryLabel).percent=fresh?record[@"percent"]:nil;
        _batteryLabel.stringValue=fresh?[NSString stringWithFormat:@"%@%%",record[@"percent"]]:@"—";
        _batteryLabel.accessibilityLabel=[NSString stringWithFormat:@"%@ 电量 %@",_nameLabel.stringValue,fresh?_batteryLabel.stringValue:@"未知"];
    }
    _stateLabel.toolTip=record[@"status"];self.toolTip=record[@"status"];
    for(NSUInteger i=0;i<_sliders.count;i++){
        BBMenuSlider *slider=_sliders[i];NSString *feature=i?@"volume":@"brightness";
        slider.enabled=BBDisplayControlAvailable(record,(uint8_t)slider.tag);
        slider.accessibilityLabel=[NSString stringWithFormat:@"%@%@",_nameLabel.stringValue,i?@"音量":@"亮度"];
        if(!slider.dragging){slider.doubleValue=[record[feature][@"percent"] doubleValue];_values[i].stringValue=slider.enabled?[NSString stringWithFormat:@"%.0f%%",slider.doubleValue]:@"不可用";}
        if(!slider.enabled)_values[i].stringValue=@"不可用";
        slider.toolTip=slider.enabled?slider.accessibilityLabel:(record[[feature stringByAppendingString:@"Error"]]?:record[@"status"]?:@"此控制不可用");
    }
}
- (void)changeLevel:(BBMenuSlider*)sender {
    uint8_t code=(uint8_t)sender.tag;
    if(!sender.enabled||!BBDisplayControlAvailable(_record,code)||!_controller)return;
    _values[code==0x62?1:0].stringValue=[NSString stringWithFormat:@"%.0f%%",sender.doubleValue];
    [_controller setPercent:sender.doubleValue code:code identity:_record[@"identity"]];
}
- (NSMenu*)menuForEvent:(NSEvent*)event {return nil;}
@end

@interface BBApp:NSObject<NSApplicationDelegate,NSMenuDelegate,NSWindowDelegate,BBMappingTarget>
@property BBEngine*engine;
@property DBNativeAudioSetup*nativeAudio;
@property BBDisplayController*displays;
@property DBUSBSmart*usbSmart;
@property NSWindow*window;
@property NSScrollView*devicesScroll;
@property BBFlippedView*devicesView;
@property BBFlippedView*displayGroup;
@property BBFlippedView*wirelessGroup;
@property BBFlippedView*settingsGroup;
@property NSTextField*displayHeading;
@property NSTextField*wirelessHeading;
@property NSTextField*generalHeading;
@property BBFlippedView*smartGroup;
@property NSTextField*smartHeading;
@property NSTimeInterval disksRefreshedAt;
@property NSButton*authorizeButton;
@property NSString*devicesSignature;
@property NSTextField*heading;
@property NSPopUpButton*intervalPicker;
@property NSSwitch*autoStartSwitch;
@property NSThread*thread;
@property NSTimer*timer;
@property int lockFD;
@property NSStatusItem*statusItem;
@property NSMenu*statusMenu;
@property BOOL handoffPending;
@property BOOL terminationPending;
@property BOOL terminationReady;
@property BOOL terminationReplyPending;
@end
static NSButton*button(NSString*title,id target,SEL action,NSRect frame){NSButton*b=[NSButton buttonWithTitle:title target:target action:action];b.frame=frame;return b;}
@implementation BBApp
- (BOOL)installIfNeeded {
    if(BBTestingUI)return YES;
    NSString*current=NSBundle.mainBundle.bundlePath;
    NSString*dest=InstallPath,*apps=dest.stringByDeletingLastPathComponent;
    if([current.stringByResolvingSymlinksInPath isEqual:dest.stringByResolvingSymlinksInPath])return YES;
    NSAlert*a=[NSAlert new];a.messageText=@"安装 DeviceBridge";a.informativeText=@"将安装到 /Applications（应用程序），保留设备映射、上报周期和自启选择。旧版用户目录中的副本会在新应用启动后移入不参与搜索的历史归档。\n\n本工具提供 USB 2.4G 键鼠电量桥接与外接显示器 DDC 亮度、音量控制。首次读取可能需要输入监控授权。";[a addButtonWithTitle:@"安装并启用"];[a addButtonWithTitle:@"取消"];
    [NSApp activateIgnoringOtherApps:YES];if([a runModal]!=NSAlertFirstButtonReturn)return NO;
    NSFileManager*fm=NSFileManager.defaultManager;NSError*e=nil;
    if(![fm isWritableFileAtPath:apps]){
        NSAlert*permission=[NSAlert new];permission.messageText=@"请通过访达安装到应用程序";permission.informativeText=@"此 Mac 的 /Applications 需要管理员授权。请将 DMG 内的 DeviceBridge.app 拖入“应用程序”快捷方式，由访达显示系统授权提示；完成后从“应用程序”打开。";[permission addButtonWithTitle:@"在访达中显示"];[permission runModal];[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[NSBundle.mainBundle.bundleURL]];return NO;
    }
    NSString*transaction=[apps stringByAppendingPathComponent:[NSString stringWithFormat:@".DeviceBridge-install-%@.noindex",NSUUID.UUID.UUIDString]];
    if(![fm createDirectoryAtPath:transaction withIntermediateDirectories:NO attributes:nil error:&e]){[self showError:e];return NO;}
    NSString*staging=[transaction stringByAppendingPathComponent:@"Payload.app"];
    if(![fm copyItemAtPath:current toPath:staging error:&e]){[fm removeItemAtPath:transaction error:nil];[self showError:e];return NO;}
    NSString*backup=nil;
    if([fm fileExistsAtPath:dest]){
        if(![[NSBundle bundleWithPath:dest].bundleIdentifier isEqual:BundleID]){[fm removeItemAtPath:transaction error:nil];[self showError:[NSError errorWithDomain:@"DeviceBridge" code:1 userInfo:@{NSLocalizedDescriptionKey:@"目标位置存在其他应用，已停止安装。"}]];return NO;}
    }
    // Also stop a legacy ~/Applications instance when /Applications is empty.
    for(NSRunningApplication*r in [NSRunningApplication runningApplicationsWithBundleIdentifier:BundleID]){
            if(r.processIdentifier==NSProcessInfo.processInfo.processIdentifier)continue;
            [r terminate];NSDate*deadline=[NSDate dateWithTimeIntervalSinceNow:30];
            while(!r.terminated&&deadline.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            if(!r.terminated){[fm removeItemAtPath:transaction error:nil];[self showError:[NSError errorWithDomain:@"DeviceBridge" code:2 userInfo:@{NSLocalizedDescriptionKey:@"旧版本尚未退出，请退出旧版本后重试安装。"}]];return NO;}
    }
    if([fm fileExistsAtPath:dest]){
        backup=[transaction stringByAppendingPathComponent:@"Previous.backup"];
        if(![fm moveItemAtPath:dest toPath:backup error:&e]){[fm removeItemAtPath:transaction error:nil];[self showError:e];return NO;}
    }
    if(![fm moveItemAtPath:staging toPath:dest error:&e]){BOOL restored=!backup||[fm moveItemAtPath:backup toPath:dest error:nil];if(restored)[fm removeItemAtPath:transaction error:nil];[self showError:e];return NO;}
    self.handoffPending=YES;
    NSWorkspaceOpenConfiguration*config=NSWorkspaceOpenConfiguration.configuration;config.createsNewApplicationInstance=YES;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:dest] configuration:config completionHandler:^(NSRunningApplication*running,NSError*error){
        dispatch_async(dispatch_get_main_queue(),^{
            if(error){
                // Keep a recoverable backup if rollback itself fails.
                if(backup&&[fm removeItemAtPath:dest error:nil]&&[fm moveItemAtPath:backup toPath:dest error:nil])[fm removeItemAtPath:transaction error:nil];
                else if(!backup)[fm removeItemAtPath:transaction error:nil];
                [self showError:error];
            }else [fm removeItemAtPath:transaction error:nil];
            [NSApp terminate:nil];
        });
    }];return NO;
}
- (void)migrateLegacyInstallation {
    if(BBTestingUI)return;
    for(NSString *legacy in @[@"/Applications/BatteryBridge.app",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/BatteryBridge.app"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/DeviceBridge.app"]]){
        [self archiveLegacyInstallation:legacy];
    }
}
- (void)archiveLegacyInstallation:(NSString*)legacy {
    NSFileManager*fm=NSFileManager.defaultManager;
    if(![fm fileExistsAtPath:legacy]||![[NSBundle bundleWithPath:legacy].bundleIdentifier isEqual:BundleID])return;
    for(NSRunningApplication*r in [NSRunningApplication runningApplicationsWithBundleIdentifier:BundleID]){
        if(r.processIdentifier==NSProcessInfo.processInfo.processIdentifier||![r.bundleURL.path isEqual:legacy])continue;
        [r terminate];NSDate*deadline=[NSDate dateWithTimeIntervalSinceNow:30];
        while(!r.terminated&&deadline.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        if(!r.terminated)return;
    }
    // Re-register from the canonical bundle after retiring the old login path.
    SMAppService*service=SMAppService.mainAppService;NSError*error=nil;
    if(service.status!=SMAppServiceStatusNotRegistered&&![service unregisterAndReturnError:&error]){[self showError:error];return;}
    NSString*history=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/BatteryBridge/History.noindex"];
    NSString*archived=[history stringByAppendingPathComponent:[NSString stringWithFormat:@"Legacy-%@.backup",NSUUID.UUID.UUIDString]];
    if(![fm createDirectoryAtPath:history withIntermediateDirectories:YES attributes:nil error:&error]||![fm moveItemAtPath:legacy toPath:archived error:&error])[self showError:error];
}
- (void)showError:(NSError*)e {NSAlert*a=[NSAlert new];a.messageText=@"操作未完成";a.informativeText=e.localizedDescription?:@"未知错误";[a runModal];}
- (void)applicationDidFinishLaunching:(NSNotification*)n {
    self.lockFD=-1;
    if(![self installIfNeeded]){if(!self.handoffPending)[NSApp terminate:nil];return;}
    [BBPreferences() registerDefaults:@{@"ReportInterval":@3600,@"AutoStartEnabled":@YES}];
    [self migrateLegacyInstallation];
    if(!BBTestingUI){
    NSString*support=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/BatteryBridge"];
    NSError*folderError=nil;if(![NSFileManager.defaultManager createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:&folderError]){[self showError:folderError];[NSApp terminate:nil];return;}
    _lockFD=open([[support stringByAppendingPathComponent:@"agent.lock"] fileSystemRepresentation],O_CREAT|O_RDWR,0600);
    if(_lockFD<0){[self showError:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]];[NSApp terminate:nil];return;}
    if(flock(_lockFD,LOCK_EX|LOCK_NB)!=0){
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"local.batterybridge.showSettings" object:BundleID userInfo:nil deliverImmediately:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{[NSApp terminate:nil];});return;
    }
    }
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(reopenNotification:) name:@"local.batterybridge.showSettings" object:BundleID];
    [self createStatusItem];
    self.engine=[BBEngine new];self.thread=[[NSThread alloc]initWithTarget:_engine selector:@selector(run) object:nil];self.thread.name=@"DeviceBridge HID";[_thread start];
    if(!BBTestingUI){
        self.displays=[BBDisplayController new];[_displays start];
        self.usbSmart=[DBUSBSmart new];
        __weak BBApp *weak=self;
        _usbSmart.changed=^{[weak refresh];};
        _usbSmart.enabled=YES;
        [_usbSmart refreshInventory];
    }
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(wake:) name:NSWorkspaceDidWakeNotification object:nil];
    if(!BBTestingUI&&[BBPreferences() boolForKey:@"AutoStartEnabled"]&&SMAppService.mainAppService.status==SMAppServiceStatusNotRegistered){NSError*e=nil;[SMAppService.mainAppService registerAndReturnError:&e];}
    self.timer=[NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    if(BBTestingUI||![BBPreferences() boolForKey:@"hasLaunched"]){[BBPreferences() setBool:YES forKey:@"hasLaunched"];[self showWindow];}
    if(!BBTestingUI){self.nativeAudio=[DBNativeAudioSetup new];__weak BBApp *weak=self;
        self.displays.volumeBridgesChanged=^(NSArray *rows,BOOL userInitiated){[weak.nativeAudio updateDisplayBridges:rows userInitiated:userInitiated];};
        [self.nativeAudio updateDisplayBridges:self.displays.snapshot userInitiated:NO];
        dispatch_async(dispatch_get_main_queue(),^{
            [self offerUSBSmartSetup];
            [self.displays beginMediaKeyOnboarding];[self.nativeAudio beginOnboarding];
        });}
}
- (void)createStatusItem {
    self.statusItem=[NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSImage*icon=BBStatusIcon();
    icon.template=YES;icon.size=NSMakeSize(19,19);_statusItem.button.image=icon;_statusItem.button.toolTip=[BBApplicationTitle() stringByAppendingString:@" · 设备状态与显示器控制"];
    self.statusMenu=[[NSMenu alloc]initWithTitle:@"DeviceBridge"];_statusMenu.delegate=self;_statusMenu.autoenablesItems=NO;_statusItem.menu=_statusMenu;
}
- (void)createMainMenu {
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *applicationItem = [mainMenu addItemWithTitle:@"DeviceBridge" action:NULL keyEquivalent:@""];
    applicationItem.submenu = [[NSMenu alloc] initWithTitle:@"DeviceBridge"];
    NSMenuItem *quit = [applicationItem.submenu addItemWithTitle:@"退出 DeviceBridge" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;

    NSMenuItem *fileItem = [mainMenu addItemWithTitle:@"文件" action:NULL keyEquivalent:@""];
    fileItem.submenu = [[NSMenu alloc] initWithTitle:@"文件"];
    NSMenuItem *close = [fileItem.submenu addItemWithTitle:@"关闭窗口" action:@selector(performClose:) keyEquivalent:@"w"];
    close.target = _window;
    NSApp.mainMenu = mainMenu;
}
- (NSMenuItem*)menuItem:(NSString*)title action:(SEL)action value:(id)value {
    NSMenuItem*i=[[NSMenuItem alloc]initWithTitle:title action:action keyEquivalent:@""];i.target=self;i.representedObject=value;i.enabled=action!=NULL;return i;
}
- (void)menuNeedsUpdate:(NSMenu*)menu {
    if(menu!=_statusMenu)return;[menu removeAllItems];
    [menu addItem:[self menuItem:@"显示主界面" action:@selector(showSettings:) value:nil]];
    if(_usbSmart.available&&!_usbSmart.serviceReady&&!_usbSmart.busy)
        [menu addItem:[self menuItem:@"授权外置硬盘 SMART…" action:@selector(enableUSBSmart) value:nil]];
    NSMenuItem*quit=[self menuItem:@"退出程序" action:@selector(quit:) value:nil];quit.keyEquivalent=@"q";[menu addItem:quit];
}
- (void)toggleMapping:(NSMenuItem*)sender {
    NSString*identity=sender.representedObject;if(!identity)return;NSMutableDictionary*choices=[[BBPreferences() dictionaryForKey:@"MappedDevices"] mutableCopy]?:[NSMutableDictionary new];choices[identity]=@(![choices[identity] boolValue]);[BBPreferences() setObject:choices forKey:@"MappedDevices"];[_engine settingsChanged];
}
- (void)setDeviceMapping:(NSMenuItem*)sender {
    NSDictionary*value=sender.representedObject;NSString*identity=value[@"identity"];if(!identity.length)return;
    NSMutableDictionary*choices=[[BBPreferences() dictionaryForKey:@"MappedDevices"] mutableCopy]?:[NSMutableDictionary new];choices[identity]=@([value[@"enabled"] boolValue]);[BBPreferences() setObject:choices forKey:@"MappedDevices"];[_engine settingsChanged];_devicesSignature=nil;[self refresh];
}
- (void)refreshDevice:(NSMenuItem*)sender {NSString*identity=sender.representedObject;[_engine refreshIdentity:identity];}
- (void)openOfficialDriver:(NSMenuItem*)sender {
    NSString*physical=[sender.representedObject objectForKey:@"physical"];NSString*url=[physical hasPrefix:@"046d:"]?@"https://ghub.logitechg.com.cn/":([physical hasPrefix:@"3837:"]?@"https://www.mchose.com.cn/":([physical hasPrefix:@"a8a5:2255:"]?@"https://xunshe.yjx2012.com/?productName=USB%20Receiver":nil));
    if(url&&!BBTestingUI)[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]];
}
- (void)showDeviceInfo:(NSMenuItem*)sender {
    NSDictionary*r=sender.representedObject;NSAlert*a=[NSAlert new];a.messageText=r[@"name"]?:@"设备信息";
    NSString*updated=r[@"updated"]?[NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[r[@"updated"] doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle]:@"尚未读取";
    a.informativeText=[NSString stringWithFormat:@"类型：%@\n连接：%@\n电量：%@\n充电状态：%@\n更新：%@\n系统映射：%@\n\n%@",[r[@"category"] isEqual:@"Keyboard"]?@"键盘":([r[@"category"] isEqual:@"Mouse"]?@"鼠标":@"USB 设备"),[r[@"connected"] boolValue]?@"接收器在线":@"未连接",r[@"percent"]?[NSString stringWithFormat:@"%@%%%@",r[@"percent"],[r[@"fresh"] boolValue]?@"":@"（上次读数）"]:@"未获取",BBChargeStatus(r),updated,mappingEnabled(r[@"identity"]?:@"")?@"开启":@"关闭",r[@"status"]?:@""];
    [NSApp activateIgnoringOtherApps:YES];[a runModal];
}
- (void)deleteDevice:(NSMenuItem*)sender {
    if (!_window || _window.attachedSheet) return;
    NSString *identity = sender.representedObject;
    for (NSDictionary *record in [_engine status]) {
        if (![record[@"identity"] isEqual:identity] || [record[@"connected"] boolValue]) continue;
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = [NSString stringWithFormat:@"删除「%@」？", record[@"name"] ?: @"设备"];
        alert.informativeText = @"此设备的记录和电量映射设置将从 DeviceBridge 中移除。";
        [alert addButtonWithTitle:@"取消"].keyEquivalent = @"\r";
        NSButton *deleteButton = [alert addButtonWithTitle:@"删除"];
        deleteButton.hasDestructiveAction = YES;
        [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
            if (response == NSAlertSecondButtonReturn) [self.engine forgetIdentity:identity];
        }];
        return;
    }
}
- (void)pickInterval:(NSPopUpButton*)sender {[self changeInterval:sender.selectedItem];}
- (void)changeInterval:(NSMenuItem*)sender {[BBPreferences() setObject:@(BBInterval(sender.representedObject)) forKey:@"ReportInterval"];[_engine kick];[self refresh];}
- (void)toggleAutoStart:(NSSwitch*)sender {NSMenuItem*item=[NSMenuItem new];item.representedObject=@(sender.state==NSControlStateValueOn);[self setAutoStart:item];}
- (void)setAutoStart:(NSMenuItem*)sender {
    BOOL requested=[sender.representedObject boolValue];
    if(BBTestingUI){[BBPreferences() setBool:requested forKey:@"AutoStartEnabled"];[self refresh];return;}
    SMAppService*service=SMAppService.mainAppService;BOOL currently=service.status==SMAppServiceStatusEnabled||service.status==SMAppServiceStatusRequiresApproval;
    if(requested==currently){[BBPreferences() setBool:requested forKey:@"AutoStartEnabled"];[self refresh];return;}NSError*e=nil;
    BOOL ok=requested?[service registerAndReturnError:&e]:[service unregisterAndReturnError:&e];
    if(!ok){[self refresh];[self showError:e];return;}[BBPreferences() setBool:requested forKey:@"AutoStartEnabled"];[self refresh];
}
- (void)showSettings:(id)sender {[self showWindow];}
- (void)quit:(id)sender {
    if(_usbSmart.busy){[self showWindow];return;}
    if(BBTestingUI||!_displays){[NSApp terminate:sender];return;}
    [self prepareToQuit];
}
- (void)reopenNotification:(NSNotification*)n {[self showWindow];}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {return NO;}

- (void)wake:(NSNotification*)n {[_engine kick];[_usbSmart refreshInventory];}
- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)visible {[self showWindow];return YES;}
- (void)buildWindow {
    if(_window)return;
    self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,720,700) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    _window.releasedWhenClosed=NO;_window.title=BBApplicationTitle();_window.backgroundColor=NSColor.windowBackgroundColor;[_window center];_window.contentMinSize=NSMakeSize(560,420);_window.delegate=self;
    [self createMainMenu];
    NSView *content=_window.contentView;
    self.devicesScroll=[[NSScrollView alloc]initWithFrame:content.bounds];_devicesScroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;_devicesScroll.hasHorizontalScroller=NO;_devicesScroll.hasVerticalScroller=YES;_devicesScroll.autohidesScrollers=NO;_devicesScroll.drawsBackground=NO;_devicesScroll.borderType=NSNoBorder;
    self.devicesView=[[BBFlippedView alloc]initWithFrame:content.bounds];_devicesScroll.documentView=_devicesView;[content addSubview:_devicesScroll];
    NSTextField *title=cardLabel(@"设备列表",NSMakeRect(24,24,200,30),[NSFont systemFontOfSize:22 weight:NSFontWeightSemibold],NSColor.labelColor);title.accessibilityIdentifier=@"DeviceListTitle";[_devicesView addSubview:title];
    NSButton *refresh=button(@"刷新全部",self,@selector(rescan:),NSMakeRect(594,24,102,32));refresh.image=[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"刷新全部设备"];refresh.imagePosition=NSImageLeading;refresh.bezelStyle=NSBezelStyleRounded;refresh.autoresizingMask=NSViewMinXMargin;[_devicesView addSubview:refresh];
    self.authorizeButton=button(@"授权读取…",self,@selector(permission:),NSMakeRect(584,64,112,28));_authorizeButton.hidden=YES;_authorizeButton.autoresizingMask=NSViewMinXMargin;[_devicesView addSubview:_authorizeButton];
    self.displayHeading=cardLabel(@"显示器",NSZeroRect,[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],NSColor.labelColor);
    self.wirelessHeading=cardLabel(@"2.4G 设备",NSZeroRect,[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],NSColor.labelColor);
    self.generalHeading=cardLabel(@"通用",NSZeroRect,[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],NSColor.labelColor);
    for(NSTextField *heading in @[_displayHeading,_wirelessHeading,_generalHeading])[_devicesView addSubview:heading];
    self.displayGroup=[[BBFlippedView alloc]initWithFrame:NSZeroRect];self.wirelessGroup=[[BBFlippedView alloc]initWithFrame:NSZeroRect];
    [_devicesView addSubview:_displayGroup];[_devicesView addSubview:_wirelessGroup];
    self.settingsGroup=[[BBFlippedView alloc]initWithFrame:NSMakeRect(24,0,672,116)];_settingsGroup.groupHeight=116;_settingsGroup.settingsGroup=YES;[_devicesView addSubview:_settingsGroup];
    self.heading=cardLabel(@"自动更新",NSMakeRect(16,18,200,20),[NSFont systemFontOfSize:13],NSColor.labelColor);[_settingsGroup addSubview:_heading];
    self.intervalPicker=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(520,15,136,26) pullsDown:NO];_intervalPicker.target=self;_intervalPicker.action=@selector(pickInterval:);_intervalPicker.autoresizingMask=NSViewMinXMargin;_intervalPicker.accessibilityLabel=@"自动更新周期";
    for(NSNumber *n in @[@300,@1800,@3600,@7200,@10800]){[_intervalPicker addItemWithTitle:[@"每" stringByAppendingString:BBIntervalLabel(n.doubleValue)]];_intervalPicker.lastItem.representedObject=n;}[_settingsGroup addSubview:_intervalPicker];
    [_settingsGroup addSubview:cardLabel(@"登录时启动",NSMakeRect(16,75,220,20),[NSFont systemFontOfSize:13],NSColor.labelColor)];
    self.autoStartSwitch=[[NSSwitch alloc]initWithFrame:NSMakeRect(612,73,44,24)];_autoStartSwitch.target=self;_autoStartSwitch.action=@selector(toggleAutoStart:);_autoStartSwitch.controlSize=NSControlSizeSmall;_autoStartSwitch.accessibilityLabel=@"登录时启动";_autoStartSwitch.autoresizingMask=NSViewMinXMargin;[_settingsGroup addSubview:_autoStartSwitch];
    if(_usbSmart.available){
        self.smartHeading=cardLabel(@"硬盘",NSZeroRect,[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],NSColor.labelColor);
        [_devicesView addSubview:_smartHeading];
        self.smartGroup=[[BBFlippedView alloc]initWithFrame:NSZeroRect];
        [_devicesView addSubview:_smartGroup];
    }
    if(!BBTestingUI){[_window setFrameAutosaveName:@"DeviceListWindow"];[_window setFrameUsingName:@"DeviceListWindow"];}
}
- (void)windowWillClose:(NSNotification*)notification {
    if(notification.object==_window)[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}
- (void)applicationDidBecomeActive:(NSNotification*)notification {[_displays refreshMediaKeyAuthorization];[self refresh];}
- (void)windowDidResize:(NSNotification*)notification {if(!_devicesScroll)return;_devicesSignature=nil;[self refresh];}
- (void)showWindow {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self buildWindow];
    [_window makeKeyAndOrderFront:nil];[self refresh];[NSApp activateIgnoringOtherApps:YES];
}
- (void)refresh {
    NSTimeInterval interval=BBInterval([BBPreferences() objectForKey:@"ReportInterval"]);
    _statusItem.button.toolTip=[NSString stringWithFormat:@"%@ · 设备状态与显示器控制 · 每%@上报",BBApplicationTitle(),BBIntervalLabel(interval)];if(!_window)return;
    NSArray*rows=[[_engine status] arrayByAddingObjectsFromArray:_displays.snapshot?:@[]];_heading.stringValue=@"自动更新";
    for(NSMenuItem*i in _intervalPicker.itemArray)if([i.representedObject doubleValue]==interval){[_intervalPicker selectItem:i];break;}
    _autoStartSwitch.state=[BBPreferences() boolForKey:@"AutoStartEnabled"]?NSControlStateValueOn:NSControlStateValueOff;
    _autoStartSwitch.toolTip=(!BBTestingUI&&SMAppService.mainAppService.status==SMAppServiceStatusRequiresApproval)?@"请在系统设置的登录项中批准自动启动":@"登录 macOS 时自动启动";
    [_displays refreshMediaKeyAuthorization];
    BOOL denied=NO;for(NSDictionary*r in rows)denied=denied||([r[@"connected"] boolValue]&&[r[@"status"] containsString:@"访问被拒绝"]);
    _authorizeButton.hidden=!denied;_authorizeButton.title=@"授权读取…";_authorizeButton.action=@selector(permission:);
    _authorizeButton.toolTip=@"授权读取设备电量";
    for(NSView *view in _displayGroup.subviews){
        if ([view isKindOfClass:BBDisplayRow.class]) {
            BBDisplayRow *row = (BBDisplayRow *)view;
            if (row.isTrackingBrightness || row.isEditingPercent) return;
        }
    }
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    if(now-_disksRefreshedAt>=interval){_disksRefreshedAt=now;[_usbSmart refreshInventory];}
    NSArray *driveRows=_usbSmart.drives?:@[];
    NSString*signature=[NSString stringWithFormat:@"%@:%@:%ld",rows,driveRows,(long)(now/120)];if([signature isEqual:_devicesSignature])return;_devicesSignature=signature;
    NSPoint origin=_devicesScroll.contentView.bounds.origin;
    _devicesScroll.autohidesScrollers=NO;[_devicesScroll tile];
    CGFloat documentWidth=MAX(1,_devicesScroll.contentSize.width),width=MAX(1,documentWidth-48),y=100;
    NSArray *displayRows=_displays.snapshot?:@[],*wirelessRows=[_engine status]?:@[];
    NSArray *groups=@[_displayGroup,_wirelessGroup],*headings=@[_displayHeading,_wirelessHeading],*sections=@[displayRows,wirelessRows];
    for(NSUInteger section=0;section<sections.count;section++){
        BBFlippedView *group=groups[section];NSTextField *heading=headings[section];NSArray *items=sections[section];
        heading.frame=NSMakeRect(26,y,MAX(1,width-4),20);y+=32;
        CGFloat groupHeight=items.count?items.count*96:64;
        group.frame=NSMakeRect(24,y,width,groupHeight);group.groupHeight=groupHeight;
        for(NSView *view in group.subviews.copy)[view removeFromSuperview];
        if(!items.count)[group addSubview:cardLabel(section?@"未发现 2.4G 设备":@"暂无显示器",NSMakeRect(16,22,MAX(1,width-32),20),[NSFont systemFontOfSize:12],NSColor.secondaryLabelColor)];
        for(NSUInteger i=0;i<items.count;i++){
            NSRect frame=NSMakeRect(0,i*96,width,96);
            if(section==0){BBDisplayRow *row=[[BBDisplayRow alloc]initWithFrame:frame record:items[i]];row.controller=_displays;row.showsSeparator=i+1<items.count;[group addSubview:row];}
            else{BBDeviceRow *row=[[BBDeviceRow alloc]initWithFrame:frame record:items[i]];row.menuTarget=self;row.showsSeparator=i+1<items.count;[group addSubview:row];}
        }
        [group setNeedsDisplay:YES];y+=groupHeight+28;
    }
    if(_smartGroup){
        _smartHeading.frame=NSMakeRect(26,y,MAX(1,width-4),20);y+=32;
        CGFloat height=driveRows.count?driveRows.count*BBDriveRowHeight:64;
        _smartGroup.frame=NSMakeRect(24,y,width,height);_smartGroup.groupHeight=height;
        for(NSView *view in _smartGroup.subviews.copy)[view removeFromSuperview];
        if(!driveRows.count)[_smartGroup addSubview:cardLabel(@"未发现硬盘",NSMakeRect(16,22,MAX(1,width-32),20),[NSFont systemFontOfSize:12],NSColor.secondaryLabelColor)];
        for(NSUInteger i=0;i<driveRows.count;i++){
            BBDriveRow *row=[[BBDriveRow alloc]initWithFrame:NSMakeRect(0,i*BBDriveRowHeight,width,BBDriveRowHeight) record:driveRows[i]];
            row.showsSeparator=i+1<driveRows.count;
            __weak BBApp *weak=self;
            row.ejectAction=^(NSNumber *mediaID){
                [weak.usbSmart ejectDrive:mediaID completion:^(NSError *error){if(error)[weak showError:error];}];
            };
            [_smartGroup addSubview:row];
        }
        [_smartGroup setNeedsDisplay:YES];y+=height+28;
    }
    _generalHeading.frame=NSMakeRect(26,y,MAX(1,width-4),20);y+=32;
    _settingsGroup.frame=NSMakeRect(24,y,width,116);y+=140;
    _devicesView.frame=NSMakeRect(0,0,documentWidth,MAX(y,_devicesScroll.contentSize.height));
    origin.x=0;origin.y=MAX(0,MIN(origin.y,_devicesView.bounds.size.height-_devicesScroll.contentSize.height));
    [_devicesScroll.contentView scrollToPoint:origin];[_devicesScroll reflectScrolledClipView:_devicesScroll.contentView];
}

- (void)enableUSBSmart {
    __weak BBApp *weak=self;
    [_usbSmart prepareService:^(BOOL ready){[weak refresh];}];
}
- (void)offerUSBSmartSetup {
    if(!_usbSmart.available||_usbSmart.serviceReady||[BBPreferences() boolForKey:@"USBSmartSetupOffered"])return;
    [BBPreferences() setBool:YES forKey:@"USBSmartSetupOffered"];
    NSAlert *alert=[NSAlert new];
    alert.messageText=@"启用外置硬盘 SMART";
    alert.informativeText=@"安装后台读取组件需要一次管理员授权。之后插入兼容的 SSK 硬盘盒，可在首次挂载前自动采集 SMART。也可稍后从菜单栏授权。";
    [alert addButtonWithTitle:@"启用…"];
    [alert addButtonWithTitle:@"稍后"];
    [NSApp activateIgnoringOtherApps:YES];
    if([alert runModal]==NSAlertFirstButtonReturn)[self enableUSBSmart];
}
- (void)permission:(id)sender {
    // Request only when the user invokes the authorization action.
    // The OS owns the consent decision; opening Settings does not imply a grant.
    if(!BBTestingUI&&IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)){[_engine kick];[self refresh];return;}
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}
- (void)rescan:(id)sender {[_engine kick];[_displays refreshControls];[_usbSmart refreshInventory];}
- (void)login:(id)sender {if(!BBTestingUI)[SMAppService openSystemSettingsLoginItems];}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
    if(_usbSmart.busy)return NSTerminateCancel;
    if(BBTestingUI||!_displays||_terminationReady)return NSTerminateNow;
    _terminationReplyPending=YES;
    [self prepareToQuit];
    return NSTerminateLater;
}
- (void)prepareToQuit {
    if(_terminationPending)return;
    _terminationPending=YES;
    // A menu quit can finish asynchronous cleanup on the normal event loop
    // before asking AppKit to terminate.
    [_displays prepareForTermination:^(BOOL displayRestored){
        void (^finish)(BOOL)=^(BOOL audioRestored){
            BOOL restored=displayRestored&&audioRestored;
            BOOL replyPending=self.terminationReplyPending;
            self.terminationReplyPending=NO;
            self.terminationPending=NO;
            self.terminationReady=restored;
            if(replyPending)[NSApp replyToApplicationShouldTerminate:restored];
            else if(restored)[NSApp terminate:nil];
            if(!restored){
                NSAlert *alert=[NSAlert new];alert.messageText=@"退出恢复尚未完成";
                alert.informativeText=audioRestored?@"屏幕识别信息未确认恢复，已暂缓退出，请检查显示器连接后重试。":@"音频输出恢复或代理撤下未完成，已暂缓退出，避免留下无效声音输出。请检查声音输出后重试。";
                [NSApp activateIgnoringOtherApps:YES];[alert runModal];
            }
        };
        if(self.nativeAudio)[self.nativeAudio prepareForTermination:finish];
        else finish(YES);
    }];
}
- (void)applicationWillTerminate:(NSNotification*)n {
    self.usbSmart=nil;[_nativeAudio stop];[_displays stop];_engine.stopping=YES;[_timer invalidate];if(_lockFD>=0)close(_lockFD);
}
@end

int main(int argc,const char*argv[]){@autoreleasepool{
    NSArray*args=NSProcessInfo.processInfo.arguments;
    if([args containsObject:@"--version"]){puts(Version.UTF8String);return 0;}
    if([args containsObject:@"--diagnose-permissions"]){
        NSDictionary *report=@{@"version":Version,@"bundlePath":NSBundle.mainBundle.bundlePath,@"bundleIdentifier":NSBundle.mainBundle.bundleIdentifier?:@"",@"accessibilityTrusted":@(AXIsProcessTrusted()),@"deviceControlAccess":@(IOHIDCheckAccess(kIOHIDRequestTypePostEvent)),@"inputMonitoringAccess":@(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))};
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);return 0;
    }
    if([args containsObject:@"--diagnose-displays"]){
        BBDisplayController*d=[BBDisplayController new];[d startReadOnly];
        NSDate*deadline=[NSDate dateWithTimeIntervalSinceNow:12];
        while(!d.discoveryFinished&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
        NSData*data=[NSJSONSerialization dataWithJSONObject:d.snapshot options:NSJSONWritingPrettyPrinted error:nil];puts([[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding].UTF8String);[d stop];return 0;
    }
    if([args containsObject:@"--diagnose"]){
        BBTestingUI=YES;
        printf("DeviceBridge %s\nHID access: %d (0=granted, 1=denied, 2=unknown)\n",Version.UTF8String,IOHIDCheckAccess(kIOHIDRequestTypeListenEvent));
        BBEngine*engine=[BBEngine new];engine.diagnostic=YES;[engine scan];return 0;
    }
    if([args containsObject:@"--publisher-test"]){
        BBSource*s=[BBSource new];BOOL ok=[s publish:@"local.batterybridge.temporary-test" name:@"DeviceBridge Temporary Test" category:@"Keyboard" reading:@{@"percent":@50,@"charging":@NO,@"full":@NO}];printf("Temporary accessory publish: %s\n",ok?"PASS":"FAIL");return ok?0:1;
    }
    BBTestingUI=[NSBundle.mainBundle.infoDictionary[@"BBPreviewMode"] boolValue];
    NSApplication*app=NSApplication.sharedApplication;app.activationPolicy=NSApplicationActivationPolicyAccessory;
    static BBApp*delegate;delegate=[BBApp new];app.delegate=delegate;[app run];return 0;
}}
