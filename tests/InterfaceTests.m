// Offscreen AppKit checks. Uses in-memory preferences and never installs or registers login items.
#define main BBApplicationMain
#import "../Sources/main.m"
#undef main
static void ensure(BOOL ok,const char*message){if(!ok){fprintf(stderr,"FAIL: %s\n",message);exit(1);}}
@interface BBShortcutTestApp : BBApp
@property BOOL quitRequested;
@end
@implementation BBShortcutTestApp
- (void)quit:(id)sender {self.quitRequested=YES;}
@end

static NSEvent *commandKey(NSString *key, unsigned short keyCode, NSWindow *window) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:window.windowNumber context:nil characters:key charactersIgnoringModifiers:key isARepeat:NO keyCode:keyCode];
}

@interface BBFakeCompxChannel:BBChannel
@property BOOL online;
@property NSMutableArray*commands;
@end
@implementation BBFakeCompxChannel
- (NSDictionary*)exchange:(uint8_t)rid payload:(NSData*)data matching:(BOOL(^)(NSDictionary*))match {
    if(!_commands)_commands=[NSMutableArray new];const uint8_t*p=data.bytes;[_commands addObject:@(p[0])];
    uint8_t r[17]={8,p[0],0,0,0,p[0]==3?1:2,p[0]==3?_online:53,0};
    r[16]=0x55;for(int i=0;i<16;i++)r[16]-=r[i];NSDictionary*f=@{@"id":@(rid),@"data":[NSData dataWithBytes:r length:17]};
    return match(f)?f:nil;
}
@end
@interface BBFakeLogitechChannel:BBChannel
@property NSUInteger timeouts;
@property uint8_t unifiedIndex;
@property uint8_t delayedHeader;
@property NSUInteger legacyLookups;
@end
@implementation BBFakeLogitechChannel
- (NSDictionary*)exchange:(uint8_t)rid payload:(NSData*)data matching:(BOOL(^)(NSDictionary*))match {
    const uint8_t*p=data.bytes;
    uint8_t reply[20]={0x11,p[0],p[1],p[2]};
    if(p[1]==0&&p[4]==0x04&&_timeouts){
        _timeouts--;
        _delayedHeader=p[2];
        self.lastError=kIOReturnTimeout;
        return nil;
    }
    if(_delayedHeader){
        reply[3]=_delayedHeader;reply[4]=6;reply[6]=5;
        NSDictionary*late=@{@"id":@0x11,@"data":[NSData dataWithBytes:reply length:sizeof reply]};
        ensure(!match(late),"a late Logitech feature reply cannot match a new query");
        reply[3]=p[2];reply[4]=0;reply[6]=0;
        _delayedHeader=0;
    }
    if(p[1]==0){
        if(p[4]==0x00)_legacyLookups++;
        reply[4]=p[4]==0x04?_unifiedIndex:6;
    }else{
        reply[4]=(p[2]>>4)==1?0x5c:0x0f;
        reply[5]=(p[2]>>4)==1?8:7;
    }
    self.lastError=kIOReturnSuccess;
    NSDictionary*frame=@{@"id":@0x11,@"data":[NSData dataWithBytes:reply length:sizeof reply]};
    return match(frame)?frame:nil;
}
@end
@interface BBPermissionDisplayController:BBDisplayController
@property BOOL trusted;
@property BOOL activeTap;
@property BOOL listenGranted;
@property NSMutableArray *requests;
@property NSNumber *pendingBrightness;
@end
@implementation BBPermissionDisplayController
- (BOOL)accessibilityAuthorized {return _trusted;}
- (BOOL)hasActiveMediaKeyTap {return _activeTap;}
- (BOOL)inputMonitoringAuthorized {return _listenGranted;}
- (void)setPercent:(double)percent code:(uint8_t)code identity:(NSString*)identity {
    if(!_requests)_requests=[NSMutableArray new];[_requests addObject:@{@"percent":@(percent),@"code":@(code),@"identity":identity}];
    if(code==0x10)_pendingBrightness=@(percent);
}
- (NSNumber*)pendingBrightnessForIdentity:(NSString*)identity {return [identity isEqual:@"display:test"]?_pendingBrightness:nil;}
@end
int main(int argc,const char*argv[]){@autoreleasepool{
    BBTestingUI=YES;[NSApplication sharedApplication];[BBPreferences() registerDefaults:@{@"ReportInterval":@3600,@"AutoStartEnabled":@YES}];
    ensure([NSImage imageWithSystemSymbolName:@"gamecontroller" accessibilityDescription:nil]!=nil,"macOS supplies the game controller icon");
    NSString *gamepadID=@"test.gamepad";
    ensure(mappingEnabled(gamepadID,@"Game Controller")&&!mappingEnabled(gamepadID,@"Mouse"),"only game controllers opt in to mapping by default");
    [BBPreferences() setObject:@{gamepadID:@NO} forKey:@"MappedDevices"];
    ensure(!mappingEnabled(gamepadID,@"Game Controller"),"controller mapping can be disabled");
    [BBPreferences() setObject:@{} forKey:@"MappedDevices"];
    NSDictionary *gamepadPower=BBPowerDetails(gamepadID,@"Pro Controller",@"Game Controller",
        @{@"percent":@60,@"transport":@"Bluetooth"});
    ensure([gamepadPower[@"Transport Type"] isEqual:@"Bluetooth"]&&[gamepadPower[@"Accessory Category"] isEqual:@"Game Controller"]&&
        [gamepadPower[@"Current Capacity"] intValue]==60,"a game controller publishes its battery as a Bluetooth accessory");
    ensure(receiverKind(@{@"Transport":@"USB",@"VendorID":@0x045e,@"ProductID":@0x028e,@"Product":@"Flydigi Direwolf 4"})==BBReceiverNone,
        "Xbox-compatible Flydigi is excluded from USB receiver polling");
    uint8_t flydigiDescriptor[]={0x85,3,0x75,8,0x95,31,0x91,2,0x85,4,0x81,2};
    ensure(receiverKind(@{@"Transport":@"USB",@"VendorID":@0x37d7,@"ProductID":@0x2401,@"PrimaryUsagePage":@0xffa0,
        @"ReportDescriptor":[NSData dataWithBytes:flydigiDescriptor length:sizeof flydigiDescriptor]})==BBReceiverNone,
        "Flydigi vendor HID receivers are excluded from USB receiver polling");
    // A USB mouse/keyboard usage alone must never qualify as a 2.4G receiver.
    NSMutableDictionary*hid=[@{@"Transport":@"USB",@"VendorID":@0x056a,@"ProductID":@0x0357,@"Product":@"Wacom Intuos Pro M",@"PrimaryUsagePage":@1,@"PrimaryUsage":@2} mutableCopy];
    ensure(receiverKind(hid)==BBReceiverNone,"wired Wacom mouse interface excluded");
    hid[@"PrimaryUsage"]=@6;ensure(receiverKind(hid)==BBReceiverNone,"generic USB keyboard excluded");
    hid[@"VendorID"]=@0x046d;hid[@"PrimaryUsagePage"]=@0xff00;hid[@"PrimaryUsage"]=@1;hid[@"Product"]=@"G502 HERO Gaming Mouse";
    ensure(receiverKind(hid)==BBReceiverNone,"wired Logitech vendor interface excluded");
    hid[@"Product"]=@"USB Receiver";ensure(receiverKind(hid)==BBReceiverLogitech,"Logitech USB receiver retained");
    hid[@"Product"]=@"LIGHTSPEED Receiver";ensure(receiverKind(hid)==BBReceiverLogitech,"LIGHTSPEED receiver retained");
    hid[@"Transport"]=@"Bluetooth";ensure(receiverKind(hid)==BBReceiverNone,"Bluetooth excluded even with receiver-like name");
    hid[@"Transport"]=@"USB";hid[@"VendorID"]=@0x3837;hid[@"ProductID"]=@0x1015;hid[@"PrimaryUsagePage"]=@0xff80;hid[@"Product"]=@"MCHOSE K87 V3 2.4G";
    ensure(receiverKind(hid)==BBReceiverQHW,"MCHOSE 2.4G receiver retained");
    hid[@"Product"]=@"MCHOSE K87 V3";ensure(receiverKind(hid)==BBReceiverNone,"MCHOSE wired mode excluded");
    hid[@"VendorID"]=@0xa8a5;hid[@"ProductID"]=@0x2255;hid[@"PrimaryUsagePage"]=@1;hid[@"PrimaryUsage"]=@2;hid[@"Product"]=@"USB Receiver";
    ensure(receiverKind(hid)==BBReceiverNone,"shared YJX identifier requires verified descriptor");
    hid[@"ReportDescriptor"]=[[NSData alloc]initWithBase64EncodedString:@"BQEJAqEBCQGhAIUFBQkZASkQFQAlAZUQdQGBAgUBCTAJMRYBgCb/f5UCdRCBBgk4FYElf5UBdQiBBgUMCjgClQGBBsDABQEJBqEBhQKVcHUBFQAlAQUHGQAq/wCBAsAFDAkBoQGFAxkBKv8DFQEm/wOVAXUQgQDABQEJgKEBhQQZgSmDFQAlAZUDdQGBApUFgQHABqv/CQChAYWrFQAm/wAZACr/AJU9dQiBAhkAKv8AlT11CJECwAYB/wkQoQGF8BUAJv8AGQEpCJU/dQiBAhkBKQiRAsA=" options:0];
    ensure(receiverKind(hid)==BBReceiverYJX,"verified YJX 2.4G receiver retained");
    uint8_t f75Descriptor[]={0x85,0x13,0x75,8,0x95,19,0x81,2,0x91,2};
    hid[@"VendorID"]=@0x3554;hid[@"ProductID"]=@0xfa09;hid[@"PrimaryUsagePage"]=@0xff02;hid[@"PrimaryUsage"]=@1;
    hid[@"ReportDescriptor"]=[NSData dataWithBytes:f75Descriptor length:sizeof f75Descriptor];
    ensure(receiverKind(hid)==BBReceiverAulaF75,"F75 receiver with battery collection accepted");
    hid[@"PrimaryUsagePage"]=@1;ensure(receiverKind(hid)==BBReceiverNone,"F75 normal keyboard interface excluded");
    hid[@"PrimaryUsagePage"]=@0xff02;hid[@"ProductID"]=@0xfa08;ensure(receiverKind(hid)==BBReceiverNone,"F75 other connection identifier excluded");
    hid[@"ProductID"]=@0xfa09;hid[@"Transport"]=@"Bluetooth";ensure(receiverKind(hid)==BBReceiverNone,"F75 Bluetooth excluded");
    uint8_t sc580Descriptor[]={0x85,0x0f,0x75,8,0x95,32,0xb1,2};
    hid[@"Transport"]=@"USB";hid[@"VendorID"]=@0x089d;hid[@"ProductID"]=@0x062f;hid[@"PrimaryUsagePage"]=@0xff00;
    hid[@"ReportDescriptor"]=[NSData dataWithBytes:sc580Descriptor length:sizeof sc580Descriptor];
    ensure(receiverKind(hid)==BBReceiverAulaSC580,"SC580 wireless feature collection accepted");
    hid[@"VendorID"]=@0x088d;hid[@"ProductID"]=@0x062e;ensure(receiverKind(hid)==BBReceiverNone,"SC580 wired device excluded");
    hid[@"VendorID"]=@0x089d;hid[@"ProductID"]=@0x062f;[hid removeObjectForKey:@"ReportDescriptor"];
    ensure(receiverKind(hid)==BBReceiverNone,"SC580 missing feature report excluded");
    // Receiver-only allowlists and actual USB interface numbers are required.
    hid=[@{@"Transport":@"USB",@"VendorID":@0x1532,@"ProductID":@0x0296,@"USBInterfaceNumber":@2} mutableCopy];
    ensure(receiverKind(hid)==BBReceiverRazer,"Razer TKL receiver control interface accepted without name guessing");
    ensure([receiverProfile(hid)[@"category"] isEqual:@"Keyboard"],"Razer receiver classified as keyboard");
    hid[@"USBInterfaceNumber"]=@0;ensure(receiverKind(hid)==BBReceiverNone,"Razer keyboard normal input interface excluded");
    hid[@"USBInterfaceNumber"]=@2;hid[@"ProductID"]=@0x0298;ensure(receiverKind(hid)==BBReceiverNone,"Razer TKL wired ID excluded");
    NSArray*razerReceivers=@[@0x025c,@0x0271,@0x02ba,@0x02d5,@0x0290,@0x0296,@0x00a6,@0x00c1,@0x00b7,@0x00c5,@0x00bf];
    for(NSNumber*pid in razerReceivers){
        hid[@"ProductID"]=pid;hid[@"USBInterfaceNumber"]=(pid.intValue<0x0100)?@0:((pid.intValue==0x0271||pid.intValue==0x02ba)?@3:@2);
        ensure(receiverKind(hid)==BBReceiverRazer,"documented Razer receiver accepted");
        hid[@"Transport"]=@"Bluetooth";ensure(receiverKind(hid)==BBReceiverNone,"Razer Bluetooth excluded");hid[@"Transport"]=@"USB";
    }
    for(NSNumber*pid in @[@0x00a5,@0x00c0,@0x00b6,@0x00c4,@0x00be]){
        hid[@"ProductID"]=pid;hid[@"USBInterfaceNumber"]=@0;ensure(receiverKind(hid)==BBReceiverNone,"Razer mouse cable ID excluded");
    }
    hid[@"ProductID"]=@0x00bf;
    [hid removeObjectForKey:@"USBInterfaceNumber"];ensure(receiverKind(hid)==BBReceiverNone,"Razer missing USB interface refused");
    uint8_t kcDescriptor[]={0x85,0xb3,0x75,8,0x95,63,0x91,2,0x85,0xb4,0x81,2};
    hid[@"VendorID"]=@0x3434;hid[@"ProductID"]=@0xd028;hid[@"USBInterfaceNumber"]=@4;hid[@"PrimaryUsagePage"]=@0xffc1;
    hid[@"ReportDescriptor"]=[NSData dataWithBytes:kcDescriptor length:sizeof kcDescriptor];
    ensure(receiverKind(hid)==BBReceiverKeychron,"Keychron receiver vendor output/input accepted");
    hid[@"USBInterfaceNumber"]=@0;ensure(receiverKind(hid)==BBReceiverNone,"Keychron mouse input interface excluded");hid[@"USBInterfaceNumber"]=@4;
    hid[@"ProductID"]=@0xd048;ensure(receiverKind(hid)==BBReceiverNone,"Keychron cable ID excluded");
    uint8_t glDescriptor[]={0x75,8,0x95,64,0xb1,2};
    hid[@"VendorID"]=@0x258a;hid[@"ProductID"]=@0x2022;hid[@"PrimaryUsagePage"]=@0xffa0;
    hid[@"ReportDescriptor"]=[NSData dataWithBytes:glDescriptor length:sizeof glDescriptor];
    ensure(receiverKind(hid)==BBReceiverGlorious,"Glorious receiver exact feature length accepted");
    hid[@"PrimaryUsagePage"]=@1;ensure(receiverKind(hid)==BBReceiverNone,"Glorious regular input collection excluded");hid[@"PrimaryUsagePage"]=@0xffff;
    hid[@"ProductID"]=@0x2011;ensure(receiverKind(hid)==BBReceiverNone,"Glorious wired ID excluded");
    uint8_t ssDescriptor[]={0x75,8,0x95,64,0x91,2};
    hid[@"VendorID"]=@0x1038;hid[@"PrimaryUsagePage"]=@0xffc0;hid[@"ReportDescriptor"]=[NSData dataWithBytes:ssDescriptor length:sizeof ssDescriptor];
    for(NSNumber*pid in @[@0x1838,@0x1878,@0x1852,@0x185c,@0x1860,@0x1858,@0x1874]){
        hid[@"ProductID"]=pid;ensure(receiverKind(hid)==BBReceiverSteelSeries,"documented Aerox receiver accepted");
    }
    for(NSNumber*pid in @[@0x183a,@0x187a,@0x1854,@0x185e,@0x1862,@0x185a,@0x1876,@0x1890]){
        hid[@"ProductID"]=pid;ensure(receiverKind(hid)==BBReceiverNone,"Aerox cable or unadapted generation excluded");
    }
    hid[@"ProductID"]=@0x1838;[hid removeObjectForKey:@"ReportDescriptor"];ensure(receiverKind(hid)==BBReceiverNone,"Aerox unknown report layout refused");
    BBChannel*inputChannel=[BBChannel new];inputChannel.frames=[NSMutableArray new];inputChannel.allowedInputReports=[NSSet setWithObject:@0xb4];
    uint8_t inputBytes[64]={0};
    reportCallback((__bridge void*)inputChannel,0,NULL,kIOHIDReportTypeInput,0,inputBytes,64);
    ensure(inputChannel.frames.count==0,"ordinary unnumbered input discarded on Keychron channel");
    reportCallback((__bridge void*)inputChannel,0,NULL,kIOHIDReportTypeInput,0xb4,inputBytes,64);
    ensure(inputChannel.frames.count==1,"Keychron vendor reply routed to its channel");
    inputChannel.allowedInputReports=[NSSet set];
    reportCallback((__bridge void*)inputChannel,0,NULL,kIOHIDReportTypeInput,0xb4,inputBytes,64);
    ensure(inputChannel.frames.count==1,"feature-only Razer and Glorious channels retain no input reports");
    // Current receivers remain distinct from cable IDs and unrelated USB inputs.
    hid=[@{@"Transport":@"USB",@"VendorID":@0x1532,@"ProductID":@0x00e6,@"USBInterfaceNumber":@0} mutableCopy];
    ensure([receiverProfile(hid)[@"name"] isEqual:@"Razer Viper V4 Pro"],"Viper V4 Pro 2026 receiver supported");
    hid[@"ProductID"]=@0x00e5;ensure(receiverKind(hid)==BBReceiverNone,"Viper V4 cable excluded");
    hid[@"ProductID"]=@0x00f0;ensure(receiverKind(hid)==BBReceiverRazer,"DeathAdder V4 Carbon Fiber receiver accepted");
    uint8_t compxDescriptor[]={0x85,8,0x75,8,0x95,16,0x91,2,0x81,2};
    hid[@"PrimaryUsagePage"]=@0xff02;hid[@"PrimaryUsage"]=@2;hid[@"ReportDescriptor"]=[NSData dataWithBytes:compxDescriptor length:sizeof compxDescriptor];
    for(NSArray*ids in @[@[@0x3554,@0xf508],@[@0x3554,@0xf509],@[@0x3554,@0xf58a],@[@0x3554,@0xf505],@[@0x3554,@0xf523],@[@0x373b,@0x1085],@[@0x373b,@0x101a],@[@0x373b,@0x101b],@[@0x3710,@0x5406],@[@0x1b1c,@0x2b2a],@[@0x3770,@0x0200]]){
        hid[@"VendorID"]=ids[0];hid[@"ProductID"]=ids[1];ensure(receiverKind(hid)==BBReceiverCompx,"documented Compx RF receiver accepted");
        hid[@"Transport"]=@"Bluetooth";ensure(receiverKind(hid)==BBReceiverNone,"Compx Bluetooth excluded");hid[@"Transport"]=@"USB";
    }
    hid[@"VendorID"]=@0x3554;hid[@"ProductID"]=@0xf58c;ensure(receiverKind(hid)==BBReceiverNone,"VXE R1 Pro Max wired ID excluded");
    hid[@"ProductID"]=@0xf58a;hid[@"PrimaryUsage"]=@1;ensure(receiverKind(hid)==BBReceiverNone,"Compx wrong collection excluded");
    uint8_t mchoseDescriptor[]={0x85,0x11,0x75,8,0x95,20,0xb1,2};
    hid[@"VendorID"]=@0x3837;hid[@"ProductID"]=@0x100b;hid[@"PrimaryUsagePage"]=@0xff01;hid[@"PrimaryUsage"]=@1;hid[@"ReportDescriptor"]=[NSData dataWithBytes:mchoseDescriptor length:sizeof mchoseDescriptor];
    ensure(receiverKind(hid)==BBReceiverMchose,"MCHOSE A7 V2 Ultra feature interface accepted");
    hid[@"PrimaryUsagePage"]=@0xff0b;ensure(receiverKind(hid)==BBReceiverNone,"MCHOSE nonresponding sibling collection excluded");hid[@"PrimaryUsagePage"]=@0xff01;
    hid[@"ProductID"]=@0x4245;ensure(receiverKind(hid)==BBReceiverNone,"MCHOSE incompatible G3 family not swept in by vendor");
    uint8_t atkDescriptor[]={0x85,4,0x75,8,0x95,31,0x91,2,0x81,2};
    hid[@"VendorID"]=@0x320f;hid[@"ProductID"]=@0x5088;hid[@"PrimaryUsagePage"]=@0xff1c;hid[@"PrimaryUsage"]=@0x92;hid[@"Product"]=@"ATK V75X 2.4G Dongle";hid[@"ReportDescriptor"]=[NSData dataWithBytes:atkDescriptor length:sizeof atkDescriptor];
    ensure(receiverKind(hid)==BBReceiverATKKeyboard,"ATK V75X 2026 wireless keyboard accepted");
    hid[@"Product"]=@"Other Keyboard";ensure(receiverKind(hid)==BBReceiverNone,"shared ATK USB ID requires actual product name");
    uint8_t omniDescriptor[]={0x85,1,0x75,8,0x95,63,0x91,2,0x81,2};
    hid[@"VendorID"]=@0x0b05;hid[@"ProductID"]=@0x1ace;hid[@"LocationID"]=@123;hid[@"USBInterfaceNumber"]=@2;hid[@"PrimaryUsagePage"]=@0xff02;hid[@"PrimaryUsage"]=@1;hid[@"ReportDescriptor"]=[NSData dataWithBytes:omniDescriptor length:sizeof omniDescriptor];
    ensure(receiverKind(hid)==BBReceiverASUSOmni,"ASUS OMNI pairing-control interface accepted");
    hid[@"PrimaryUsagePage"]=@1;ensure(receiverKind(hid)==BBReceiverNone,"ASUS OMNI keyboard input excluded");
    uint8_t superstrikeDescriptor[]={0x85,0x10,0x75,8,0x95,6,0x91,2};
    hid[@"VendorID"]=@0x046d;hid[@"ProductID"]=@0xc54d;hid[@"PrimaryUsagePage"]=@0xff00;hid[@"PrimaryUsage"]=@1;hid[@"Product"]=@"PRO X2 SUPERSTRIKE";hid[@"ReportDescriptor"]=[NSData dataWithBytes:superstrikeDescriptor length:sizeof superstrikeDescriptor];
    ensure(receiverKind(hid)==BBReceiverLogitech,"2026 SUPERSTRIKE receiver does not depend on receiver word in product name");
    [hid removeObjectForKey:@"ReportDescriptor"];ensure(receiverKind(hid)==BBReceiverNone,"SUPERSTRIKE requires HID++ output descriptor");
    BBFakeCompxChannel*compx=[BBFakeCompxChannel new];
    NSNumber *compxOnline=nil;
    ensure(BBCompxBattery(compx,&compxOnline)==nil&&[compxOnline isEqual:@NO]&&[compx.commands isEqual:@[@3]],"offline Compx receiver never queried for cached battery");
    compx.online=YES;[compx.commands removeAllObjects];
    ensure([BBCompxBattery(compx,&compxOnline)[@"percent"] intValue]==53&&compxOnline.boolValue&&[compx.commands isEqual:@[@3,@4]],"online check precedes every Compx battery read");
    BBFakeLogitechChannel*logitech=[BBFakeLogitechChannel new];
    logitech.unifiedIndex=6;logitech.timeouts=1;
    ensure([BBLogitechBattery(logitech,1)[@"percent"] intValue]==92&&logitech.legacyLookups==0,
           "retry a timed-out Logitech unified battery lookup and read the correct percentage");
    logitech.timeouts=2;
    ensure(!BBLogitechBattery(logitech,1)&&logitech.legacyLookups==0,
           "Logitech lookup timeout cannot trigger legacy battery decoding");
    logitech.unifiedIndex=0;
    ensure([BBLogitechBattery(logitech,1)[@"percent"] intValue]==15&&logitech.legacyLookups==1,
           "Logitech legacy battery percentage is accepted after explicit unified feature absence");
    uint8_t omniKeyboardDescriptor[]={0x85,2,0x75,8,0x95,63,0x91,2,0x81,2};
    NSMutableDictionary*omniKeyboard=[@{@"Transport":@"USB",@"VendorID":@0x0b05,@"ProductID":@0x1ace,@"LocationID":@123,@"USBInterfaceNumber":@2,@"PrimaryUsagePage":@0xff00,@"PrimaryUsage":@2,@"ReportDescriptor":[NSData dataWithBytes:omniKeyboardDescriptor length:sizeof omniKeyboardDescriptor]} mutableCopy];
    ensure(BBASUSKeyboardInterfaceMatches(omniKeyboard,@"0b05:1ace:123"),"OMNI keyboard channel resolves on same receiver");
    ensure(!BBASUSKeyboardInterfaceMatches(omniKeyboard,@"0b05:1ace:124"),"two OMNI receivers cannot exchange paired keyboard data");
    [omniKeyboard removeObjectForKey:@"LocationID"];ensure(!BBASUSKeyboardInterfaceMatches(omniKeyboard,@"0b05:1ace:0"),"missing location never groups unrelated OMNI devices");
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSArray*fixtures=@[@{@"name":@"G304 X LIGHTSPEED",@"identity":@"test.mouse",@"category":@"Mouse",@"connected":@YES,@"fresh":@YES,@"percent":@94,@"charging":@NO,@"full":@NO,@"updated":@(now),@"mapped":@YES,@"published":@YES,@"status":@"已映射到系统电量",@"selectable":@YES},@{@"name":@"MCHOSE K87 V3",@"identity":@"test.keyboard",@"category":@"Keyboard",@"connected":@YES,@"fresh":@YES,@"percent":@92,@"charging":@NO,@"full":@NO,@"updated":@(now),@"mapped":@YES,@"published":@YES,@"status":@"已映射到系统电量",@"selectable":@YES}];
    BBShortcutTestApp*app=[BBShortcutTestApp new];app.engine=[BBEngine new];app.engine.snapshot=fixtures;app.statusMenu=[NSMenu new];app.statusMenu.autoenablesItems=NO;[app menuNeedsUpdate:app.statusMenu];
    ensure(app.statusMenu.numberOfItems==2,"status menu contains only the two application commands");
    ensure([[app.statusMenu itemAtIndex:app.statusMenu.numberOfItems-2].title isEqual:@"显示主界面"]&&[app.statusMenu itemAtIndex:app.statusMenu.numberOfItems-2].action==@selector(showSettings:),"first command opens main window");
    ensure([[app.statusMenu itemAtIndex:app.statusMenu.numberOfItems-1].title isEqual:@"退出程序"]&&[app.statusMenu itemAtIndex:app.statusMenu.numberOfItems-1].action==@selector(quit:)&&[[app.statusMenu itemAtIndex:app.statusMenu.numberOfItems-1].keyEquivalent isEqual:@"q"],"second command quits with keyboard shortcut");
    NSMutableDictionary *offlineWireless=[fixtures[0] mutableCopy];offlineWireless[@"connected"]=@NO;offlineWireless[@"fresh"]=@NO;
    app.engine.snapshot=[fixtures arrayByAddingObject:offlineWireless];[app menuNeedsUpdate:app.statusMenu];
    ensure(app.statusMenu.numberOfItems==2,"disconnected wireless devices are omitted from menu");
    app.engine.snapshot=@[offlineWireless,fixtures[1]];[app menuNeedsUpdate:app.statusMenu];
    ensure(app.statusMenu.numberOfItems==2,"wireless disconnection does not add menu entries");
    app.engine.snapshot=fixtures;[app menuNeedsUpdate:app.statusMenu];
    ensure(app.statusMenu.numberOfItems==2,"wireless reconnection does not add menu entries");
    NSMenuItem*three=[NSMenuItem new];three.representedObject=@10800;[app changeInterval:three];ensure(BBInterval([BBPreferences() objectForKey:@"ReportInterval"])==10800,"interval menu saves three hours");
    NSMenuItem*mapping=[NSMenuItem new];mapping.representedObject=@"test.mouse";[app toggleMapping:mapping];ensure(mappingEnabled(@"test.mouse",@"Mouse"),"mapping can be enabled");[app toggleMapping:mapping];ensure(!mappingEnabled(@"test.mouse",@"Mouse"),"mapping can be disabled");
    ensure(![app applicationShouldTerminateAfterLastWindowClosed:NSApp],"closing window does not terminate app");
    BBDeviceRow*card=[[BBDeviceRow alloc]initWithFrame:NSMakeRect(0,0,640,96) record:fixtures[0]];card.menuTarget=app;
    NSEvent*rightClick=[NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];
    ensure([card menuForEvent:rightClick]==nil,"connected device row has no context menu");
    BOOL hasMappingLabel=NO;
    for(NSView*v in card.subviews){
        if([v isKindOfClass:NSButton.class])ensure(v==card.refreshButton,"refresh is the wireless row’s only button");
        if([v isKindOfClass:NSTextField.class]&&[[(NSTextField*)v stringValue] isEqual:@"映射"])hasMappingLabel=YES;
    }
    ensure(hasMappingLabel,"mapping label uses requested wording");
    app.engine.forcePoll=NO;
    BBDeviceRow*unknown=[[BBDeviceRow alloc]initWithFrame:NSMakeRect(0,0,640,96) record:@{@"name":@"Unknown",@"connected":@YES,@"selectable":@NO}];unknown.menuTarget=app;
    [card performDeviceAction:card.refreshButton];
    ensure([app.engine.refreshTargets containsObject:@"test.mouse"]&&app.engine.refreshTargets.count==1,"row refresh button targets its own device");
    ensure(!unknown.refreshButton.enabled,"unsupported row disables refresh");
    ensure(card.mappingSwitch.enabled&&!unknown.mappingSwitch.enabled,"mapping switch respects protocol support");
    card.mappingSwitch.state=NSControlStateValueOn;[card mappingChanged:card.mappingSwitch];ensure(mappingEnabled(@"test.mouse",@"Mouse"),"card switch enables mapping");
    card.mappingSwitch.state=NSControlStateValueOff;[card mappingChanged:card.mappingSwitch];ensure(!mappingEnabled(@"test.mouse",@"Mouse"),"card switch disables mapping");
    [NSApp finishLaunching];
    [app buildWindow];
    [BBPreferences() setObject:@{@"test.mouse":@YES} forKey:@"MappedDevices"];
    app.engine.snapshot=@[offlineWireless,fixtures[1]];
    [app refresh];
    ensure(app.wirelessGroup.subviews.count==1&&
           [((BBDeviceRow *)app.wirelessGroup.subviews.firstObject).record[@"identity"] isEqual:@"test.keyboard"],
           "disconnected wireless devices are hidden");
    app.engine.snapshot=fixtures;
    [app refresh];
    ensure(app.wirelessGroup.subviews.count==2&&mappingEnabled(@"test.mouse",@"Mouse"),
           "reconnected devices reappear with their saved mapping");
    NSImage*brand=BBStatusIcon();ensure(brand.isTemplate&&brand.size.width==20,"brand menu bar icon is a monochrome system template");
    [app buildWindow];
    [app refresh];
    BOOL hasListTitle=NO;for(NSView*v in app.devicesView.subviews)if([v isKindOfClass:NSTextField.class]&&[[(NSTextField*)v stringValue] isEqual:@"设备列表"])hasListTitle=YES;
    ensure(hasListTitle,"main window title uses device list wording");
    for(NSView *view in app.settingsGroup.subviews)if([view isKindOfClass:NSTextField.class])ensure(![[(NSTextField*)view stringValue] isEqual:@"登录 Mac 后自动运行 DeviceBridge"],"login switch has no redundant description text");
    ensure(app.intervalPicker.numberOfItems==5&&[app.intervalPicker itemWithTitle:@"每5 分钟"]!=nil,"main window offers five update intervals including five minutes");
    [app.intervalPicker selectItemAtIndex:0];app.engine.forcePoll=NO;[app pickInterval:app.intervalPicker];
    ensure(BBInterval([BBPreferences() objectForKey:@"ReportInterval"])==300&&app.engine.forcePoll,"five minute interval is saved and immediately requests a fresh reading");
    app.autoStartSwitch.state=NSControlStateValueOn;[app toggleAutoStart:app.autoStartSwitch];ensure([BBPreferences() boolForKey:@"AutoStartEnabled"],"main window startup switch persists enabled state");
    app.autoStartSwitch.state=NSControlStateValueOff;[app toggleAutoStart:app.autoStartSwitch];ensure(![BBPreferences() boolForKey:@"AutoStartEnabled"],"main window startup switch persists disabled state");
    [app showWindow];[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];ensure(app.window.visible,"opening main window displays it");
    ensure([NSApp.mainMenu performKeyEquivalent:commandKey(@"w",13,app.window)],"Command-W dispatches from the main menu");
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];ensure(!app.window.visible&&!app.quitRequested,"Command-W closes the window and keeps the app running");
    [app showWindow];[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];ensure(app.window.visible,"main window can reopen after close");
    ensure([NSApp.mainMenu performKeyEquivalent:commandKey(@"q",12,app.window)]&&app.quitRequested,"Command-Q dispatches the app's quit action");
    [app.window orderOut:nil];
    ensure([app.window.title containsString:Version],"window title exposes the running version");
    BBPermissionDisplayController *permissionDisplays=[BBPermissionDisplayController new];app.displays=permissionDisplays;
    NSDictionary*displayFixture=@{@"identity":@"display:test",@"category":@"Display",@"connected":@YES,@"mappingEnabled":@YES,@"brightnessBridgeEnabled":@YES,@"brightnessBridgeAvailable":@YES,@"volumeBridgeEnabled":@YES,@"audioOutputUID":@"test-hdmi",@"updated":@(now),@"name":@"DELL S2725QS",@"brightness":@{@"percent":@55},@"volume":@{@"percent":@20},@"status":@"DDC 已读取"};
    NSMutableDictionary *offlineDisplay=[displayFixture mutableCopy];
    offlineDisplay[@"connected"]=@NO;
    offlineDisplay[@"identity"]=@"display:disconnected";
    [app.displays setValue:@[offlineDisplay,displayFixture] forKey:@"snapshot"];
    app.devicesSignature=nil;[app refresh];
    ensure(app.displayGroup.subviews.count==1&&
           [((BBDisplayRow *)app.displayGroup.subviews.firstObject).record[@"identity"] isEqual:@"display:test"],
           "disconnected display rows are hidden");
    ensure(app.authorizeButton.hidden,"shortcut authorization uses first-launch onboarding without a manual button");
    permissionDisplays.listenGranted=YES;[app refresh];
    ensure(!permissionDisplays.mediaKeysAuthorized&&app.authorizeButton.hidden,"listen-only access does not grant shortcuts or restore a manual shortcut button");
    permissionDisplays.trusted=YES;[app refresh];
    ensure(app.authorizeButton.hidden,"granted Accessibility immediately hides shortcut authorization without a device change");
    permissionDisplays.trusted=NO;permissionDisplays.activeTap=YES;[app refresh];
    ensure(app.authorizeButton.hidden,"working filtering event tap hides redundant authorization");
    permissionDisplays.activeTap=NO;[app applicationDidBecomeActive:[NSNotification notificationWithName:NSApplicationDidBecomeActiveNotification object:NSApp]];
    ensure(!permissionDisplays.mediaKeysAuthorized&&app.authorizeButton.hidden,"revoked permission stays detected without showing a manual shortcut button");
    permissionDisplays.trusted=YES;[app applicationDidBecomeActive:[NSNotification notificationWithName:NSApplicationDidBecomeActiveNotification object:NSApp]];
    ensure(app.authorizeButton.hidden,"returning from Settings detects newly granted permission");
    [permissionDisplays setValue:@YES forKey:@"permissionCheckComplete"];[permissionDisplays setValue:@0 forKey:@"deviceControlStatus"];permissionDisplays.trusted=NO;permissionDisplays.activeTap=NO;[app refresh];
    ensure(app.authorizeButton.hidden,"granted device-control permission hides authorization even if AX preflight is false");
    [permissionDisplays setValue:@1 forKey:@"deviceControlStatus"];permissionDisplays.trusted=YES;permissionDisplays.activeTap=YES;[app refresh];
    ensure(app.authorizeButton.hidden,"PostEvent denial cannot override Accessibility or a working filtering tap");
    [permissionDisplays setValue:@2 forKey:@"deviceControlStatus"];[app refresh];
    ensure(app.authorizeButton.hidden,"unknown PostEvent state cannot override working shortcut access");
    permissionDisplays.trusted=NO;permissionDisplays.activeTap=NO;[app refresh];
    ensure(!permissionDisplays.mediaKeysAuthorized&&app.authorizeButton.hidden,"unavailable shortcut permission never restores removed shortcut button");
    [permissionDisplays setValue:@NO forKey:@"permissionCheckComplete"];permissionDisplays.trusted=YES;permissionDisplays.activeTap=NO;
    [app menuNeedsUpdate:app.statusMenu];
    ensure(app.statusMenu.numberOfItems==2,"display discovery does not add device sections to menu");
    NSUInteger displayRows=0;for(NSView*v in app.displayGroup.subviews)if([v isKindOfClass:BBDisplayRow.class]){
        displayRows++;BBDisplayRow*r=(BBDisplayRow*)v;NSMenu *injected=[NSMenu new];[injected addItemWithTitle:@"删除" action:NULL keyEquivalent:@""];r.menu=injected;
        ensure([r menuForEvent:rightClick]==nil,"display cannot be deleted through a context menu even if a menu is assigned");ensure(r.brightnessSlider.enabled&&r.volumeSlider.enabled,"display row exposes both detected controls");
        ensure(NSMaxX(r.volumeSlider.frame)<=NSMinX(r.mappingSwitch.frame),"display controls precede mapping switch");
        ensure(r.mappingSwitch.state==NSControlStateValueOn&&r.refreshButton.frame.origin.x==r.bounds.size.width-50,"display mapping is enabled and refresh stays at the right edge");
    }
    BBDisplayRow *audioRow=[[BBDisplayRow alloc]initWithFrame:NSMakeRect(0,0,640,96) record:displayFixture];
    ensure(audioRow.brightnessBridgeSwitch!=audioRow.volumeBridgeSwitch&&audioRow.volumeBridgeSwitch.enabled,"brightness and audio have separate usable switches");
    NSMutableDictionary *silentRecord=[displayFixture mutableCopy];[silentRecord removeObjectForKey:@"audioOutputUID"];
    BBDisplayRow *silentRow=[[BBDisplayRow alloc]initWithFrame:NSMakeRect(0,0,640,96) record:silentRecord];
    ensure(!silentRow.volumeBridgeSwitch.enabled&&silentRow.volumeBridgeSwitch.state==NSControlStateValueOff&&silentRow.brightnessBridgeSwitch.enabled,"non-audio monitor disables only volume bridge, even with DDC volume metadata");
    NSMutableDictionary *unsignedRecord=[displayFixture mutableCopy];unsignedRecord[@"brightnessBridgeAvailable"]=@NO;
    BBDisplayRow *unsignedRow=[[BBDisplayRow alloc]initWithFrame:NSMakeRect(0,0,640,96) record:unsignedRecord];
    ensure(!unsignedRow.brightnessBridgeSwitch.enabled&&unsignedRow.brightnessBridgeSwitch.state==NSControlStateValueOff&&unsignedRow.brightnessSlider.enabled&&unsignedRow.volumeBridgeSwitch.enabled,"missing HID signing disables only native brightness bridge and never presents an enabled bridge");
    ensure(audioRow.brightnessSlider.frame.size.width>=140&&audioRow.volumeSlider.frame.size.width==audioRow.brightnessSlider.frame.size.width,"both hardware control tracks are enlarged equally");
    ensure(displayRows==1,"display discovered alongside wireless receivers");
    BBDisplayRow *trackingRow=(BBDisplayRow*)app.displayGroup.subviews.firstObject;
    NSSlider *brightnessSlider=trackingRow.brightnessSlider;
    ensure(brightnessSlider.continuous,"brightness sends changes during a drag");
    [brightnessSlider setValue:@YES forKey:@"tracking"];
    brightnessSlider.doubleValue=85;
    [brightnessSlider sendAction:brightnessSlider.action to:brightnessSlider.target];
    ensure([[[trackingRow valueForKey:@"brightnessValueLabel"] stringValue] isEqual:@"85%"],"percentage follows the slider immediately");
    NSMutableDictionary *olderReading=[displayFixture mutableCopy];olderReading[@"brightness"]=@{@"percent":@60};
    [app.displays setValue:@[olderReading] forKey:@"snapshot"];[app refresh];
    ensure(app.displayGroup.subviews.firstObject==trackingRow&&brightnessSlider.intValue==85,"refresh preserves the slider while the mouse is tracking");
    [brightnessSlider setValue:@NO forKey:@"tracking"];[app refresh];
    BBDisplayRow *rebuiltRow=(BBDisplayRow*)app.displayGroup.subviews.firstObject;
    ensure(rebuiltRow!=trackingRow&&rebuiltRow.brightnessSlider.intValue==85&&[[[rebuiltRow valueForKey:@"brightnessValueLabel"] stringValue] isEqual:@"85%"],"rebuilt row shows the latest goal over the older readback");
    permissionDisplays.pendingBrightness=nil;
    NSMutableDictionary *confirmedReading=[displayFixture mutableCopy];confirmedReading[@"brightness"]=@{@"percent":@85};
    [app.displays setValue:@[confirmedReading] forKey:@"snapshot"];[app refresh];
    ensure(((BBDisplayRow*)app.displayGroup.subviews.firstObject).brightnessSlider.intValue==85,"confirming the final value does not move the thumb backwards");
    BBDisplayRow *editableRow = (BBDisplayRow *)app.displayGroup.subviews.firstObject;
    for (NSNumber *volume in @[@NO, @YES]) {
        NSTextField *field = [editableRow valueForKey:volume.boolValue ? @"volumeValueLabel" : @"brightnessValueLabel"];
        NSSlider *slider = volume.boolValue ? editableRow.volumeSlider : editableRow.brightnessSlider;
        ensure(field.isEditable && [app.window makeFirstResponder:field], "available percent field accepts keyboard focus");
        NSTextView *editor = (NSTextView *)field.currentEditor;
        [editor insertText:@"37" replacementRange:NSMakeRange(0, editor.string.length)];
        app.devicesSignature = nil;
        [app refresh];
        ensure(app.displayGroup.subviews.firstObject == editableRow && [editor.string isEqual:@"37"], "refresh preserves the in-progress percentage");
        [editor insertNewline:nil];
        NSDictionary *request = permissionDisplays.requests.lastObject;
        ensure(slider.intValue == 37 && [field.stringValue isEqual:@"37%"] && [request[@"percent"] isEqual:@37] &&
               [request[@"code"] isEqual:volume.boolValue ? @0x62 : @0x10], "Return applies the exact percentage to the matching monitor control");
        NSUInteger count = permissionDisplays.requests.count;
        ensure([app.window makeFirstResponder:field], "percent field can be edited again");
        editor = (NSTextView *)field.currentEditor;
        [editor insertText:@"101" replacementRange:NSMakeRange(0, editor.string.length)];
        [editor insertNewline:nil];
        ensure(permissionDisplays.requests.count == count && [field.stringValue isEqual:@"37%"], "out-of-range input restores the last value without writing");
        ensure([app.window makeFirstResponder:field], "percent field can accept a new edit after invalid input");
        editor = (NSTextView *)field.currentEditor;
        [editor insertText:@"42" replacementRange:NSMakeRange(0, editor.string.length)];
        [editor doCommandBySelector:@selector(cancelOperation:)];
        ensure(permissionDisplays.requests.count == count && [field.stringValue isEqual:@"37%"] && !editableRow.isEditingPercent,
               "Escape cancels the edit without changing the control");
    }
    ensure(app.displayGroup.groupHeight==96&&app.wirelessGroup.groupHeight==fixtures.count*96,"each category has its own grouped rows");
    ensure(NSMaxY(app.displayGroup.frame)<NSMinY(app.wirelessHeading.frame)&&NSMaxY(app.wirelessGroup.frame)<NSMinY(app.generalHeading.frame),"displays precede wireless devices and general settings");
    ensure(app.settingsGroup.superview==app.devicesView&&app.authorizeButton.superview==app.devicesView,"settings and header belong to the same scroll document");
    ensure(app.devicesScroll.superview==app.window.contentView&&app.window.contentView.subviews.count==1,"entire window content scrolls together");
    for(NSNumber*legacy in @[@YES,@NO]){
        app.devicesScroll.scrollerStyle=legacy.boolValue?NSScrollerStyleLegacy:NSScrollerStyleOverlay;
        for(NSValue*size in @[[NSValue valueWithSize:NSMakeSize(560,420)],[NSValue valueWithSize:NSMakeSize(900,620)]]){
            [app.window setContentSize:size.sizeValue];app.devicesSignature=nil;[app refresh];
            for(NSView*row in [app.displayGroup.subviews arrayByAddingObjectsFromArray:app.wirelessGroup.subviews]){
                ensure(row.frame.size.height==96,"display and wireless rows share the same height");
                for(NSView*control in row.subviews){
                    ensure(NSMinX(control.frame)>=0&&NSMaxX(control.frame)<=row.bounds.size.width,"mixed row controls fit at narrow and wide widths");
                    if ([control isKindOfClass:NSImageView.class] && NSWidth(control.frame) == 40)
                        ensure(NSMidY(control.frame) == NSMidY(row.bounds), "device icon is centered vertically in its row");
                }
            }
        }
    }
    app.displays=nil;app.devicesSignature=nil;[app refresh];
    for(NSView *view in app.devicesView.subviews)if([view isKindOfClass:NSButton.class]){
        NSString *title=[(NSButton*)view title];
        ensure(![title containsString:@"系统音量"]&&![title containsString:@"手动安装"],"main window has no manual audio installation buttons");
    }
    ensure((app.window.styleMask&NSWindowStyleMaskResizable)!=0,"window allows both dimensions to resize");
    NSMutableArray*many=[fixtures mutableCopy];for(int i=0;i<7;i++)[many addObject:fixtures[i%2]];app.engine.snapshot=many;
    for(NSNumber*legacy in @[@YES,@NO]){
        app.devicesScroll.scrollerStyle=legacy.boolValue?NSScrollerStyleLegacy:NSScrollerStyleOverlay;
        for(NSValue*size in @[[NSValue valueWithSize:NSMakeSize(560,420)],[NSValue valueWithSize:NSMakeSize(660,330)],[NSValue valueWithSize:NSMakeSize(900,620)],[NSValue valueWithSize:NSMakeSize(1400,700)]]){
            [app.window setContentSize:size.sizeValue];app.devicesSignature=nil;[app refresh];
            CGFloat available=app.devicesScroll.contentSize.width;
            ensure(NSMinY(app.generalHeading.frame)-NSMaxY(app.wirelessGroup.frame)==28,
                   "general settings follow the wireless device list with the standard section gap");
            ensure(app.wirelessGroup.subviews.count==many.count,"all wireless rows remain present after resize");
            for(NSView*v in app.devicesView.subviews)ensure(NSMinX(v.frame)>=0&&NSMaxX(v.frame)<=available+0.5,"card stays within viewport including legacy scrollbar");
            ensure(app.devicesView.frame.size.width<=available+0.5&&!app.devicesScroll.hasHorizontalScroller,"no horizontal document overflow");
            NSUInteger cols=0;for(NSView*v in app.wirelessGroup.subviews)if(NSMinY(v.frame)==0)cols++;
            for(BBDeviceRow*row in app.wirelessGroup.subviews){
                ensure(fabs(row.frame.size.width-app.wirelessGroup.bounds.size.width)<0.5,"each device row fills the list width");
                for(NSView*control in row.subviews)ensure(NSMinX(control.frame)>=0&&NSMaxX(control.frame)<=available,"row content stays inside narrow and wide windows");
            }
            ensure(cols==1,"devices stay in a single list at every window width");
            ensure(app.devicesScroll.frame.size.height==size.sizeValue.height,"whole-page viewport grows with window height");
            CGFloat bottom=app.devicesView.bounds.size.height-app.devicesScroll.contentSize.height;
            [app.devicesScroll.contentView scrollToPoint:NSMakePoint(0,bottom)];[app.devicesScroll reflectScrolledClipView:app.devicesScroll.contentView];
            ensure(NSMaxY(app.settingsGroup.frame)<=NSMaxY(app.devicesScroll.documentVisibleRect),"general settings are reachable by scrolling to the bottom");
            ensure(NSMinY(app.displayHeading.frame)<NSMinY(app.devicesScroll.documentVisibleRect),"display heading scrolls away with the page");
        }
    }
    app.engine.snapshot=fixtures;[app.window setContentSize:NSMakeSize(660,330)];app.devicesSignature=nil;[app refresh];
    NSDictionary*deniedMouse=@{@"name":@"YJX",@"identity":@"test.yjx",@"connected":@YES,@"selectable":@YES,@"status":@"设备访问被拒绝 0xe00002e2"};
    app.engine.snapshot=@[fixtures[1],deniedMouse];app.devicesSignature=nil;[app refresh];
    ensure(!app.authorizeButton.hidden,"a readable keyboard must not hide the mouse permission action");
    BBDeviceRow*deniedCard=[[BBDeviceRow alloc]initWithFrame:NSMakeRect(0,0,640,96) record:deniedMouse];deniedCard.menuTarget=app;
    ensure(deniedCard.refreshButton.enabled&&[deniedCard.refreshButton.toolTip isEqual:@"授权读取此设备电量"],"denied device retains its direct authorization button");
    // Exercise the device-response -> macOS publication path, not just labels.
    uint8_t chargingFrame[]={0xf0,0x30,0xa5,0x95,0x2e,1,1,1,78,1};
    NSDictionary*reading=BBYJXDecode([NSData dataWithBytes:chargingFrame length:sizeof chargingFrame],0xf0);
    NSDictionary*details=BBPowerDetails(@"test.yjx",@"YJX",@"Mouse",reading);
    ensure([details[@"Is Charging"] boolValue]&&![details[@"Is Charged"] boolValue]&&[details[@"Power Source State"] isEqual:@"AC Power"]&&[details[@"Current Capacity"] intValue]==78,"YJX charging response becomes charging AC accessory source");
    NSMutableDictionary*chargingRecord=[@{@"connected":@YES,@"fresh":@YES,@"charging":reading[@"charging"],@"full":reading[@"full"]} mutableCopy];
    ensure([BBChargeStatus(chargingRecord) isEqual:@"正在充电"],"charging shown independently of connection");
    chargingRecord[@"fresh"]=@NO;ensure([BBChargeStatus(chargingRecord) isEqual:@"充电状态未知"],"stale sample cannot claim a current charging state");
    chargingRecord[@"fresh"]=@YES;chargingRecord[@"connected"]=@NO;ensure([BBChargeStatus(chargingRecord) isEqual:@"充电状态未知"],"disconnected receiver cannot claim not charging");
    chargingFrame[8]=100;chargingFrame[9]=0;reading=BBYJXDecode([NSData dataWithBytes:chargingFrame length:sizeof chargingFrame],0xf0);
    details=BBPowerDetails(@"test.yjx",@"YJX",@"Mouse",reading);
    ensure(![details[@"Is Charging"] boolValue]&&[details[@"Is Charged"] boolValue]&&[details[@"Power Source State"] isEqual:@"Battery Power"],"real observed full/not-charging frame has correct macOS flags");
    chargingRecord[@"connected"]=@YES;chargingRecord[@"charging"]=reading[@"charging"];chargingRecord[@"full"]=reading[@"full"];
    ensure([BBChargeStatus(chargingRecord) isEqual:@"未充电 · 已充满"],"full and charging are distinct states");
    NSMutableDictionary*contradictory=[reading mutableCopy];contradictory[@"charging"]=@YES;
    ensure(![BBPowerDetails(@"test.yjx",@"YJX",@"Mouse",contradictory)[@"Is Charged"] boolValue],"macOS never receives charging and charged simultaneously");
    if(argc>1){
        BBPermissionDisplayController *permissionDisplays=[BBPermissionDisplayController new];app.displays=permissionDisplays;[app.displays setValue:@[displayFixture] forKey:@"snapshot"];
        app.engine.snapshot=fixtures;[app.window setContentSize:NSMakeSize(660,600)];app.devicesSignature=nil;[app refresh];
        if(argc>2)app.window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        NSView*root=app.devicesView;
        NSBitmapImageRep*rep=[[NSBitmapImageRep alloc]initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(root.bounds.size.width*2) pixelsHigh:(NSInteger)(root.bounds.size.height*2) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];rep.size=root.bounds.size;
        NSGraphicsContext*ctx=[NSGraphicsContext graphicsContextWithBitmapImageRep:rep];[NSGraphicsContext saveGraphicsState];[NSGraphicsContext setCurrentContext:ctx];[root.effectiveAppearance performAsCurrentDrawingAppearance:^{[NSColor.windowBackgroundColor setFill];NSRectFill(root.bounds);[root displayRectIgnoringOpacity:root.bounds inContext:ctx];}];[NSGraphicsContext restoreGraphicsState];
        NSData*png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];ensure([png writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES],"offscreen preview saved");
    }
    puts("PASS: menu, device list, lifecycle and responsive window checks (8 resize scenarios)");
}}
