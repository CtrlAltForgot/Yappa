#ifndef YAPPA_PORTAL_CAPTURE_HXX
#define YAPPA_PORTAL_CAPTURE_HXX

#ifdef __linux__

#include <gio/gio.h>

#include <cstdint>
#include <string>

#include "rtc_video_source.h"

typedef struct _GstAppSink GstAppSink;
typedef struct _GstBus GstBus;
typedef struct _GstElement GstElement;
typedef struct _GstMessage GstMessage;

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

class YappaPortalCapture {
 public:
  YappaPortalCapture();
  ~YappaPortalCapture();

  bool Start(scoped_refptr<RTCVideoSource> source,
             int width,
             int height,
             int frames_per_second,
             std::string* error);
  void Stop();

 private:
  struct PortalResponse {
    bool received = false;
    uint32_t code = 2;
    GVariant* results = nullptr;
  };

  static void OnPortalResponse(GDBusConnection* connection,
                               const gchar* sender_name,
                               const gchar* object_path,
                               const gchar* interface_name,
                               const gchar* signal_name,
                               GVariant* parameters,
                               gpointer user_data);
  static int OnNewSample(GstAppSink* sink, gpointer user_data);
  static gboolean OnBusMessage(GstBus* bus,
                               GstMessage* message,
                               gpointer user_data);

  bool Request(const char* method,
               GVariant* parameters,
               PortalResponse* response,
               std::string* error);
  bool CreatePortalSession(uint32_t* node_id, int* pipewire_fd,
                           std::string* error);
  bool StartPipeline(uint32_t node_id,
                     int pipewire_fd,
                     int width,
                     int height,
                     int frames_per_second,
                     std::string* error);

  GDBusConnection* bus_ = nullptr;
  std::string session_handle_;
  guint response_subscription_ = 0;
  PortalResponse* pending_response_ = nullptr;
  GstElement* pipeline_ = nullptr;
  guint bus_watch_id_ = 0;
  int pipewire_fd_ = -1;
  uint64_t frame_count_ = 0;
  scoped_refptr<RTCVideoSource> source_;
};

}  // namespace flutter_webrtc_plugin

#endif  // __linux__
#endif  // YAPPA_PORTAL_CAPTURE_HXX
