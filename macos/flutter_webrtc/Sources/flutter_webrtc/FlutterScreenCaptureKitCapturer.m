#import "FlutterScreenCaptureKitCapturer.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif

@interface FlutterScreenCaptureKitCapturer ()
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
<SCStreamOutput>
#endif
@property(nonatomic, strong) RTCVideoCapturer *capturer;
@property(nonatomic, weak) id<RTCVideoCapturerDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t captureQueue;
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
@property(nonatomic, strong) SCStream *stream API_AVAILABLE(macos(12.3));
@property(nonatomic) CVPixelBufferPoolRef pixelBufferPool API_AVAILABLE(macos(12.3));
@property(nonatomic) size_t poolWidth API_AVAILABLE(macos(12.3));
@property(nonatomic) size_t poolHeight API_AVAILABLE(macos(12.3));
@property(nonatomic) OSType poolPixelFormat API_AVAILABLE(macos(12.3));
#endif
@end

@implementation FlutterScreenCaptureKitCapturer

- (instancetype)initWithDelegate:(id<RTCVideoCapturerDelegate>)delegate {
  self = [super init];
  if (self) {
    _delegate = delegate;
    _capturer = [[RTCVideoCapturer alloc] initWithDelegate:delegate];
    _captureQueue = dispatch_queue_create("com.iperius.sck.capture", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)dealloc {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    [self releasePixelBufferPool];
  }
#endif
}

- (void)startCaptureWithFPS:(NSInteger)fps
                   sourceId:(NSString* _Nullable)sourceId
                   maxWidth:(NSInteger)maxWidth
                  maxHeight:(NSInteger)maxHeight
                  onStarted:(void (^)(NSError * _Nullable error))onStarted {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
      if (error != nil) {
        onStarted(error);
        return;
      }

      SCDisplay *display = [self selectDisplayFromContent:content sourceId:sourceId];
      if (display == nil) {
        NSError *noDisplay = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: @"No matching display"}];
        onStarted(noDisplay);
        return;
      }

      SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
      SCStreamConfiguration *config = [SCStreamConfiguration new];
      // SCDisplay.width/height are in points. Start from the display's pixel
      // size so Retina screens are not halved, then clamp to a sane max so
      // Liquid Retina panels (e.g. 3456x2234) do not overwhelm encode.
      double scale = 1;
      CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display.displayID);
      if (mode != NULL) {
        size_t pointWidth = CGDisplayModeGetWidth(mode);
        if (pointWidth > 0) {
          scale = (double)CGDisplayModeGetPixelWidth(mode) / pointWidth;
        }
        CGDisplayModeRelease(mode);
      }
      size_t fullWidth = (size_t)lround(display.width * scale);
      size_t fullHeight = (size_t)lround(display.height * scale);
      // Match meeting screen-share default: 2560x1600. Callers may override.
      const size_t defaultMaxW = 2560;
      const size_t defaultMaxH = 1600;
      size_t capW = maxWidth > 0 ? (size_t)maxWidth : defaultMaxW;
      size_t capH = maxHeight > 0 ? (size_t)maxHeight : defaultMaxH;
      double down = 1.0;
      if (fullWidth > capW) {
        down = MIN(down, (double)capW / (double)fullWidth);
      }
      if (fullHeight > capH) {
        down = MIN(down, (double)capH / (double)fullHeight);
      }
      size_t outW = (size_t)lround(fullWidth * down);
      size_t outH = (size_t)lround(fullHeight * down);
      // NV12 / WebRTC encoders prefer even dimensions.
      outW -= outW % 2;
      outH -= outH % 2;
      if (outW < 2) outW = 2;
      if (outH < 2) outH = 2;
      config.width = outW;
      config.height = outH;
      if (down < 1.0) {
        NSLog(@"ScreenCaptureKit size clamped %zux%zu -> %zux%zu (cap %zux%zu)",
              fullWidth, fullHeight, outW, outH, capW, capH);
      }
      config.minimumFrameInterval = CMTimeMake(1, (int32_t)MAX(1, fps));
      config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
      // Keep a small SCK surface queue. Downstream WebRTC encoding may hold
      // frames briefly; a deeper queue just delays the stall when buffers are
      // retained. We copy out of the SCK surface in the callback instead.
      config.queueDepth = 3;
      if (@available(macOS 13.0, *)) {
        config.showsCursor = YES;
      }

      self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
      NSError *addOutputError = nil;
      [self.stream addStreamOutput:self
                              type:SCStreamOutputTypeScreen
               sampleHandlerQueue:self.captureQueue
                            error:&addOutputError];
      if (addOutputError != nil) {
        onStarted(addOutputError);
        return;
      }

      [self.stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
        onStarted(startError);
      }];
    }];
    return;
  }
