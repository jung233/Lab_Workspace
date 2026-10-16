#include <windows.h>
#include <objbase.h>
#include <cstdlib>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE previous,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(GetCommandLineArguments());
  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 800);
  if (!window.Create(L"Lab Workspace", origin, size)) {
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  ::ShowWindow(window.GetHandle(), show_command);
  MSG message;
  while (::GetMessage(&message, nullptr, 0, 0)) {
    ::TranslateMessage(&message);
    ::DispatchMessage(&message);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
