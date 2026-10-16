#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

class Win32Window {
 public:
  struct Point { unsigned int x; unsigned int y; Point(unsigned int x, unsigned int y) : x(x), y(y) {} };
  struct Size { unsigned int width; unsigned int height; Size(unsigned int width, unsigned int height) : width(width), height(height) {} };
  Win32Window();
  virtual ~Win32Window();
  bool Create(const wchar_t* title, const Point& origin, const Size& size);
  HWND GetHandle() const;
  RECT GetClientArea() const;
  void SetChildContent(HWND content);
  void SetQuitOnClose(bool quit_on_close);
  void Show();

 protected:
  virtual bool OnCreate();
  virtual void OnDestroy();
  virtual void OnSize(unsigned int width, unsigned int height);
  virtual LRESULT MessageHandler(HWND window, UINT message, WPARAM wparam,
                                 LPARAM lparam);

 private:
  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
  HWND window_ = nullptr;
  HWND child_content_ = nullptr;
  bool quit_on_close_ = false;
};

#endif