#endif

  NSError *unavailable = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                             code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: @"ScreenCaptureKit not available"}];
  onStarted(unavailable);
}

- (void)stopCaptureWithCompletion:(void (^)(void))completion {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    if (self.stream == nil) {
      [self releasePixelBufferPool];
      completion();
      return;
    }
    SCStream *stream = self.stream;
    self.stream = nil;
    [stream stopCaptureWithCompletionHandler:^(__unused NSError * _Nullable error) {
      dispatch_async(self.captureQueue, ^{
        [self releasePixelBufferPool];
        completion();
      });
    }];
    return;
  }
#endif
  completion();
}

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
- (SCDisplay *)selectDisplayFromContent:(SCShareableContent *)content
                               sourceId:(NSString *)sourceId API_AVAILABLE(macos(12.3)) {
  if (content.displays.count == 0) {
    return nil;
  }

  if (sourceId != nil && sourceId.length > 0) {
    for (SCDisplay *display in content.displays) {
      if ([[NSString stringWithFormat:@"%u", display.displayID] isEqualToString:sourceId]) {
        return display;
      }
    }
  }

  CGDirectDisplayID mainDisplay = CGMainDisplayID();
  for (SCDisplay *display in content.displays) {
    if (display.displayID == mainDisplay) {
      return display;
    }
  }

  return content.displays.firstObject;
}

- (void)releasePixelBufferPool API_AVAILABLE(macos(12.3)) {
  if (_pixelBufferPool != NULL) {
    CVPixelBufferPoolRelease(_pixelBufferPool);
    _pixelBufferPool = NULL;
  }
  _poolWidth = 0;
  _poolHeight = 0;
  _poolPixelFormat = 0;
}

- (BOOL)ensurePixelBufferPoolForWidth:(size_t)width
                               height:(size_t)height
                          pixelFormat:(OSType)pixelFormat API_AVAILABLE(macos(12.3)) {
  if (_pixelBufferPool != NULL && _poolWidth == width && _poolHeight == height &&
      _poolPixelFormat == pixelFormat) {
    return YES;
  }
  [self releasePixelBufferPool];

  NSDictionary *pixelBufferAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(pixelFormat),
    (id)kCVPixelBufferWidthKey : @(width),
    (id)kCVPixelBufferHeightKey : @(height),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  NSDictionary *poolAttributes = @{
    (id)kCVPixelBufferPoolMinimumBufferCountKey : @4,
  };

  CVPixelBufferPoolRef pool = NULL;
  CVReturn rc = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                        (__bridge CFDictionaryRef)poolAttributes,
                                        (__bridge CFDictionaryRef)pixelBufferAttributes,
                                        &pool);
  if (rc != kCVReturnSuccess || pool == NULL) {
    return NO;
  }
  _pixelBufferPool = pool;
  _poolWidth = width;
  _poolHeight = height;
  _poolPixelFormat = pixelFormat;
  return YES;
}

