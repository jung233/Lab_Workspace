#include "win32_window.h"

namespace {
constexpr wchar_t kWindowClass[] = L"LabWorkspaceFlutterWindow";
}

Win32Window::Win32Window() = default;
Win32Window::~Win32Window() = default;

bool Win32Window::Create(const wchar_t* title, const Point& origin, const Size& size) {
  WNDCLASSW window_class = {};
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  window_class.lpszClassName = kWindowClass;
  window_class.style = CS_HREDRAW | CS_VREDRAW;
  window_class.lpfnWndProc = WndProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  RegisterClassW(&window_class);
  window_ = CreateWindowW(kWindowClass, title, WS_OVERLAPPEDWINDOW, origin.x, origin.y,
                          size.width, size.height, nullptr, nullptr, window_class.hInstance, this);
  return window_ != nullptr && OnCreate();
}

HWND Win32Window::GetHandle() const { return window_; }
RECT Win32Window::GetClientArea() const { RECT rect = {}; if (window_) GetClientRect(window_, &rect); return rect; }
void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_);
  const auto rect = GetClientArea();
  MoveWindow(content, 0, 0, rect.right - rect.left, rect.bottom - rect.top, TRUE);
  SetFocus(content);
}
void Win32Window::SetQuitOnClose(bool value) { quit_on_close_ = value; }
void Win32Window::Show() { if (window_) ShowWindow(window_, SW_SHOWNORMAL); }
bool Win32Window::OnCreate() { return true; }
void Win32Window::OnDestroy() {}
void Win32Window::OnSize(unsigned int width, unsigned int height) { if (child_content_) MoveWindow(child_content_, 0, 0, width, height, TRUE); }

LRESULT CALLBACK Win32Window::WndProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* instance = reinterpret_cast<Win32Window*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    instance = static_cast<Win32Window*>(create->lpCreateParams);
    instance->window_ = window;
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(instance));
  }
  return instance ? instance->MessageHandler(window, message, wparam, lparam)
                  : DefWindowProcW(window, message, wparam, lparam);
}

LRESULT Win32Window::MessageHandler(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_SIZE: OnSize(LOWORD(lparam), HIWORD(lparam)); return 0;
    case WM_DESTROY: OnDestroy(); if (quit_on_close_) PostQuitMessage(0); return 0;
    case WM_NCDESTROY: SetWindowLongPtrW(window, GWLP_USERDATA, 0); window_ = nullptr; break;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
