#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include <optional>
#include <string>

#include "audio_engine.h"
#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* native_audio_channel;
  LinuxAudioEngine* audio_engine;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

namespace {

void RespondSuccess(FlMethodCall* call, FlValue* value = nullptr) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(call, response, nullptr);
}

void RespondError(FlMethodCall* call, const std::string& message) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_error_response_new("audio_engine", message.c_str(), nullptr));
  fl_method_call_respond(call, response, nullptr);
}

void RespondResult(FlMethodCall* call, const std::optional<std::string>& error) {
  if (error.has_value()) {
    RespondError(call, error.value());
    return;
  }
  RespondSuccess(call);
}

void HandleNativeAudioCall(FlMethodChannel*, FlMethodCall* call,
                           gpointer user_data) {
  auto* application = MY_APPLICATION(user_data);
  LinuxAudioEngine* engine = application->audio_engine;
  const gchar* method = fl_method_call_get_name(call);
  FlValue* arguments = fl_method_call_get_args(call);

  if (g_strcmp0(method, "getCapabilities") == 0) {
    FlValue* result = engine->GetCapabilities();
    RespondSuccess(call, result);
    fl_value_unref(result);
    return;
  }
  if (g_strcmp0(method, "getMetrics") == 0) {
    FlValue* result = engine->GetMetrics();
    RespondSuccess(call, result);
    fl_value_unref(result);
    return;
  }
  if (g_strcmp0(method, "getNetworkInterfaces") == 0) {
    FlValue* result = fl_value_new_list();
    RespondSuccess(call, result);
    fl_value_unref(result);
    return;
  }
  if (g_strcmp0(method, "prepareSender") == 0) {
    RespondResult(call, engine->PrepareSender(arguments));
    return;
  }
  if (g_strcmp0(method, "prepareReceiver") == 0) {
    RespondResult(call, engine->PrepareReceiver(arguments));
    return;
  }
  if (g_strcmp0(method, "connectToSender") == 0) {
    RespondResult(call, engine->ConnectToSender(arguments));
    return;
  }
  if (g_strcmp0(method, "startStream") == 0) {
    RespondResult(call, engine->StartStream(arguments));
    return;
  }
  if (g_strcmp0(method, "prepareUsbSender") == 0) {
    RespondResult(call, engine->PrepareUsbSender(arguments));
    return;
  }
  if (g_strcmp0(method, "prepareUsbReceiver") == 0) {
    RespondResult(call, engine->PrepareUsbReceiver(arguments));
    return;
  }
  if (g_strcmp0(method, "stopStream") == 0) {
    engine->StopStream();
    RespondSuccess(call);
    return;
  }
  if (g_strcmp0(method, "setVolume") == 0) {
    engine->SetVolume(arguments);
    RespondSuccess(call);
    return;
  }
  if (g_strcmp0(method, "setMuted") == 0) {
    engine->SetMuted(arguments);
    RespondSuccess(call);
    return;
  }
  if (g_strcmp0(method, "disconnect") == 0) {
    engine->Disconnect();
    RespondSuccess(call);
    return;
  }
  fl_method_call_respond_not_implemented(call, nullptr);
}

}  // namespace

static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window = GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_default_size(window, 1280, 800);
  gtk_window_set_title(window, "AudioBridge");

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
  gtk_widget_realize(GTK_WIDGET(view));
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  self->audio_engine = new LinuxAudioEngine();
  self->native_audio_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "audio_bridge/native_engine",
      FL_METHOD_CODEC(fl_standard_method_codec_new()));
  fl_method_channel_set_method_call_handler(
      self->native_audio_channel, HandleNativeAudioCall, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
  gtk_widget_show(GTK_WIDGET(window));
}

static gboolean my_application_local_command_line(GApplication* application,
                                                    gchar*** arguments,
                                                    int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);
  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    *exit_status = 1;
    return TRUE;
  }
  g_application_activate(application);
  *exit_status = 0;
  return TRUE;
}

static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_object(&self->native_audio_channel);
  delete self->audio_engine;
  self->audio_engine = nullptr;
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication*) {}

MyApplication* my_application_new() {
  g_set_prgname(APPLICATION_ID);
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE, nullptr));
}
