#import "FlutterRTCVideoRenderer.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CGColorSpace.h>
#import <CoreGraphics/CGImage.h>
#import <CoreVideo/CoreVideo.h>
#import <stdarg.h>
#import <WebRTC/RTCYUVHelper.h>
#import <WebRTC/RTCYUVPlanarBuffer.h>
#import <WebRTC/WebRTC.h>

#import <objc/runtime.h>

#import "FlutterWebRTCPlugin.h"
#import <os/lock.h>

typedef NS_ENUM(NSInteger, RdYuvRange) {
  RdYuvRangeUnknown = 0,
  RdYuvRangeLimited = 1,
  RdYuvRangeFull = 2,
};

static void RdRendererLog(NSString* format, ...) NS_FORMAT_FUNCTION(1, 2) {
  va_list args;
  va_start(args, format);
  NSString* line = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  NSLog(@"[rd-renderer] %@", line);

  @autoreleasepool {
    NSString* home = NSHomeDirectory();
    if (home.length == 0) {
      return;
    }
    NSString* dir = [home stringByAppendingPathComponent:
                         @"Library/Application Support/cn.geekery.remoteDesktop/logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString* path = [dir stringByAppendingPathComponent:@"renderer_diag.log"];
    NSString* stamped =
        [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    NSData* data = [stamped dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
      [data writeToFile:path atomically:NO];
      return;
    }
    @try {
      [fh seekToEndOfFile];
      [fh writeData:data];
      [fh closeFile];
    } @catch (__unused NSException* e) {
      [fh closeFile];
    }
  }
}

static inline uint8_t RdClampU8(int v) {
  if (v < 0) return 0;
  if (v > 255) return 255;
  return (uint8_t)v;
}

// JPEG/full-range BT.601 style I420 -> BGRA (byte order B,G,R,A).
// Used when sampled Y clearly occupies 0..255 instead of 16..235.
static void RdI420FullToBGRA(const uint8_t* srcY,
                             int strideY,
                             const uint8_t* srcU,
                             int strideU,
                             const uint8_t* srcV,
                             int strideV,
                             uint8_t* dstBGRA,
                             int dstStride,
                             int width,
                             int height) {
  for (int j = 0; j < height; ++j) {
    const uint8_t* yRow = srcY + j * strideY;
    const uint8_t* uRow = srcU + (j / 2) * strideU;
    const uint8_t* vRow = srcV + (j / 2) * strideV;
    uint8_t* dst = dstBGRA + j * dstStride;
    for (int i = 0; i < width; ++i) {
      const int Y = yRow[i];
      const int U = uRow[i / 2] - 128;
      const int V = vRow[i / 2] - 128;
      // Fixed-point approx of full-range BT.601.
      const int R = Y + ((91881 * V + 32768) >> 16);
      const int G = Y - ((22554 * U + 46802 * V + 32768) >> 16);
      const int B = Y + ((116130 * U + 32768) >> 16);
      dst[i * 4 + 0] = RdClampU8(B);
      dst[i * 4 + 1] = RdClampU8(G);
      dst[i * 4 + 2] = RdClampU8(R);
      dst[i * 4 + 3] = 255;
    }
  }
}

static RdYuvRange RdSampleI420Range(id<RTCI420Buffer> buffer,
                                    int* outMinY,
                                    int* outMaxY,
                                    int* outBelow12,
                                    int* outAbove235,
                                    int* outSamples) {
  const int width = buffer.width;
  const int height = buffer.height;
  if (width <= 0 || height <= 0) {
    return RdYuvRangeUnknown;
  }
  const uint8_t* yPlane = buffer.dataY;
  const int strideY = buffer.strideY;
  int minY = 255;
  int maxY = 0;
  int below12 = 0;
  int above235 = 0;
  int samples = 0;
  // ~32x32 grid across the frame keeps this cheap on the render thread.
  const int stepX = MAX(1, width / 32);
  const int stepY = MAX(1, height / 32);
  for (int j = 0; j < height; j += stepY) {
    const uint8_t* row = yPlane + j * strideY;
    for (int i = 0; i < width; i += stepX) {
      const int y = row[i];
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      if (y < 12) ++below12;
      if (y > 235) ++above235;
      ++samples;
    }
  }
  if (outMinY) *outMinY = minY;
  if (outMaxY) *outMaxY = maxY;
  if (outBelow12) *outBelow12 = below12;
  if (outAbove235) *outAbove235 = above235;
  if (outSamples) *outSamples = samples;
  if (samples <= 0) {
    return RdYuvRangeUnknown;
  }
  // Two strong full-range signals for desktop remoting:
  // 1) Y population below the limited pedestal (true blacks in 0..11)
  // 2) Y population above limited white (236..255). Hardware H.264 decode on
  //    Apple often expands limited bitstreams to full-range I420; feeding that
  //    into limited I420ToARGB applies the pedestal removal twice and crushes
  //    dark UI grays to near-black. above235 is the reliable tell when the
  //    scene has no true blacks (common on dark themes).
  if (below12 * 100 >= samples) {  // >= 1%
    return RdYuvRangeFull;
  }
  if (above235 * 100 >= samples) {  // >= 1%
    return RdYuvRangeFull;
  }
  if (maxY >= 250) {
    return RdYuvRangeFull;
  }
  return RdYuvRangeLimited;
}

static void RdAttachSRGBColorSpace(CVPixelBufferRef pixelBuffer) {
  if (!pixelBuffer) {
    return;
  }
  // Output is already converted BGRA (display-referred RGB). Only tag sRGB.
  // Do NOT attach YCbCr matrix / BT.709 transfer — those belong on YUV buffers
  // and can make Flutter/CoreImage treat RGB as video and crush mid-grays.
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  if (!space) {
    space = CGColorSpaceCreateDeviceRGB();
  }
  if (!space) {
    return;
  }
  CVBufferSetAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey, space,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey);
  CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey);
  CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey);
  CGColorSpaceRelease(space);
}

