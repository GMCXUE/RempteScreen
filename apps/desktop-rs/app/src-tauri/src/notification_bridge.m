#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

static void (*rs_notify_callback)(const char *);
static void report(NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if(data && rs_notify_callback) rs_notify_callback([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
static void status(void) {
    [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *s) {
        report(@{@"type":@"permission",@"authorization":@(s.authorizationStatus),@"alerts":@(s.alertSetting),@"sounds":@(s.soundSetting)});
    }];
}
@interface RSNotificationDelegate : NSObject<UNUserNotificationCenterDelegate>
@end
@implementation RSNotificationDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completion {
    completion(UNNotificationPresentationOptionBanner|UNNotificationPresentationOptionList|UNNotificationPresentationOptionSound);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completion {
    NSString *action=[response.actionIdentifier isEqual:UNNotificationDefaultActionIdentifier]?@"tap":response.actionIdentifier;
    report(@{@"type":@"action",@"action":action,@"extra":response.notification.request.content.userInfo});completion();
}
@end
static RSNotificationDelegate *rs_delegate;
void rs_notifications_init(void (*callback)(const char *)) {
    rs_notify_callback=callback;
    dispatch_async(dispatch_get_main_queue(),^{
        UNUserNotificationCenter *center=[UNUserNotificationCenter currentNotificationCenter];
        rs_delegate=[RSNotificationDelegate new];center.delegate=rs_delegate;
        UNNotificationAction *answer=[UNNotificationAction actionWithIdentifier:@"answer" title:@"接通" options:UNNotificationActionOptionForeground];
        UNNotificationAction *reject=[UNNotificationAction actionWithIdentifier:@"reject" title:@"挂断" options:UNNotificationActionOptionForeground];
        [center setNotificationCategories:[NSSet setWithObject:[UNNotificationCategory categoryWithIdentifier:@"friend-call" actions:@[answer,reject] intentIdentifiers:@[] options:UNNotificationCategoryOptionNone]]];
        [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert|UNAuthorizationOptionSound|UNAuthorizationOptionBadge completionHandler:^(BOOL granted,NSError *error){
            if(error)report(@{@"type":@"error",@"error":error.localizedDescription});status();
        }];
    });
}
void rs_notifications_status(void) {status();}
void rs_notifications_post(const char *json) {
    NSString *value=[NSString stringWithUTF8String:json];
    dispatch_async(dispatch_get_main_queue(),^{
        NSDictionary *data=[NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if(!data)return;
        UNMutableNotificationContent *content=[UNMutableNotificationContent new];
        content.title=data[@"title"]?:@"RemoteScreen";content.body=data[@"body"]?:@"";content.userInfo=data[@"extra"]?:@{};
        content.categoryIdentifier=data[@"category"]?:@"";
        content.threadIdentifier=data[@"thread"]?:@"";
        if([data[@"sound"] boolValue])content.sound=[UNNotificationSound defaultSound];
        NSString *identifier=data[@"id"]?:NSUUID.UUID.UUIDString;
        UNNotificationRequest *request=[UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError *error){
            report(@{@"type":@"delivery",@"id":identifier,@"error":error.localizedDescription?:@""});
        }];
    });
}
void rs_notifications_remove(const char *identifier) {
    NSString *value=[NSString stringWithUTF8String:identifier];
    [[UNUserNotificationCenter currentNotificationCenter] removeDeliveredNotificationsWithIdentifiers:@[value]];
    [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[value]];
}

// A system banner's lifetime and button colors belong to macOS. Keep the call
// controls in our own nonactivating panel instead, independent of the webview.
#import <AppKit/AppKit.h>
@interface RSCallPanel : NSObject
@property(nonatomic, strong) NSPanel *panel;
@property(nonatomic, strong) NSTextField *nameLabel;
@property(nonatomic, strong) NSImageView *avatar;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *answer;
@property(nonatomic, strong) NSButton *hangup;
@property(nonatomic, strong) NSDictionary *call;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSDate *pendingUntil;
@property(nonatomic) BOOL awaitingAnswer;
@end
@implementation RSCallPanel
- (NSTextField *)label:(NSRect)frame size:(CGFloat)size bold:(BOOL)bold {
    NSTextField *label=[NSTextField labelWithString:@""];label.frame=frame;
    label.font=bold?[NSFont boldSystemFontOfSize:size]:[NSFont systemFontOfSize:size];
    label.lineBreakMode=NSLineBreakByTruncatingTail;[self.panel.contentView addSubview:label];return label;
}
- (NSButton *)button:(NSRect)frame symbol:(NSString *)symbol label:(NSString *)label color:(NSColor *)color action:(SEL)action {
    NSButton *button=[[NSButton alloc] initWithFrame:frame];button.title=@"";
    button.image=[[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightSemibold]];
    button.imagePosition=NSImageOnly;button.toolTip=label;button.accessibilityLabel=label;
    button.bordered=NO;button.wantsLayer=YES;button.layer.backgroundColor=color.CGColor;button.layer.cornerRadius=frame.size.height/2;
    button.contentTintColor=NSColor.whiteColor;
    button.target=self;button.action=action;[self.panel.contentView addSubview:button];return button;
}
- (instancetype)init {
    if((self=[super init])) {
        self.panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,320,108) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        self.panel.level=NSFloatingWindowLevel;self.panel.hidesOnDeactivate=NO;self.panel.releasedWhenClosed=NO;
        self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
        self.panel.opaque=NO;self.panel.backgroundColor=NSColor.clearColor;self.panel.hasShadow=YES;self.panel.movableByWindowBackground=YES;
        self.panel.accessibilityLabel=@"RemoteScreen 来电";
        NSVisualEffectView *surface=[[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0,0,320,108)];
        surface.material=NSVisualEffectMaterialPopover;surface.state=NSVisualEffectStateActive;surface.wantsLayer=YES;surface.layer.cornerRadius=18;surface.layer.masksToBounds=YES;
        self.panel.contentView=surface;
        self.avatar=[[NSImageView alloc] initWithFrame:NSMakeRect(16,52,40,40)];
        self.avatar.imageScaling=NSImageScaleProportionallyUpOrDown;self.avatar.wantsLayer=YES;
        self.avatar.layer.cornerRadius=12;self.avatar.layer.masksToBounds=YES;[surface addSubview:self.avatar];
        self.nameLabel=[self label:NSMakeRect(68,75,236,20) size:15 bold:YES];
        self.statusLabel=[self label:NSMakeRect(68,53,236,18) size:12 bold:NO];self.statusLabel.textColor=NSColor.secondaryLabelColor;
        self.answer=[self button:NSMakeRect(228,12,32,32) symbol:@"phone.fill" label:@"接通" color:[NSColor colorWithRed:0.13 green:0.65 blue:0.48 alpha:1] action:@selector(accept:)];
        self.hangup=[self button:NSMakeRect(272,12,32,32) symbol:@"phone.down.fill" label:@"挂断" color:[NSColor colorWithRed:0.89 green:0.36 blue:0.39 alpha:1] action:@selector(end:)];
        self.timer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    }return self;
}
- (void)accept:(id)sender {[self send:@"answer"];}
- (void)end:(id)sender {[self send:@"hangup"];}
- (void)send:(NSString *)action {
    if(!self.call || self.pendingUntil)return;
    NSDictionary *extra=@{@"kind":@"call",@"accountId":self.call[@"accountId"]?:@"",@"peerId":self.call[@"peerId"]?:@"",@"callId":self.call[@"id"]?:@""};
    self.awaitingAnswer=[action isEqual:@"answer"];
    self.pendingUntil=[NSDate dateWithTimeIntervalSinceNow:8];self.answer.enabled=NO;self.hangup.enabled=NO;
    [self tick:nil];
    report(@{@"type":@"action",@"action":action,@"extra":extra});
}
- (void)tick:(NSTimer *)timer {
    if(!self.call)return;
    double now=NSDate.date.timeIntervalSince1970*1000;
    if([self.call[@"expiresAt"] doubleValue]<=now) {[self update:nil];return;}
    if(self.pendingUntil && [self.pendingUntil timeIntervalSinceNow]<=0) {
        self.pendingUntil=nil;
        if(self.awaitingAnswer){self.awaitingAnswer=NO;[self update:nil];return;}
    }
    self.answer.enabled=!self.pendingUntil;
    self.hangup.enabled=!self.pendingUntil;
    NSString *kind=[self.call[@"kind"] isEqual:@"video"]?@"视频":@"语音";
    self.statusLabel.stringValue=self.awaitingAnswer?@"正在接通…":[NSString stringWithFormat:@"%@来电",kind];
}
- (void)update:(NSDictionary *)call {
    // This panel is only an incoming alert; active controls live in the call UI.
    if(![call[@"status"] isEqual:@"ringing"] || ![call[@"role"] isEqual:@"callee"])call=nil;
    BOOL changed=![self.call[@"id"] isEqual:call[@"id"]]||![self.call[@"status"] isEqual:call[@"status"]];
    if(changed){self.pendingUntil=nil;self.awaitingAnswer=NO;}
    self.call=call;
    if(!call){[self.panel orderOut:nil];return;}
    self.nameLabel.stringValue=call[@"peerName"]?:@"好友";
    NSData *avatarData=[[NSData alloc] initWithBase64EncodedString:call[@"avatarPng"]?:@"" options:0];
    self.avatar.image=avatarData?[[NSImage alloc] initWithData:avatarData]:nil;
    [self tick:nil];if(!self.call)return;
    if(!self.panel.visible) {
        NSScreen *screen=NSScreen.mainScreen?:NSScreen.screens.firstObject;
        NSRect frame=screen.visibleFrame;[self.panel setFrameTopLeftPoint:NSMakePoint(NSMaxX(frame)-self.panel.frame.size.width-20,NSMaxY(frame)-20)];
        [self.panel orderFrontRegardless];
    }
}
@end
static RSCallPanel *rs_call_panel;
void rs_call_panel_update(const char *json) {
    NSString *value=[NSString stringWithUTF8String:json];
    dispatch_async(dispatch_get_main_queue(),^{
        id data=[NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:nil];
        if(!rs_call_panel)rs_call_panel=[RSCallPanel new];
        [rs_call_panel update:[data isKindOfClass:NSDictionary.class]?data:nil];
    });
}

void rs_call_panel_dismiss(const char *identifier) {
    NSString *value=[NSString stringWithUTF8String:identifier];
    dispatch_async(dispatch_get_main_queue(),^{
        if([rs_call_panel.call[@"id"] isEqual:value]) {
            rs_call_panel.awaitingAnswer=NO;rs_call_panel.pendingUntil=nil;[rs_call_panel update:nil];
        }
    });
}

void rs_call_panel_prepare_answer(const char *identifier) {
    NSString *value=[NSString stringWithUTF8String:identifier];
    dispatch_async(dispatch_get_main_queue(),^{
        if([rs_call_panel.call[@"id"] isEqual:value] && [rs_call_panel.call[@"status"] isEqual:@"ringing"]) {
            rs_call_panel.awaitingAnswer=YES;rs_call_panel.pendingUntil=[NSDate dateWithTimeIntervalSinceNow:8];[rs_call_panel tick:nil];
        }
    });
}
