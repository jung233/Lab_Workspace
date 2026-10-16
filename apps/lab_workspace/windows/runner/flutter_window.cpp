#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <filesystem>
#include <cwchar>
#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {
std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                        static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), length);
  return result;
}

bool IsAuthorizedTemporaryFile(const std::wstring& path) {
  wchar_t temp[MAX_PATH] = {};
  const DWORD length = GetTempPathW(MAX_PATH, temp);
  if (length == 0 || length >= MAX_PATH) return false;
  const auto root = std::filesystem::path(temp) / L"lab_workspace_open";
  std::error_code error;
  const auto canonical_root = std::filesystem::weakly_canonical(root, error);
  if (error) return false;
  const auto canonical_file = std::filesystem::weakly_canonical(path, error);
  if (error || !std::filesystem::is_regular_file(canonical_file, error)) return false;
  const auto prefix = canonical_root.native() + L"\\";
  const auto candidate = canonical_file.native();
  return candidate.size() > prefix.size() &&
         _wcsnicmp(candidate.c_str(), prefix.c_str(), prefix.size()) == 0;
}

std::optional<std::wstring> ReadPath(const flutter::EncodableValue* arguments) {
  if (arguments == nullptr || !std::holds_alternative<flutter::EncodableMap>(*arguments)) return std::nullopt;
  const auto& map = std::get<flutter::EncodableMap>(*arguments);
  const auto found = map.find(flutter::EncodableValue("path"));
  if (found == map.end() || !std::holds_alternative<std::string>(found->second)) return std::nullopt;
  const auto path = Utf8ToWide(std::get<std::string>(found->second));
  return path.empty() ? std::nullopt : std::optional<std::wstring>(path);
}

void HandleFileAction(const flutter::MethodCall<flutter::EncodableValue>& call,
                      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto path = ReadPath(call.arguments());
  if (!path || !IsAuthorizedTemporaryFile(*path)) {
    result->Error("FILE_PATH_DENIED", "Path is outside app temporary storage.");
    return;
  }
  if (call.method_name() == "openFile") {
    const auto code = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", path->c_str(), nullptr, nullptr, SW_SHOWNORMAL));
    if (code <= 32) result->Error("NO_FILE_VIEWER", "Windows could not open this file.");
    else result->Success(flutter::EncodableValue(true));
  } else if (call.method_name() == "revealFile") {
    const std::wstring args = L"/select,\"" + *path + L"\"";
    const auto code = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", L"explorer.exe", args.c_str(), nullptr, SW_SHOWNORMAL));
    if (code <= 32) result->Error("REVEAL_FAILED", "Windows Explorer could not show this file.");
    else result->Success(flutter::EncodableValue(true));
  } else if (call.method_name() == "shareFile") {
    result->Error("SHARE_UNAVAILABLE", "System sharing is not available on Windows.");
  } else {
    result->NotImplemented();
  }
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project) : project_(project) {}
FlutterWindow::~FlutterWindow() = default;

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) return false;
  const auto frame = GetClientArea();
  controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!controller_->engine() || !controller_->view()) return false;
  RegisterPlugins(controller_->engine());
  controller_->engine()->SetNextFrameCallback([this]() { Show(); });
  SetChildContent(controller_->view()->GetNativeWindow());
  file_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      controller_->engine()->messenger(), "lab_workspace/native_files",
      &flutter::StandardMethodCodec::GetInstance());
  file_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    HandleFileAction(call, std::move(result));
  });
  return true;
}

void FlutterWindow::OnDestroy() {
  file_channel_.reset();
  controller_.reset();
  Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(HWND window, UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  if (controller_) {
    const std::optional<LRESULT> result =
        controller_->HandleTopLevelWindowProc(window, message, wparam, lparam);
    if (result.has_value()) return *result;
  }
  return Win32Window::MessageHandler(window, message, wparam, lparam);
}
