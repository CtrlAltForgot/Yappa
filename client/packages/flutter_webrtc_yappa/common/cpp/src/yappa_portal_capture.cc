#include "yappa_portal_capture.h"

#ifdef __linux__

#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/video.h>

#include <chrono>
#include <sstream>
#include <unistd.h>

#include "rtc_video_frame.h"

namespace flutter_webrtc_plugin {
namespace {

constexpr char kPortalBusName[] = "org.freedesktop.portal.Desktop";
constexpr char kPortalObjectPath[] = "/org/freedesktop/portal/desktop";
constexpr char kScreenCastInterface[] = "org.freedesktop.portal.ScreenCast";

std::string Token(const char* prefix) {
  const auto value = std::chrono::steady_clock::now().time_since_epoch().count();
  return std::string(prefix) + std::to_string(value);
}

GVariant* Options(std::initializer_list<std::pair<const char*, GVariant*>> values) {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE_VARDICT);
  for (const auto& value : values) {
    g_variant_builder_add(&builder, "{sv}", value.first, value.second);
  }
  return g_variant_builder_end(&builder);
}

std::string GErrorMessage(const char* operation, GError* error) {
  std::string message(operation);
  message += ": ";
  message += error != nullptr ? error->message : "unknown portal error";
  return message;
}

}  // namespace

YappaPortalCapture::YappaPortalCapture() {
  gst_init(nullptr, nullptr);
}

YappaPortalCapture::~YappaPortalCapture() {
  Stop();
}

void YappaPortalCapture::OnPortalResponse(
    GDBusConnection*,
    const gchar*,
    const gchar*,
    const gchar*,
    const gchar*,
    GVariant* parameters,
    gpointer user_data) {
  auto* self = static_cast<YappaPortalCapture*>(user_data);
  if (self->pending_response_ == nullptr) {
    return;
  }

  guint32 code = 2;
  GVariant* results = nullptr;
  g_variant_get(parameters, "(u@a{sv})", &code, &results);
  self->pending_response_->code = code;
  self->pending_response_->results = results;
  self->pending_response_->received = true;
}

bool YappaPortalCapture::Request(const char* method,
                                 GVariant* parameters,
                                 PortalResponse* response,
                                 std::string* error) {
  pending_response_ = response;
  GError* call_error = nullptr;
  GVariant* reply = g_dbus_connection_call_sync(
      bus_, kPortalBusName, kPortalObjectPath, kScreenCastInterface, method,
      parameters, G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
      &call_error);
  if (reply == nullptr) {
    pending_response_ = nullptr;
    *error = GErrorMessage(method, call_error);
    g_clear_error(&call_error);
    return false;
  }
  g_variant_unref(reply);

  while (!response->received) {
    g_main_context_iteration(nullptr, true);
  }
  pending_response_ = nullptr;

  if (response->code != 0) {
    *error = response->code == 1 ? "Screen selection was cancelled."
                                 : "The desktop portal rejected screen capture.";
    if (response->results != nullptr) {
      g_variant_unref(response->results);
      response->results = nullptr;
    }
    return false;
  }
  return true;
}

