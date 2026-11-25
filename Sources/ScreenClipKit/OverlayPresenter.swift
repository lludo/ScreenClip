#if os(iOS) && DEBUG
  import SwiftUI
  import UIKit

  /// Shows ScreenClip in its own windows above the app, so the app's view hierarchy, navigation,
  /// and SwiftUI state are never touched.
  @MainActor final class OverlayPresenter {
    private var sheetWindow: UIWindow?
    private var toastWindow: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var toastGeneration = 0

    var windows: [UIWindow] { [sheetWindow, toastWindow].compactMap { $0 } }
    var isPresentingSheet: Bool { sheetWindow != nil }

    func presentSheet<Content: View>(
      in scene: UIWindowScene, @ViewBuilder content: (@escaping () -> Void) -> Content
    ) {
      guard sheetWindow == nil else { return }
      previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
      let window = UIWindow(windowScene: scene)
      window.windowLevel = .alert + 1
      let host = UIHostingController(rootView: AnyView(content { [weak self] in self?.dismissSheet() }))
      window.rootViewController = host
      window.alpha = 0
      window.makeKeyAndVisible()
      sheetWindow = window
      UIView.animate(withDuration: 0.2) { window.alpha = 1 }
    }

    func dismissSheet() {
      guard let window = sheetWindow else { return }
      sheetWindow = nil
      window.endEditing(true)
      UIView.animate(withDuration: 0.2, animations: { window.alpha = 0 }) { _ in
        window.isHidden = true
        window.rootViewController = nil
      }
      previousKeyWindow?.makeKey()
    }

    /// A short message at the top of the screen, with an optional action button.
    func toast(_ text: String, action: String? = nil, perform: (() -> Void)? = nil) {
      dismissToast()
      guard let scene = Snapshot.activeScene() else { return }
      toastGeneration += 1
      let generation = toastGeneration
      let bounds = scene.coordinateSpace.bounds
      let top = scene.windows.first?.safeAreaInsets.top ?? 44
      let window = UIWindow(windowScene: scene)
      window.windowLevel = .alert + 2
      window.frame = CGRect(x: 0, y: top + 4, width: bounds.width, height: 84)
      window.backgroundColor = .clear
      let view = ToastView(text: text, action: action) { [weak self] in
        self?.dismissToast()
        perform?()
      }
      let host = UIHostingController(rootView: view)
      host.view.backgroundColor = .clear
      window.rootViewController = host
      window.isHidden = false
      toastWindow = window
      DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 3.5 : 6)) { [weak self] in
        guard let self, self.toastGeneration == generation else { return }
        self.dismissToast()
      }
    }

    func dismissToast() {
      toastWindow?.isHidden = true
      toastWindow = nil
    }
  }

  struct ToastView: View {
    let text: String
    let action: String?
    let perform: () -> Void
    var body: some View {
      HStack(spacing: 12) {
        Image(systemName: "camera.viewfinder").foregroundStyle(.orange)
        Text(text).font(.subheadline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        if let action {
          Button(action, action: perform).buttonStyle(.borderedProminent).tint(.orange)
            .controlSize(.small)
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 10)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
      .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onTapGesture { if action == nil { perform() } }
    }
  }
#endif