// Sample decoded BGRA (byte order B,G,R,A) so we can tell crush-before-RGB
// (Y already low) from crush-after-RGB (display pipeline).
static void RdSampleBGRA(const uint8_t* bgra,
                         int stride,
                         int width,
                         int height,
                         int* outMin,
                         int* outMax,
                         int* outBelow16,
                         int* outBelow32,
                         int* outSamples) {
  int minV = 255;
  int maxV = 0;
  int below16 = 0;
  int below32 = 0;
  int samples = 0;
  if (!bgra || width <= 0 || height <= 0) {
    if (outMin) *outMin = 0;
    if (outMax) *outMax = 0;
    if (outBelow16) *outBelow16 = 0;
    if (outBelow32) *outBelow32 = 0;
    if (outSamples) *outSamples = 0;
    return;
  }
  const int stepX = MAX(1, width / 32);
  const int stepY = MAX(1, height / 32);
  for (int j = 0; j < height; j += stepY) {
    const uint8_t* row = bgra + j * stride;
    for (int i = 0; i < width; i += stepX) {
      const uint8_t* px = row + i * 4;
      // luma proxy on RGB channels (already decoded)
      const int v = (px[0] + px[1] + px[2]) / 3;
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
      if (v < 16) ++below16;
      if (v < 32) ++below32;
      ++samples;
    }
  }
  if (outMin) *outMin = minV;
  if (outMax) *outMax = maxV;
  if (outBelow16) *outBelow16 = below16;
  if (outBelow32) *outBelow32 = below32;
  if (outSamples) *outSamples = samples;
}

@implementation FlutterRTCVideoRenderer {
  CGSize _frameSize;
  CGSize _renderSize;
  CVPixelBufferRef _pixelBufferRef;
  RTCVideoRotation _rotation;
  FlutterEventChannel* _eventChannel;
  bool _isFirstFrameRendered;
  bool _frameAvailable;
  os_unfair_lock _lock;
  RdYuvRange _yuvRange;
  int _diagFramesLeft;
  int _bgraDiagLeft;
}

@synthesize textureId = _textureId;
@synthesize registry = _registry;
@synthesize eventSink = _eventSink;
@synthesize videoTrack = _videoTrack;

- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                              messenger:(NSObject<FlutterBinaryMessenger>*)messenger {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _isFirstFrameRendered = false;
    _frameAvailable = false;
    _frameSize = CGSizeZero;
    _renderSize = CGSizeZero;
    _rotation = -1;
    _registry = registry;
    _pixelBufferRef = nil;
    _eventSink = nil;
    _rotation = -1;
    _yuvRange = RdYuvRangeUnknown;
    _diagFramesLeft = 8;
    _bgraDiagLeft = 8;
    _textureId = [registry registerTexture:self];
    /*Create Event Channel.*/
    _eventChannel = [FlutterEventChannel
        eventChannelWithName:[NSString stringWithFormat:@"FlutterWebRTC/Texture%lld", _textureId]
             binaryMessenger:messenger];
    [_eventChannel setStreamHandler:self];
  }
  return self;
}

- (CVPixelBufferRef)copyPixelBuffer {
  CVPixelBufferRef buffer = nil;
  os_unfair_lock_lock(&_lock);
  if (_pixelBufferRef != nil && _frameAvailable) {
    buffer = CVBufferRetain(_pixelBufferRef);
    _frameAvailable = false;
  }
  os_unfair_lock_unlock(&_lock);
  return buffer;
}

- (void)dispose {
  [_eventChannel setStreamHandler:nil];
  _eventChannel = nil;
  os_unfair_lock_lock(&_lock);
  [_registry unregisterTexture:_textureId];
  _textureId = -1;
  if (_pixelBufferRef) {
    CVBufferRelease(_pixelBufferRef);
    _pixelBufferRef = nil;
  }
  _frameAvailable = false;
  os_unfair_lock_unlock(&_lock);
}

- (void)setVideoTrack:(RTCVideoTrack*)videoTrack {
  RTCVideoTrack* oldValue = self.videoTrack;
  if (oldValue != videoTrack) {
    os_unfair_lock_lock(&_lock);
    _videoTrack = videoTrack;
    os_unfair_lock_unlock(&_lock);
    _isFirstFrameRendered = false;
    if (oldValue) {
      [oldValue removeRenderer:self];
    }
    _frameSize = CGSizeZero;
    _renderSize = CGSizeZero;
    _rotation = -1;
    _yuvRange = RdYuvRangeUnknown;
    _diagFramesLeft = 8;
    _bgraDiagLeft = 8;
    if (videoTrack) {
      [videoTrack addRenderer:self];
    }
  }
}

- (id<RTCI420Buffer>)correctRotation:(const id<RTCI420Buffer>)src
                        withRotation:(RTCVideoRotation)rotation {
  int rotated_width = src.width;
  int rotated_height = src.height;

  if (rotation == RTCVideoRotation_90 || rotation == RTCVideoRotation_270) {
    int temp = rotated_width;
    rotated_width = rotated_height;
    rotated_height = temp;
  }

  id<RTCI420Buffer> buffer = [[RTCI420Buffer alloc] initWithWidth:rotated_width
                                                           height:rotated_height];

  [RTCYUVHelper I420Rotate:src.dataY
                srcStrideY:src.strideY
                      srcU:src.dataU
                srcStrideU:src.strideU
                      srcV:src.dataV
                srcStrideV:src.strideV
                      dstY:(uint8_t*)buffer.dataY
                dstStrideY:buffer.strideY
                      dstU:(uint8_t*)buffer.dataU
                dstStrideU:buffer.strideU
                      dstV:(uint8_t*)buffer.dataV
                dstStrideV:buffer.strideV
                     width:src.width
                    height:src.height
                      mode:rotation];

  return buffer;
}