// Copy out of ScreenCaptureKit's IOSurface pool immediately. RTCCVPixelBuffer
// retains the source surface until WebRTC finishes encoding; holding SCK
// surfaces across encode stalls the stream once queueDepth buffers are in
// flight (seen as intermittent first-frame / frozen decode_fps=0).
- (CVPixelBufferRef)copyPixelBuffer:(CVPixelBufferRef)source API_AVAILABLE(macos(12.3)) {
  if (source == NULL) {
    return NULL;
  }
  size_t width = CVPixelBufferGetWidth(source);
  size_t height = CVPixelBufferGetHeight(source);
  OSType pixelFormat = CVPixelBufferGetPixelFormatType(source);
  if (width == 0 || height == 0) {
    return NULL;
  }

  CVPixelBufferRef copy = NULL;
  if ([self ensurePixelBufferPoolForWidth:width height:height pixelFormat:pixelFormat]) {
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool, &copy);
  }
  if (copy == NULL) {
    NSDictionary *attrs = @{
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    CVReturn createRc = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                                            (__bridge CFDictionaryRef)attrs, &copy);
    if (createRc != kCVReturnSuccess || copy == NULL) {
      return NULL;
    }
  }

  CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferLockBaseAddress(copy, 0);
  size_t planeCount = MAX(CVPixelBufferGetPlaneCount(source), (size_t)1);
  BOOL ok = YES;
  if (CVPixelBufferIsPlanar(source)) {
    for (size_t plane = 0; plane < planeCount; plane++) {
      const uint8_t *src = CVPixelBufferGetBaseAddressOfPlane(source, plane);
      uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane);
      if (src == NULL || dst == NULL) {
        ok = NO;
        break;
      }
      size_t srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane);
      size_t dstStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane);
      size_t rows = CVPixelBufferGetHeightOfPlane(source, plane);
      size_t bytes = MIN(srcStride, dstStride);
      for (size_t row = 0; row < rows; row++) {
        memcpy(dst + row * dstStride, src + row * srcStride, bytes);
      }
    }
  } else {
    const uint8_t *src = CVPixelBufferGetBaseAddress(source);
    uint8_t *dst = CVPixelBufferGetBaseAddress(copy);
    if (src == NULL || dst == NULL) {
      ok = NO;
    } else {
      size_t srcStride = CVPixelBufferGetBytesPerRow(source);
      size_t dstStride = CVPixelBufferGetBytesPerRow(copy);
      size_t rows = height;
      size_t bytes = MIN(srcStride, dstStride);
      for (size_t row = 0; row < rows; row++) {
        memcpy(dst + row * dstStride, src + row * srcStride, bytes);
      }
    }
  }
  CVPixelBufferUnlockBaseAddress(copy, 0);
  CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);

  if (!ok) {
    CVPixelBufferRelease(copy);
    return NULL;
  }
  return copy;
}

- (void)stream:(SCStream *)stream
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  if (type != SCStreamOutputTypeScreen) {
    return;
  }
  if (sampleBuffer == NULL || !CMSampleBufferIsValid(sampleBuffer)) {
    return;
  }

  // Only forward real screen updates. Idle/blank/suspended keep reusing the
  // last surface and, when retained by WebRTC, exhaust the SCK buffer pool.
  CFArrayRef attachmentsArray =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false /* createIfNecessary */);
  if (attachmentsArray != NULL && CFArrayGetCount(attachmentsArray) > 0) {
    CFDictionaryRef attachments =
        (CFDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
    CFTypeRef statusRef = CFDictionaryGetValue(attachments, (__bridge CFStringRef)SCStreamFrameInfoStatus);
    if (statusRef != NULL) {
      NSInteger statusValue = 0;
      if (CFGetTypeID(statusRef) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)statusRef, kCFNumberNSIntegerType, &statusValue);
      }
      SCFrameStatus status = (SCFrameStatus)statusValue;
      if (status != SCFrameStatusComplete && status != SCFrameStatusStarted) {
        return;
      }
    }
  }

  CVPixelBufferRef sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (sourceBuffer == nil) {
    return;
  }

  CVPixelBufferRef pixelBuffer = [self copyPixelBuffer:sourceBuffer];
  if (pixelBuffer == NULL) {
    return;
  }

  CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  int64_t timeStampNs = (int64_t)(CMTimeGetSeconds(timestamp) * 1000000000.0);

  id<RTCVideoFrameBuffer> rtcBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
  RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:rtcBuffer
                                                      rotation:RTCVideoRotation_0
                                                   timeStampNs:timeStampNs];
  [self.delegate capturer:self.capturer didCaptureVideoFrame:frame];
  CVPixelBufferRelease(pixelBuffer);
}
#endif

@end
