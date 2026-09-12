#include "flutter_window.h"

#include <optional>
#include <vector>

#include <wincrypt.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  trust_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "dev.fundus/windows_trust",
          &flutter::StandardMethodCodec::GetInstance());
  trust_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "rootCertificates") {
          result->NotImplemented();
          return;
        }
        flutter::EncodableList roots;
        const DWORD locations[] = {CERT_SYSTEM_STORE_CURRENT_USER,
                                   CERT_SYSTEM_STORE_LOCAL_MACHINE};
        for (const DWORD location : locations) {
          HCERTSTORE store = CertOpenStore(
              CERT_STORE_PROV_SYSTEM_W, X509_ASN_ENCODING,
              static_cast<HCRYPTPROV_LEGACY>(0),
              location | CERT_STORE_OPEN_EXISTING_FLAG |
                  CERT_STORE_READONLY_FLAG,
              L"ROOT");
          if (store == nullptr) continue;
          PCCERT_CONTEXT certificate = nullptr;
          while ((certificate = CertEnumCertificatesInStore(store,
                                                              certificate)) !=
                 nullptr) {
            roots.emplace_back(std::vector<uint8_t>(
                certificate->pbCertEncoded,
                certificate->pbCertEncoded + certificate->cbCertEncoded));
          }
          CertCloseStore(store, 0);
        }
        result->Success(flutter::EncodableValue(roots));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    trust_channel_.reset();
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
