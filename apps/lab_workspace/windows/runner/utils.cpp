#include "utils.h"
#include <windows.h>
#include <shellapi.h>

std::vector<std::string> GetCommandLineArguments() {
  int count = 0;
  wchar_t** wide_args = CommandLineToArgvW(GetCommandLineW(), &count);
  std::vector<std::string> args;
  if (wide_args == nullptr) return args;
  for (int i = 1; i < count; ++i) {
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, wide_args[i], -1, nullptr, 0, nullptr, nullptr);
    if (bytes <= 1) { args.emplace_back(); continue; }
    std::string argument(bytes, '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide_args[i], -1, argument.data(), bytes, nullptr, nullptr);
    argument.pop_back();
    args.push_back(std::move(argument));
  }
  LocalFree(wide_args);
  return args;
}
