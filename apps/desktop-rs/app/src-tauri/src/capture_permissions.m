#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

// Linked into the app executable so TCC sees RemoteScreen's bundle identity.
int rs_request_capture_permission(int camera) {
    @autoreleasepool {
        AVMediaType type = camera ? AVMediaTypeVideo : AVMediaTypeAudio;
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:type];
        if (status != AVAuthorizationStatusNotDetermined) return (int)status;
        dispatch_semaphore_t ready = dispatch_semaphore_create(0);
        __block BOOL allowed = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [AVCaptureDevice requestAccessForMediaType:type completionHandler:^(BOOL granted) {
                allowed = granted;
                dispatch_semaphore_signal(ready);
            }];
        });
        if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) != 0) {
            return 4;
        }
        return allowed ? AVAuthorizationStatusAuthorized : AVAuthorizationStatusDenied;
    }
}
