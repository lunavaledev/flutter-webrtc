#include "flutter_gdi_desktop_pump.h"

#include "rtc_video_frame.h"

#if defined(_WIN32)

namespace flutter_webrtc_plugin {
namespace {

void BgraToI420(const uint8_t* bgra, int width, int height, int stride,
                std::vector<uint8_t>* y_plane, std::vector<uint8_t>* u_plane,
                std::vector<uint8_t>* v_plane) {
  const size_t y_size = static_cast<size_t>(width) * static_cast<size_t>(height);
  const size_t uv_w = static_cast<size_t>((width + 1) / 2);
  const size_t uv_h = static_cast<size_t>((height + 1) / 2);
  y_plane->resize(y_size);
  u_plane->resize(uv_w * uv_h);
  v_plane->resize(uv_w * uv_h);

  uint8_t* yd = y_plane->data();
  uint8_t* ud = u_plane->data();
  uint8_t* vd = v_plane->data();

  for (int j = 0; j < height; j += 2) {
    const int j1 = (j + 1 < height) ? j + 1 : j;
    const uint8_t* row0 = bgra + j * stride;
    const uint8_t* row1 = bgra + j1 * stride;
    uint8_t* yrow0 = yd + j * width;
    uint8_t* yrow1 = yd + j1 * width;
    uint8_t* urow = ud + (j / 2) * static_cast<int>(uv_w);
    uint8_t* vrow = vd + (j / 2) * static_cast<int>(uv_w);

    for (int i = 0; i < width; i += 2) {
      const int i1 = (i + 1 < width) ? i + 1 : i;
      const uint8_t* p00 = row0 + i * 4;
      const uint8_t* p01 = row0 + i1 * 4;
      const uint8_t* p10 = row1 + i * 4;
      const uint8_t* p11 = row1 + i1 * 4;

      const int b00 = p00[0], g00 = p00[1], r00 = p00[2];
      const int b01 = p01[0], g01 = p01[1], r01 = p01[2];
      const int b10 = p10[0], g10 = p10[1], r10 = p10[2];
      const int b11 = p11[0], g11 = p11[1], r11 = p11[2];

      yrow0[i] =
          static_cast<uint8_t>(((66 * r00 + 129 * g00 + 25 * b00 + 128) >> 8) + 16);
      yrow0[i1] =
          static_cast<uint8_t>(((66 * r01 + 129 * g01 + 25 * b01 + 128) >> 8) + 16);
      yrow1[i] =
          static_cast<uint8_t>(((66 * r10 + 129 * g10 + 25 * b10 + 128) >> 8) + 16);
      yrow1[i1] =
          static_cast<uint8_t>(((66 * r11 + 129 * g11 + 25 * b11 + 128) >> 8) + 16);

      const int r = (r00 + r01 + r10 + r11 + 2) >> 2;
      const int g = (g00 + g01 + g10 + g11 + 2) >> 2;
      const int b = (b00 + b01 + b10 + b11 + 2) >> 2;

      urow[i / 2] =
          static_cast<uint8_t>(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
      vrow[i / 2] =
          static_cast<uint8_t>(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
    }
  }

  if (height & 1) {
    const int j = height - 1;
    const uint8_t* row = bgra + j * stride;
    uint8_t* yrow = yd + j * width;
    for (int i = 0; i < width; ++i) {
      const uint8_t* p = row + i * 4;
      yrow[i] =
          static_cast<uint8_t>(((66 * p[2] + 129 * p[1] + 25 * p[0] + 128) >> 8) + 16);
    }
  }
}

}  // namespace

GdiDesktopPump::GdiDesktopPump() = default;

GdiDesktopPump::~GdiDesktopPump() { Stop(); }

void GdiDesktopPump::ResetGdi() {
  if (mem_dc_ && old_bmp_) {
    SelectObject(mem_dc_, old_bmp_);
    old_bmp_ = nullptr;
  }
  if (bmp_) {
    DeleteObject(bmp_);
    bmp_ = nullptr;
  }
  if (mem_dc_) {
    DeleteDC(mem_dc_);
    mem_dc_ = nullptr;
  }
  if (screen_dc_) {
    ReleaseDC(nullptr, screen_dc_);
    screen_dc_ = nullptr;
  }
  gdi_w_ = 0;
  gdi_h_ = 0;
}

bool GdiDesktopPump::EnsureGdi(int width, int height) {
  if (screen_dc_ && mem_dc_ && bmp_ && gdi_w_ == width && gdi_h_ == height) {
    return true;
  }
  ResetGdi();
  screen_dc_ = GetDC(nullptr);
  if (!screen_dc_) return false;
  mem_dc_ = CreateCompatibleDC(screen_dc_);
  if (!mem_dc_) {
    ResetGdi();
    return false;
  }
  bmp_ = CreateCompatibleBitmap(screen_dc_, width, height);
  if (!bmp_) {
    ResetGdi();
    return false;
  }
  old_bmp_ = SelectObject(mem_dc_, bmp_);
  if (!old_bmp_) {
    ResetGdi();
    return false;
  }
  gdi_w_ = width;
  gdi_h_ = height;
  return true;
}

bool GdiDesktopPump::CaptureBgra(std::vector<uint8_t>* out, int* width,
                                 int* height, int* stride) {
  const int w = GetSystemMetrics(SM_CXSCREEN);
  const int h = GetSystemMetrics(SM_CYSCREEN);
  if (w <= 0 || h <= 0) return false;
  if (!EnsureGdi(w, h)) return false;
  if (!BitBlt(mem_dc_, 0, 0, w, h, screen_dc_, 0, 0, SRCCOPY)) {
    ResetGdi();
    return false;
  }

  BITMAPINFOHEADER bi = {};
  bi.biSize = sizeof(bi);
  bi.biWidth = w;
  bi.biHeight = -h;
  bi.biPlanes = 1;
  bi.biBitCount = 32;
  bi.biCompression = BI_RGB;

  out->resize(static_cast<size_t>(w) * static_cast<size_t>(h) * 4);
  if (!GetDIBits(mem_dc_, bmp_, 0, h, out->data(),
                 reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS)) {
    return false;
  }
  *width = w;
  *height = h;
  *stride = w * 4;
  return true;
}

bool GdiDesktopPump::Start(scoped_refptr<RTCVideoSource> source, uint32_t fps) {
  Stop();
  if (!source.get()) return false;
  source_ = source;
  if (fps == 0) fps = 30;
  if (fps > 60) fps = 60;
  delay_ms_ = 1000 / fps;
  if (delay_ms_ == 0) delay_ms_ = 16;
  running_ = true;
  thread_ = CreateThread(nullptr, 0, ThreadMain, this, 0, nullptr);
  if (!thread_) {
    running_ = false;
    source_ = nullptr;
    return false;
  }
  return true;
}

void GdiDesktopPump::Stop() {
  running_ = false;
  if (thread_) {
    WaitForSingleObject(thread_, 3000);
    CloseHandle(thread_);
    thread_ = nullptr;
  }
  ResetGdi();
  source_ = nullptr;
}

DWORD WINAPI GdiDesktopPump::ThreadMain(LPVOID self) {
  static_cast<GdiDesktopPump*>(self)->Loop();
  return 0;
}

void GdiDesktopPump::Loop() {
  std::vector<uint8_t> bgra;
  while (running_.load()) {
    int w = 0;
    int h = 0;
    int stride = 0;
    if (CaptureBgra(&bgra, &w, &h, &stride) && source_.get()) {
      BgraToI420(bgra.data(), w, h, stride, &y_, &u_, &v_);
      auto frame = RTCVideoFrame::Create(w, h, y_.data(), w, u_.data(),
                                         (w + 1) / 2, v_.data(), (w + 1) / 2);
      if (frame.get()) {
        source_->OnCapturedFrame(frame);
      }
    }
    Sleep(delay_ms_);
  }
}

}  // namespace flutter_webrtc_plugin

#endif