- (void)copyI420ToCVPixelBuffer:(CVPixelBufferRef)outputPixelBuffer
                      withFrame:(RTCVideoFrame*)frame {
  id<RTCI420Buffer> i420Buffer = [self correctRotation:[frame.buffer toI420]
                                          withRotation:frame.rotation];

  // Sample a sparse Y grid once (then a few more times for logging) so we can
  // detect full-range desktop frames that would be crushed by limited I420ToARGB.
  if (_yuvRange == RdYuvRangeUnknown || _diagFramesLeft > 0) {
    int minY = 0, maxY = 0, below12 = 0, above235 = 0, samples = 0;
    RdYuvRange sampled = RdSampleI420Range(i420Buffer, &minY, &maxY, &below12,
                                           &above235, &samples);
    if (_yuvRange == RdYuvRangeUnknown && sampled != RdYuvRangeUnknown) {
      _yuvRange = sampled;
    }
    if (_diagFramesLeft > 0) {
      --_diagFramesLeft;
      RdRendererLog(
          @"yuv-range sample=%@ decided=%@ minY=%d maxY=%d below12=%d above235=%d "
           @"samples=%d size=%dx%d",
          sampled == RdYuvRangeFull
              ? @"full"
              : (sampled == RdYuvRangeLimited ? @"limited" : @"unknown"),
          _yuvRange == RdYuvRangeFull
              ? @"full"
              : (_yuvRange == RdYuvRangeLimited ? @"limited" : @"unknown"),
          minY, maxY, below12, above235, samples, i420Buffer.width,
          i420Buffer.height);
    }
  }

  CVPixelBufferLockBaseAddress(outputPixelBuffer, 0);

  const OSType pixelFormat = CVPixelBufferGetPixelFormatType(outputPixelBuffer);
  if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    // NV12
    uint8_t* dstY = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 0);
    const size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0);
    uint8_t* dstUV = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 1);
    const size_t dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 1);

    [RTCYUVHelper I420ToNV12:i420Buffer.dataY
                  srcStrideY:i420Buffer.strideY
                        srcU:i420Buffer.dataU
                  srcStrideU:i420Buffer.strideU
                        srcV:i420Buffer.dataV
                  srcStrideV:i420Buffer.strideV
                        dstY:dstY
                  dstStrideY:(int)dstYStride
                       dstUV:dstUV
                 dstStrideUV:(int)dstUVStride
                       width:i420Buffer.width
                      height:i420Buffer.height];

  } else {
    uint8_t* dst = CVPixelBufferGetBaseAddress(outputPixelBuffer);
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer);

    if (pixelFormat == kCVPixelFormatType_32BGRA) {
      if (_yuvRange == RdYuvRangeFull) {
        // Full-range I420 -> BGRA. Avoid limited I420ToARGB crushing near-black
        // desktop grays into pure black.
        RdI420FullToBGRA(i420Buffer.dataY, i420Buffer.strideY, i420Buffer.dataU,
                         i420Buffer.strideU, i420Buffer.dataV, i420Buffer.strideV,
                         dst, (int)bytesPerRow, i420Buffer.width,
                         i420Buffer.height);
      } else {
        // Corresponds to libyuv::FOURCC_ARGB (limited-range).
        [RTCYUVHelper I420ToARGB:i420Buffer.dataY
                      srcStrideY:i420Buffer.strideY
                            srcU:i420Buffer.dataU
                      srcStrideU:i420Buffer.strideU
                            srcV:i420Buffer.dataV
                      srcStrideV:i420Buffer.strideV
                         dstARGB:dst
                   dstStrideARGB:(int)bytesPerRow
                           width:i420Buffer.width
                          height:i420Buffer.height];
      }
      if (_bgraDiagLeft > 0) {
        --_bgraDiagLeft;
        // Log after convert: if RGB midtones exist here but look black on
        // screen, the crush is in Flutter texture / color management.
        int rgbMin = 0, rgbMax = 0, b16 = 0, b32 = 0, n = 0;
        RdSampleBGRA(dst, (int)bytesPerRow, i420Buffer.width, i420Buffer.height,
                     &rgbMin, &rgbMax, &b16, &b32, &n);
        RdRendererLog(@"bgra-after-convert range=%@ rgbMin=%d rgbMax=%d "
                       @"below16=%d below32=%d samples=%d",
                      _yuvRange == RdYuvRangeFull ? @"full" : @"limited",
                      rgbMin, rgbMax, b16, b32, n);
      }

    } else if (pixelFormat == kCVPixelFormatType_32ARGB) {
      // Corresponds to libyuv::FOURCC_BGRA
      [RTCYUVHelper I420ToBGRA:i420Buffer.dataY
                    srcStrideY:i420Buffer.strideY
                          srcU:i420Buffer.dataU
                    srcStrideU:i420Buffer.strideU
                          srcV:i420Buffer.dataV
                    srcStrideV:i420Buffer.strideV
                       dstBGRA:dst
                 dstStrideBGRA:(int)bytesPerRow
                         width:i420Buffer.width
                        height:i420Buffer.height];
    }
  }

  CVPixelBufferUnlockBaseAddress(outputPixelBuffer, 0);
}

