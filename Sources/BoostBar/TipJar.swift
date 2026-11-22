#if APPSTORE
import AppKit
import StoreKit

/// App Store edition: "buy me an energy drink" as a consumable In-App Purchase.
/// Product must exist in App Store Connect with this ID.
enum TipJar {
    static let productID = "com.macsboost.boostbar.energydrink"

    /// Listens for transactions that finish outside the purchase call (e.g. Ask to Buy, interrupted purchases).
    static func startObserving() {
        Task.detached {
            for await update in Transaction.updates {
                if case .verified(let t) = update { await t.finish() }
            }
        }
    }

    /// Localized price for the button title, e.g. "$4.99", or nil if the store can't be reached.
    static func displayPrice() async -> String? {
        try? await Product.products(for: [productID]).first?.displayPrice
    }

    @MainActor
    static func buy() async {
        do {
            guard let product = try await Product.products(for: [productID]).first else {
                Updater.alert("Store unavailable", "The App Store couldn’t be reached. Please try again later.")
                return
            }
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let t) = result {
                    await t.finish()
                    Updater.alert("Thank you! ⚡", "Your energy drink keeps the boost coming. May the boost be with you!")
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            Updater.alert("Purchase didn’t go through", error.localizedDescription)
        }
    }
}
#endif
