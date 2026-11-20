#import "FlutterWebRTCPlugin.h"

@interface FlutterWebRTCPlugin (HostShm)
- (void)createCustomVideoTrack:(FlutterResult)result;
- (void)startHostShmCapture:(NSString*)trackId result:(FlutterResult)result;
- (void)stopHostShmCapture:(FlutterResult)result;
@end
