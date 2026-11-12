import Flutter
import GoogleMaps
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Push notifications, straight from Apple (APNs) - no Firebase on iPhone. Channel "smartstep/push":
  //   register    -> asks for permission, registers with Apple -> this phone's device token (hex), or nil
  //   allowed     -> may this app show notifications?
  //   ask         -> ask for permission -> allowed?
  //   unregister  -> stop receiving (sign out)
  private var pushChannel: FlutterMethodChannel?
  private var pendingToken: FlutterResult?
  private let presenter = PushPresenter()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Google Maps API key for the official Google map. The build writes it into Info.plist (GMSApiKey) from the
    // GOOGLE_MAPS_API_KEY secret; without one the app never opens the official map, so nothing is set here.
    if let key = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String,
       !key.trimmingCharacters(in: .whitespaces).isEmpty {
      GMSServices.provideAPIKey(key)
    }
    // Show a notification as a banner even while the app is open.
    UNUserNotificationCenter.current().delegate = presenter
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(name: "smartstep/push", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "register":
        self.askPermission { granted in
          guard granted else { result(nil); return }
          // One answer per request: an earlier one still waiting gets nil.
          self.pendingToken?(nil)
          self.pendingToken = result
          UIApplication.shared.registerForRemoteNotifications()
          // Apple normally answers within a second. No answer (no network, a build without the push entitlement):
          // give up quietly - the app works without push, the Notifications screen still fills.
          DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.pendingToken?(nil)
            self?.pendingToken = nil
          }
        }
      case "allowed":
        UNUserNotificationCenter.current().getNotificationSettings { s in
          DispatchQueue.main.async { result(s.authorizationStatus == .authorized || s.authorizationStatus == .provisional) }
        }
      case "ask":
        self.askPermission { granted in result(granted) }
      case "unregister":
        UIApplication.shared.unregisterForRemoteNotifications()
        result(true)
      case "clearBadge":
        UIApplication.shared.applicationIconBadgeNumber = 0
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    pushChannel = channel
  }

  private func askPermission(_ done: @escaping (Bool) -> Void) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      DispatchQueue.main.async { done(granted) }
    }
  }

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    pendingToken?(hex)
    pendingToken = nil
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    pendingToken?(nil)
    pendingToken = nil
  }
}

/// Lets a notification show as a banner with sound while the app is in front (iOS otherwise shows nothing then).
class PushPresenter: NSObject, UNUserNotificationCenterDelegate {
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    completionHandler()
  }
}
