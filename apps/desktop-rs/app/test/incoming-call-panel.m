// Compile with clang -fobjc-arc -fblocks -framework AppKit -framework
// Foundation -framework UserNotifications. Runs against the production panel.
#import "../src-tauri/src/notification_bridge.m"

static NSDictionary *lastAction;
static void captureAction(const char *json) {
    lastAction=[NSJSONSerialization JSONObjectWithData:
        [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding]
        options:0 error:nil];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        RSCallPanel *panel=[RSCallPanel new];
        rs_notify_callback=captureAction;
        NSMutableDictionary *call=[@{@"id":@"incoming-test",@"accountId":@"account-test",
            @"peerId":@"friend-test",@"peerName":@"测试好友",@"kind":@"video",
            @"status":@"ringing",@"role":@"callee",
            @"expiresAt":@((NSDate.date.timeIntervalSince1970+45)*1000)} mutableCopy];
        if(argc>2) {
            NSData *avatar=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
            call[@"avatarPng"]=[avatar base64EncodedStringWithOptions:0];
        }
        [panel update:call];
        NSCAssert(panel.panel.visible,@"Unanswered incoming calls stay visible");
        NSCAssert(panel.answer.image && panel.hangup.image,@"Both phone symbols must exist");
        NSCAssert(panel.answer.title.length==0 && panel.hangup.title.length==0,@"Buttons are icons only");
        NSCAssert(panel.answer.frame.size.width==32 && panel.hangup.frame.size.width==32,@"Compact buttons");
        NSCAssert(NSMaxX(panel.hangup.frame)==304 && NSMinY(panel.answer.frame)==12,@"Bottom-right actions");
        if(argc>1) {
            [panel.panel displayIfNeeded];
            NSView *view=panel.panel.contentView;
            NSBitmapImageRep *bitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];
            [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
            [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
        }
        [panel.answer performClick:nil];
        NSCAssert([lastAction[@"action"] isEqual:@"answer"] &&
            [lastAction[@"extra"][@"callId"] isEqual:@"incoming-test"],@"Answer routes the correct call");
        NSCAssert(!panel.answer.enabled && !panel.hangup.enabled,@"Prevent duplicate decisions");
        [panel update:nil];
        NSCAssert(!panel.panel.visible && !panel.call && !panel.pendingUntil,@"Acceptance clears a pending alert immediately");
        [panel update:call];
        [panel.answer performClick:nil];
        call[@"status"]=@"active";
        [panel update:call];
        NSCAssert(!panel.panel.visible && !panel.call,@"An accepted call cannot retain the incoming panel");
        call[@"status"]=@"ended";
        [panel update:call];
        NSCAssert(!panel.panel.visible,@"Ended calls stay hidden");
        call[@"status"]=@"ringing";call[@"role"]=@"caller";
        [panel update:call];
        NSCAssert(!panel.panel.visible,@"Outgoing calls do not show incoming alerts");
        call[@"role"]=@"callee";
        [panel update:call];
        [panel.hangup performClick:nil];
        NSCAssert([lastAction[@"action"] isEqual:@"hangup"],@"Red action routes hangup");
        [panel update:nil];
        call[@"expiresAt"]=@0;
        [panel update:call];
        NSCAssert(!panel.panel.visible && !panel.call,@"Expired alerts close automatically");
        [panel.timer invalidate];
        [panel.panel close];
        puts("Incoming panel lifecycle and actions passed");
    }
    return 0;
}
