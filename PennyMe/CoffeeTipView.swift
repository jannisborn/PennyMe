import StoreKit
import SwiftUI

enum CoffeeTips {
    static let productIDs = ["pennyme.tip.coffee", "pennyme.tip.double", "pennyme.tip.generous"]

    static func products() async throws -> [Product] {
        try await Product.products(for: productIDs)
            .filter { $0.type == .consumable && ($0.priceFormatStyle.currencyCode != "USD" || $0.price >= 5) }
            .sorted { $0.price < $1.price }
    }

    static func handleTransactionUpdates() async {
        for await update in StoreKit.Transaction.updates {
            _ = await finish(update)
        }
    }

    static func finish(_ result: VerificationResult<StoreKit.Transaction>) async -> Bool {
        guard case .verified(let transaction) = result,
              transaction.productType == .consumable,
              productIDs.contains(transaction.productID) else { return false }

        // A tip grants no entitlement. StoreKit handles the payment and purchase history.
        await transaction.finish()
        return true
    }
}

struct CoffeeTipView: View {
    private enum PurchaseNotice: String, Identifiable {
        case thanks = "Thank you for supporting PennyMe!"
        case pending = "Your tip is pending approval or payment confirmation from Apple."
        case unverified = "We couldn’t verify this tip. Check your App Store purchase history before trying again."
        case failed = "Apple couldn’t complete the tip. Please try again later."

        var id: Self { self }
    }

    @State private var products: [Product]?
    @State private var isPurchasing = false
    @State private var purchaseNotice: PurchaseNotice?

    var body: some View {
        List {
            Section {
                Text("PennyMe is 100% free and maintained in our spare time. If it helps you, please leave an optional tip from time to time. This helps to cover the costs of our server and the Apple developer membership. Tips unlock nothing— PennyMe remains free for everyone.")
            }
            Section {
                if let products {
                    if products.isEmpty {
                        Text("Tips are currently unavailable.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(products) { product in
                            Button {
                                guard !isPurchasing else { return }
                                isPurchasing = true
                                Task { await purchase(product) }
                            } label: {
                                HStack {
                                    Text(product.displayName)
                                    Spacer()
                                    Text(product.displayPrice).bold()
                                }
                            }
                        }
                        .disabled(isPurchasing)
                    }
                } else {
                    ProgressView("Loading tips…")
                }
            }
        }
        .listStyle(.insetGrouped)
        .task {
            products = (try? await CoffeeTips.products()) ?? []
        }
        .alert(item: $purchaseNotice) { notice in
            Alert(title: Text("Buy us a coffee"), message: Text(notice.rawValue))
        }
    }

    @MainActor
    private func purchase(_ product: Product) async {
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                purchaseNotice = await CoffeeTips.finish(result) ? .thanks : .unverified
            case .pending:
                purchaseNotice = .pending
            case .userCancelled:
                break
            @unknown default:
                purchaseNotice = .failed
            }
        } catch {
            purchaseNotice = .failed
        }
    }
}
