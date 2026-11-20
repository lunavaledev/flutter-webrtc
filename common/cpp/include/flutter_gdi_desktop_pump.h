#ifndef FLUTTER_GDI_DESKTOP_PUMP_HXX
#define FLUTTER_GDI_DESKTOP_PUMP_HXX

#if defined(_WIN32)

#include "rtc_types.h"
#include "rtc_video_source.h"

#include <atomic>
#include <cstdint>
#include <vector>

#include <windows.h>

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

class GdiDesktopPump {
 public:
  GdiDesktopPump();
  ~GdiDesktopPump();

  bool Start(scoped_refptr<RTCVideoSource> source, uint32_t fps);
  void Stop();
  bool running() const { return running_.load(); }

 private:
  static DWORD WINAPI ThreadMain(LPVOID self);
  void Loop();
  void ResetGdi();
  bool EnsureGdi(int width, int height);
  bool CaptureBgra(std::vector<uint8_t>* out, int* width, int* height,
                   int* stride);

  std::atomic<bool> running_{false};
  HANDLE thread_ = nullptr;
  scoped_refptr<RTCVideoSource> source_;
  uint32_t delay_ms_ = 33;
  HDC screen_dc_ = nullptr;
  HDC mem_dc_ = nullptr;
  HBITMAP bmp_ = nullptr;
  HGDIOBJ old_bmp_ = nullptr;
  int gdi_w_ = 0;
  int gdi_h_ = 0;
  std::vector<uint8_t> y_;
  std::vector<uint8_t> u_;
  std::vector<uint8_t> v_;
};

}  // namespace flutter_webrtc_plugin

#endif

#endif