bool YappaPortalCapture::CreatePortalSession(uint32_t* node_id,
                                             int* pipewire_fd,
                                             std::string* error) {
  GError* bus_error = nullptr;
  bus_ = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &bus_error);
  if (bus_ == nullptr) {
    *error = GErrorMessage("Connect to the session bus", bus_error);
    g_clear_error(&bus_error);
    return false;
  }

  response_subscription_ = g_dbus_connection_signal_subscribe(
      bus_, kPortalBusName, "org.freedesktop.portal.Request", "Response",
      nullptr, nullptr, G_DBUS_SIGNAL_FLAGS_NONE, OnPortalResponse, this,
      nullptr);

  PortalResponse create_response;
  const std::string session_token = Token("yappa_session_");
  const std::string request_token = Token("yappa_request_");
  if (!Request(
          "CreateSession",
          g_variant_new("(@a{sv})",
                        Options({{"handle_token",
                                  g_variant_new_string(request_token.c_str())},
                                 {"session_handle_token",
                                  g_variant_new_string(session_token.c_str())}})),
          &create_response, error)) {
    return false;
  }

  GVariant* session_value =
      g_variant_lookup_value(create_response.results, "session_handle",
                             nullptr);
  if (session_value == nullptr) {
    *error = "The desktop portal did not include a capture session handle.";
    g_variant_unref(create_response.results);
    return false;
  }
  if (g_variant_is_of_type(session_value, G_VARIANT_TYPE_VARIANT)) {
    GVariant* unboxed = g_variant_get_variant(session_value);
    g_variant_unref(session_value);
    session_value = unboxed;
  }
  if (!g_variant_is_of_type(session_value, G_VARIANT_TYPE_OBJECT_PATH) &&
      !g_variant_is_of_type(session_value, G_VARIANT_TYPE_STRING)) {
    *error = std::string("The desktop portal returned an unsupported session "
                         "handle type: ") +
             g_variant_get_type_string(session_value);
    g_variant_unref(session_value);
    g_variant_unref(create_response.results);
    return false;
  }
  session_handle_ = g_variant_get_string(session_value, nullptr);
  g_variant_unref(session_value);
  g_variant_unref(create_response.results);

  PortalResponse select_response;
  if (!Request(
          "SelectSources",
          g_variant_new("(o@a{sv})", session_handle_.c_str(),
                        Options({{"handle_token",
                                  g_variant_new_string(Token("yappa_select_").c_str())},
                                 {"types", g_variant_new_uint32(3)},
                                 {"multiple", g_variant_new_boolean(false)},
                                 {"cursor_mode", g_variant_new_uint32(2)},
                                 {"persist_mode", g_variant_new_uint32(2)}})),
          &select_response, error)) {
    return false;
  }
  g_variant_unref(select_response.results);

  PortalResponse start_response;
  if (!Request(
          "Start",
          g_variant_new("(os@a{sv})", session_handle_.c_str(), "",
                        Options({{"handle_token",
                                  g_variant_new_string(Token("yappa_start_").c_str())}})),
          &start_response, error)) {
    return false;
  }

  GVariant* streams =
      g_variant_lookup_value(start_response.results, "streams",
                             G_VARIANT_TYPE("a(ua{sv})"));
  if (streams == nullptr || g_variant_n_children(streams) == 0) {
    *error = "The desktop portal returned no screen stream.";
    if (streams != nullptr) {
      g_variant_unref(streams);
    }
    g_variant_unref(start_response.results);
    return false;
  }
  GVariant* stream = g_variant_get_child_value(streams, 0);
  guint32 selected_node = 0;
  GVariant* stream_properties = nullptr;
  g_variant_get(stream, "(u@a{sv})", &selected_node, &stream_properties);
  *node_id = selected_node;
  g_variant_unref(stream_properties);
  g_variant_unref(stream);
  g_variant_unref(streams);
  g_variant_unref(start_response.results);

  GUnixFDList* fd_list = nullptr;
  GError* fd_error = nullptr;
  GVariant* fd_reply = g_dbus_connection_call_with_unix_fd_list_sync(
      bus_, kPortalBusName, kPortalObjectPath, kScreenCastInterface,
      "OpenPipeWireRemote",
      g_variant_new("(o@a{sv})", session_handle_.c_str(), Options({})),
      G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &fd_list,
      nullptr, &fd_error);
  if (fd_reply == nullptr || fd_list == nullptr) {
    *error = GErrorMessage("Open the PipeWire screen stream", fd_error);
    g_clear_error(&fd_error);
    if (fd_reply != nullptr) {
      g_variant_unref(fd_reply);
    }
    return false;
  }

  gint32 fd_index = -1;
  g_variant_get(fd_reply, "(h)", &fd_index);
  *pipewire_fd = g_unix_fd_list_get(fd_list, fd_index, &fd_error);
  g_variant_unref(fd_reply);
  g_object_unref(fd_list);
  if (*pipewire_fd < 0) {
    *error = GErrorMessage("Read the PipeWire file descriptor", fd_error);
    g_clear_error(&fd_error);
    return false;
  }
  return true;
}

int YappaPortalCapture::OnNewSample(GstAppSink* sink, gpointer user_data) {
  auto* self = static_cast<YappaPortalCapture*>(user_data);
  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (sample == nullptr || self->source_ == nullptr) {
    if (sample != nullptr) {
      gst_sample_unref(sample);
    }
    return GST_FLOW_OK;
  }

  GstCaps* caps = gst_sample_get_caps(sample);
  GstBuffer* buffer = gst_sample_get_buffer(sample);
  GstVideoInfo info;
  GstVideoFrame frame;
  if (caps != nullptr && buffer != nullptr &&
      gst_video_info_from_caps(&info, caps) &&
      gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ)) {
    auto rtc_frame = RTCVideoFrame::Create(
        GST_VIDEO_FRAME_WIDTH(&frame), GST_VIDEO_FRAME_HEIGHT(&frame),
        static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0)),
        GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0),
        static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 1)),
        GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 1),
        static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 2)),
        GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 2));
    self->source_->OnCapturedFrame(rtc_frame);
    self->frame_count_++;
    if (self->frame_count_ == 1 || self->frame_count_ % 300 == 0) {
      g_print("[YappaPortalCapture] delivered %" G_GUINT64_FORMAT
              " video frames\n",
              self->frame_count_);
    }
    gst_video_frame_unmap(&frame);
  }
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

