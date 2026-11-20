#import "FlutterHostShmCapturer.h"
#import "LocalVideoTrack.h"

#import <WebRTC/WebRTC.h>
#import <QuartzCore/QuartzCore.h>

#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

static const uint32_t kFrameMagic = 0x4D464452;
static const char* kShmName = "/GeekeryRdHostFrames";
static const size_t kHeaderBytes = 32;

@interface FlutterHostShmPump : NSObject
@property(nonatomic, strong) RTCVideoSource* source;
@property(nonatomic, strong) RTCVideoCapturer* capturer;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic) void* view;
@property(nonatomic) int fd;
@property(nonatomic) uint64_t lastSeq;
@end

@implementation FlutterHostShmPump

+ (instancetype)shared {
  static FlutterHostShmPump* pump;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pump = [[FlutterHostShmPump alloc] init];
    pump.fd = -1;
  });
  return pump;
}

- (BOOL)openShm {
  if (self.view) return YES;
  int fd = shm_open(kShmName, O_RDONLY, 0);
  if (fd < 0) return NO;
  struct stat st;
  if (fstat(fd, &st) != 0 || st.st_size < (off_t)kHeaderBytes) {
    close(fd);
    return NO;
  }
  void* view = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
  if (view == MAP_FAILED) {
    close(fd);
    return NO;
  }
  self.fd = fd;
  self.view = view;
  return YES;
}

- (void)closeShm {
  if (self.view && self.view != MAP_FAILED) {
    struct stat st;
    size_t len = kHeaderBytes;
    if (self.fd >= 0 && fstat(self.fd, &st) == 0) len = (size_t)st.st_size;
    munmap(self.view, len);
  }
  if (self.fd >= 0) close(self.fd);
  self.view = NULL;
  self.fd = -1;
}

- (void)tick {
  if (!self.source) return;
  if (![self openShm]) return;
  const uint8_t* base = (const uint8_t*)self.view;
  uint32_t magic = 0, width = 0, height = 0, stride = 0, ready = 0;
  uint64_t seq = 0;
  memcpy(&magic, base + 0, 4);
  memcpy(&width, base + 4, 4);
  memcpy(&height, base + 8, 4);
  memcpy(&stride, base + 12, 4);
  memcpy(&seq, base + 16, 8);
  memcpy(&ready, base + 24, 4);
  if (magic != kFrameMagic || !ready || width == 0 || height == 0 || seq == self.lastSeq) return;
  self.lastSeq = seq;
  size_t nbytes = (size_t)stride * (size_t)height;
  NSDictionary* attrs = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  CVPixelBufferRef pixel = NULL;
  CVReturn rc = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pixel);
  if (rc != kCVReturnSuccess || !pixel) return;
  CVPixelBufferLockBaseAddress(pixel, 0);
  uint8_t* dst = CVPixelBufferGetBaseAddress(pixel);
  size_t dstStride = CVPixelBufferGetBytesPerRow(pixel);
  const uint8_t* src = base + kHeaderBytes;
  for (uint32_t y = 0; y < height; y++) {
    memcpy(dst + y * dstStride, src + y * stride, MIN((size_t)stride, dstStride));
  }
  CVPixelBufferUnlockBaseAddress(pixel, 0);
  RTCCVPixelBuffer* buf = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixel];
  int64_t ts = (int64_t)(CACurrentMediaTime() * 1e9);
  RTCVideoFrame* frame = [[RTCVideoFrame alloc] initWithBuffer:buf rotation:RTCVideoRotation_0 timeStampNs:ts];
  [self.source capturer:self.capturer didCaptureVideoFrame:frame];
  CVPixelBufferRelease(pixel);
}

- (BOOL)startWithSource:(RTCVideoSource*)source {
  [self stop];
  self.source = source;
  self.capturer = [[RTCVideoCapturer alloc] init];
  self.lastSeq = 0;
  dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
  dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)(NSEC_PER_SEC / 30), NSEC_PER_MSEC);
  __weak FlutterHostShmPump* weakSelf = self;
  dispatch_source_set_event_handler(timer, ^{
    [weakSelf tick];
  });
  dispatch_resume(timer);
  self.timer = timer;
  return YES;
}

- (void)stop {
  if (self.timer) {
    dispatch_source_cancel(self.timer);
    self.timer = nil;
  }
  [self closeShm];
  self.source = nil;
  self.capturer = nil;
  self.lastSeq = 0;
}

@end

@implementation FlutterWebRTCPlugin (HostShm)

- (void)createCustomVideoTrack:(FlutterResult)result {
  if (!self.peerConnectionFactory) {
    result([FlutterError errorWithCode:@"createCustomVideoTrack"
                                message:@"factory unavailable"
                                details:nil]);
    return;
  }
  RTCVideoSource* source = [self.peerConnectionFactory videoSource];
  NSString* trackId = [[NSUUID UUID] UUIDString];
  RTCVideoTrack* track = [self.peerConnectionFactory videoTrackWithSource:source trackId:trackId];
  NSString* streamId = [[NSUUID UUID] UUIDString];
  RTCMediaStream* stream = [self.peerConnectionFactory mediaStreamWithStreamId:streamId];
  [stream addVideoTrack:track];
  LocalVideoTrack* local = [[LocalVideoTrack alloc] initWithTrack:track];
  self.localTracks[trackId] = local;
  self.localStreams[streamId] = stream;
  [FlutterHostShmPump shared].source = source;
  result(@{
    @"streamId" : streamId,
    @"videoTracks" : @[ @{
      @"id" : trackId,
      @"label" : trackId,
      @"kind" : @"video",
      @"enabled" : @(track.isEnabled),
      @"remote" : @(NO),
      @"readyState" : @"live",
    } ]
  });
}

- (void)startHostShmCapture:(NSString*)trackId result:(FlutterResult)result {
  id<LocalTrack> local = self.localTracks[trackId];
  if (!local) {
    result([FlutterError errorWithCode:@"startHostShmCapture" message:@"track not found" details:nil]);
    return;
  }
  RTCVideoSource* source = [FlutterHostShmPump shared].source;
  if (!source) {
    result([FlutterError errorWithCode:@"startHostShmCapture" message:@"source missing" details:nil]);
    return;
  }
  [[FlutterHostShmPump shared] startWithSource:source];
  result(@(YES));
}

- (void)stopHostShmCapture:(FlutterResult)result {
  [[FlutterHostShmPump shared] stop];
  result(@(YES));
}

@end
