#include "loopback_capturer.h"

#include <gst/app/gstappsink.h>
#include <gst/gst.h>

#include <atomic>
#include <iostream>

namespace flutter_webrtc_plugin {

namespace {

class LinuxLoopbackCapturer final : public LoopbackCapturer {
 public:
  ~LinuxLoopbackCapturer() override { Stop(); }

  bool Start(scoped_refptr<RTCAudioSource> source) override {
    Stop();
    gst_init(nullptr, nullptr);
    source_ = source;

    const char* description =
        "pulsesrc device=@DEFAULT_MONITOR@ do-timestamp=true "
        "buffer-time=20000 latency-time=10000 ! "
        "queue max-size-time=200000000 leaky=downstream ! "
        "audioconvert ! audioresample ! "
        "audio/x-raw,format=S16LE,rate=48000,channels=2,layout=interleaved ! "
        "appsink name=yappa_audio_sink emit-signals=true sync=false "
        "max-buffers=8 drop=true";

    GError* error = nullptr;
    pipeline_ = gst_parse_launch(description, &error);
    if (pipeline_ == nullptr) {
      std::cerr << "[YappaLoopback] Could not create audio pipeline: "
                << (error != nullptr ? error->message : "unknown error")
                << std::endl;
      g_clear_error(&error);
      source_ = nullptr;
      return false;
    }

    GstElement* sink =
        gst_bin_get_by_name(GST_BIN(pipeline_), "yappa_audio_sink");
    if (sink == nullptr) {
      std::cerr << "[YappaLoopback] Audio appsink was not created."
                << std::endl;
      Stop();
      return false;
    }

    g_signal_connect(sink, "new-sample", G_CALLBACK(OnNewSample), this);
    gst_object_unref(sink);
    running_ = true;

    if (gst_element_set_state(pipeline_, GST_STATE_PLAYING) ==
        GST_STATE_CHANGE_FAILURE) {
      std::cerr << "[YappaLoopback] Could not start default output monitor."
                << std::endl;
      Stop();
      return false;
    }

    std::cout << "[YappaLoopback] Capturing the default system output monitor."
              << std::endl;
    return true;
  }

  void Stop() override {
    running_ = false;
    if (pipeline_ != nullptr) {
      gst_element_set_state(pipeline_, GST_STATE_NULL);
      gst_object_unref(pipeline_);
      pipeline_ = nullptr;
    }
    source_ = nullptr;
    frame_count_ = 0;
  }

 private:
  static GstFlowReturn OnNewSample(GstAppSink* sink, gpointer user_data) {
    auto* self = static_cast<LinuxLoopbackCapturer*>(user_data);
    if (!self->running_ || !self->source_.get()) {
      return GST_FLOW_FLUSHING;
    }

    GstSample* sample = gst_app_sink_pull_sample(sink);
    if (sample == nullptr) {
      return GST_FLOW_ERROR;
    }

    GstBuffer* buffer = gst_sample_get_buffer(sample);
    GstMapInfo map;
    if (buffer != nullptr && gst_buffer_map(buffer, &map, GST_MAP_READ)) {
      constexpr size_t channels = 2;
      constexpr int sample_rate = 48000;
      constexpr int bits_per_sample = 16;
      const size_t bytes_per_frame =
          channels * static_cast<size_t>(bits_per_sample / 8);
      const size_t number_of_frames = map.size / bytes_per_frame;
      if (number_of_frames > 0 && self->running_ && self->source_.get()) {
        self->source_->CaptureFrame(
            map.data, bits_per_sample, sample_rate, channels, number_of_frames);
        ++self->frame_count_;
        if (self->frame_count_ == 1) {
          std::cout << "[YappaLoopback] Delivered first system-audio buffer."
                    << std::endl;
        }
      }
      gst_buffer_unmap(buffer, &map);
    }

    gst_sample_unref(sample);
    return GST_FLOW_OK;
  }

  std::atomic<bool> running_{false};
  GstElement* pipeline_ = nullptr;
  scoped_refptr<RTCAudioSource> source_;
  uint64_t frame_count_ = 0;
};

}  // namespace

std::unique_ptr<LoopbackCapturer> CreateLoopbackCapturer(
    const std::string& /*source_id*/) {
  return std::make_unique<LinuxLoopbackCapturer>();
}

}  // namespace flutter_webrtc_plugin
