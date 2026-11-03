import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        if let flutterVC = window?.rootViewController as? FlutterViewController {
            AppDelegate.shared?.setupChannelsIfNeeded(binaryMessenger: flutterVC.binaryMessenger)
        }
        if let url = connectionOptions.urlContexts.first?.url {
            AppDelegate.shared?.handleIncomingURL(url)
        }
    }

    override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        super.scene(scene, openURLContexts: URLContexts)
        if let url = URLContexts.first?.url {
            AppDelegate.shared?.handleIncomingURL(url)
        }
    }
}
