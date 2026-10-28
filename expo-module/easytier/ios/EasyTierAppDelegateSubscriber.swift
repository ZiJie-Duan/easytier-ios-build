import ExpoModulesCore
import UIKit

/// Starts the saved tunnel config as the app launches, before the JS bundle loads (M22-6):
/// by the time the first screen asks for data, the route to the hub is usually there.
public class EasyTierAppDelegateSubscriber: ExpoAppDelegateSubscriber {
  public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    EasyTierCore.shared.startFromLaunchConfig()
    return true
  }
}