#pragma mark - RTCVideoRenderer methods
- (void)renderFrame:(RTCVideoFrame*)frame {

  os_unfair_lock_lock(&_lock);
  if(_videoTrack == nil) {
    os_unfair_lock_unlock(&_lock);
    return;
  }
  if(!_frameAvailable && _pixelBufferRef) {
    [self copyI420ToCVPixelBuffer:_pixelBufferRef withFrame:frame];
    if(_textureId != -1) {
      [_registry textureFrameAvailable:_textureId];
    }
    _frameAvailable = true;
  }
  os_unfair_lock_unlock(&_lock);

  // Frames arrive on a decoder thread and this block runs later on the main
  // queue, so the renderer may already have been disposed and freed by the
  // time it runs. The weak reference is then nil and must not be dereferenced.
  __weak FlutterRTCVideoRenderer* weakSelf = self;
  if (_renderSize.width != frame.width || _renderSize.height != frame.height) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer* strongSelf = weakSelf;
      if (strongSelf != nil && strongSelf.eventSink) {
        strongSelf.eventSink(@{
          @"event" : @"didTextureChangeVideoSize",
          @"id" : @(strongSelf.textureId),
          @"width" : @(frame.width),
          @"height" : @(frame.height),
        });
      }
    });
    _renderSize = CGSizeMake(frame.width, frame.height);
  }

  if (frame.rotation != _rotation) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer* strongSelf = weakSelf;
      if (strongSelf != nil && strongSelf.eventSink) {
        strongSelf.eventSink(@{
          @"event" : @"didTextureChangeRotation",
          @"id" : @(strongSelf.textureId),
          @"rotation" : @(frame.rotation),
        });
      }
    });

    _rotation = frame.rotation;
  }

  // Notify Flutter once the first frame has been rendered.
  if (!_isFirstFrameRendered) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer* strongSelf = weakSelf;
      if (strongSelf == nil || strongSelf->_isFirstFrameRendered) {
        return;
      }
      if (strongSelf.eventSink) {
        strongSelf.eventSink(@{@"event" : @"didFirstFrameRendered"});
        strongSelf->_isFirstFrameRendered = true;
      }
    });
  }
}

/**
 * Sets the size of the video frame to render.
 *
 * @param size The size of the video frame to render.
 */
- (void)setSize:(CGSize)size {
  os_unfair_lock_lock(&_lock);
  if (size.width != _frameSize.width || size.height != _frameSize.height) {
    if (_pixelBufferRef) {
      CVBufferRelease(_pixelBufferRef);
    }
    NSDictionary* pixelAttributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)(pixelAttributes), &_pixelBufferRef);
    RdAttachSRGBColorSpace(_pixelBufferRef);
    _frameAvailable = false;
    _frameSize = size;
    RdRendererLog(@"pixel-buffer created %dx%d with sRGB attachments", (int)size.width,
                  (int)size.height);
  }
  os_unfair_lock_unlock(&_lock);
}

#pragma mark - FlutterStreamHandler methods

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)sink {
  _eventSink = sink;
  return nil;
}
@end

@implementation FlutterWebRTCPlugin (FlutterVideoRendererManager)

- (FlutterRTCVideoRenderer*)createWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                                            messenger:(NSObject<FlutterBinaryMessenger>*)messenger {
  return [[FlutterRTCVideoRenderer alloc] initWithTextureRegistry:registry messenger:messenger];
}

- (void)rendererSetSrcObject:(FlutterRTCVideoRenderer*)renderer stream:(RTCVideoTrack*)videoTrack {
  renderer.videoTrack = videoTrack;
}
@end
