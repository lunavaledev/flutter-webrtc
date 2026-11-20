#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

@interface FlutterScreenCaptureKitCapturer : NSObject

- (instancetype)initWithDelegate:(id<RTCVideoCapturerDelegate>)delegate;

// maxWidth/maxHeight clamp the capture size in pixels (0 = use built-in default).
// showCursor: when NO, OS cursor is not composited into captured frames (UU-style).
- (void)startCaptureWithFPS:(NSInteger)fps
                   sourceId:(NSString* _Nullable)sourceId
                   maxWidth:(NSInteger)maxWidth
                  maxHeight:(NSInteger)maxHeight
                 showCursor:(BOOL)showCursor
                  onStarted:(void (^ _Nonnull)(NSError * _Nullable error))onStarted;

- (void)stopCaptureWithCompletion:(void (^ _Nonnull)(void))completion;

@end

NS_ASSUME_NONNULL_END