gboolean YappaPortalCapture::OnBusMessage(GstBus*,
                                          GstMessage* message,
                                          gpointer) {
  switch (GST_MESSAGE_TYPE(message)) {
    case GST_MESSAGE_ERROR: {
      GError* error = nullptr;
      gchar* debug = nullptr;
      gst_message_parse_error(message, &error, &debug);
      g_printerr("[YappaPortalCapture] GStreamer error from %s: %s\n",
                 GST_OBJECT_NAME(message->src),
                 error != nullptr ? error->message : "unknown error");
      if (debug != nullptr) {
        g_printerr("[YappaPortalCapture] debug: %s\n", debug);
      }
      g_clear_error(&error);
      g_free(debug);
      break;
    }
    case GST_MESSAGE_EOS:
      g_printerr("[YappaPortalCapture] PipeWire stream reached EOS\n");
      break;
    case GST_MESSAGE_WARNING: {
      GError* error = nullptr;
      gchar* debug = nullptr;
      gst_message_parse_warning(message, &error, &debug);
      g_printerr("[YappaPortalCapture] GStreamer warning from %s: %s\n",
                 GST_OBJECT_NAME(message->src),
                 error != nullptr ? error->message : "unknown warning");
      g_clear_error(&error);
      g_free(debug);
      break;
    }
    default:
      break;
  }
  return G_SOURCE_CONTINUE;
}

bool YappaPortalCapture::StartPipeline(uint32_t node_id,
                                       int pipewire_fd,
                                       int width,
                                       int height,
                                       int frames_per_second,
                                       std::string* error) {
  std::ostringstream pipeline_description;
  pipeline_description
      << "pipewiresrc fd=" << pipewire_fd << " path=" << node_id
      << " do-timestamp=true ! queue max-size-buffers=2 leaky=downstream "
      << "! videoconvert ! videoscale add-borders=true "
      << "! videorate drop-only=true max-rate=" << frames_per_second
      << " ! video/x-raw,format=I420,width=" << width
      << ",height=" << height << ",framerate=" << frames_per_second << "/1 "
      << "! appsink name=yappa_sink emit-signals=true sync=false "
      << "max-buffers=2 drop=true";

  GError* pipeline_error = nullptr;
  pipeline_ = gst_parse_launch(pipeline_description.str().c_str(),
                               &pipeline_error);
  if (pipeline_ == nullptr) {
    *error = GErrorMessage("Create the PipeWire video pipeline",
                           pipeline_error);
    g_clear_error(&pipeline_error);
    close(pipewire_fd);
    return false;
  }

  GstElement* sink = gst_bin_get_by_name(GST_BIN(pipeline_), "yappa_sink");
  g_signal_connect(sink, "new-sample", G_CALLBACK(OnNewSample), this);
  g_object_unref(sink);
  GstBus* bus = gst_element_get_bus(pipeline_);
  bus_watch_id_ = gst_bus_add_watch(bus, OnBusMessage, this);
  gst_object_unref(bus);

  frame_count_ = 0;
  const GstStateChangeReturn state =
      gst_element_set_state(pipeline_, GST_STATE_PLAYING);
  if (state == GST_STATE_CHANGE_FAILURE) {
    close(pipewire_fd);
    *error = "GStreamer could not start the PipeWire screen stream.";
    return false;
  }
  pipewire_fd_ = pipewire_fd;
  return true;
}

bool YappaPortalCapture::Start(scoped_refptr<RTCVideoSource> source,
                               int width,
                               int height,
                               int frames_per_second,
                               std::string* error) {
  Stop();
  source_ = source;
  uint32_t node_id = 0;
  int pipewire_fd = -1;
  if (!CreatePortalSession(&node_id, &pipewire_fd, error)) {
    Stop();
    return false;
  }
  if (!StartPipeline(node_id, pipewire_fd, width, height, frames_per_second,
                     error)) {
    Stop();
    return false;
  }
  return true;
}

void YappaPortalCapture::Stop() {
  if (bus_watch_id_ != 0) {
    g_source_remove(bus_watch_id_);
    bus_watch_id_ = 0;
  }
  if (pipeline_ != nullptr) {
    gst_element_set_state(pipeline_, GST_STATE_NULL);
    gst_object_unref(pipeline_);
    pipeline_ = nullptr;
  }
  if (pipewire_fd_ >= 0) {
    close(pipewire_fd_);
    pipewire_fd_ = -1;
  }
  source_ = nullptr;

  if (bus_ != nullptr && !session_handle_.empty()) {
    g_dbus_connection_call_sync(
        bus_, kPortalBusName, session_handle_.c_str(),
        "org.freedesktop.portal.Session", "Close", nullptr, nullptr,
        G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
  }
  session_handle_.clear();

  if (bus_ != nullptr && response_subscription_ != 0) {
    g_dbus_connection_signal_unsubscribe(bus_, response_subscription_);
    response_subscription_ = 0;
  }
  pending_response_ = nullptr;
  if (bus_ != nullptr) {
    g_object_unref(bus_);
    bus_ = nullptr;
  }
}

}  // namespace flutter_webrtc_plugin

#endif  // __linux__
