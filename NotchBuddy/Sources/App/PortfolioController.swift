import Foundation
import CryptoKit
import Combine

// MARK: - Data model

struct PortfolioHolding: Identifiable, Equatable, Sendable {
    let symbol: String          // "BTC", "ETH", "USDT"
    let amount: Double          // raw units (BTC, not satoshi)
    var price: Double           // USD price; filled after the price pass
    var change24h: Double? = nil        // % change vs 24 h ago; nil = unavailable
    var priceHistory: [Double] = []     // last 7 daily closes, oldest first
    var id: String { symbol }
    var value: Double { amount * price }
}

enum ExchangeKind: String, CaseIterable, Sendable, Codable {
    case binance, okx, bybit, kraken, coinbase
    var name: String {
        switch self {
        case .binance:  return "Binance"
        case .okx:      return "OKX"
        case .bybit:    return "Bybit"
        case .kraken:   return "Kraken"
        case .coinbase: return "Coinbase"
        }
    }
    var keychainPrefix: String { "portfolio-\(rawValue)" }
    /// Whether a passphrase is required (Coinbase Pro, OKX).
    var needsPassphrase: Bool { self == .okx || self == .coinbase }
}

enum WalletKind: String, CaseIterable, Sendable, Codable {
    // UTXO
    case bitcoin, dogecoin, litecoin
    // EVM — Ethereum mainnet + L2s + alt-L1s
    case ethereum, polygon, bnbChain, avalanche, arbitrum, optimism, base
    // Other L1s
    case solana, tron, xrp, cardano, cosmos, near

    var name: String {
        switch self {
        case .bitcoin:   return "Bitcoin"
        case .dogecoin:  return "Dogecoin"
        case .litecoin:  return "Litecoin"
        case .ethereum:  return "Ethereum"
        case .polygon:   return "Polygon"
        case .bnbChain:  return "BNB Chain"
        case .avalanche: return "Avalanche"
        case .arbitrum:  return "Arbitrum"
        case .optimism:  return "Optimism"
        case .base:      return "Base"
        case .solana:    return "Solana"
        case .tron:      return "TRON"
        case .xrp:       return "XRP Ledger"
        case .cardano:   return "Cardano"
        case .cosmos:    return "Cosmos"
        case .near:      return "NEAR"
        }
    }

    var symbol: String {
        switch self {
        case .bitcoin:   return "BTC"
        case .dogecoin:  return "DOGE"
        case .litecoin:  return "LTC"
        case .ethereum:  return "ETH"
        case .polygon:   return "POL"
        case .bnbChain:  return "BNB"
        case .avalanche: return "AVAX"
        case .arbitrum:  return "ETH"
        case .optimism:  return "ETH"
        case .base:      return "ETH"
        case .solana:    return "SOL"
        case .tron:      return "TRX"
        case .xrp:       return "XRP"
        case .cardano:   return "ADA"
        case .cosmos:    return "ATOM"
        case .near:      return "NEAR"
        }
    }

    var placeholder: String {
        switch self {
        case .bitcoin:                                        return "bc1q… or 1… or 3…"
        case .dogecoin:                                       return "D…"
        case .litecoin:                                       return "ltc1… or L… or M…"
        case .ethereum, .polygon, .bnbChain, .avalanche,
             .arbitrum, .optimism, .base:                    return "0x…"
        case .solana:                                         return "base58 address"
        case .tron:                                           return "T…"
        case .xrp:                                            return "r…"
        case .cardano:                                        return "addr1…"
        case .cosmos:                                         return "cosmos1…"
        case .near:                                           return "alice.near or 64-char hex"
        }
    }
}

struct PortfolioWallet: Identifiable, Equatable, Codable, Sendable {
    var id: String { address }
    let kind: WalletKind
    let address: String
    var label: String           // user-defined label, defaults to trimmed address
}

struct PortfolioAccount: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case exchange(ExchangeKind)
        case wallet(PortfolioWallet)
    }
    var id: String {
        switch source {
        case .exchange(let k):  return k.rawValue
        case .wallet(let w):    return w.address
        }
    }
    let source: Source
    var holdings: [PortfolioHolding] = []
    var fetchError: String?

    var totalValueUSD: Double { holdings.reduce(0) { $0 + $1.value } }
}

// MARK: - Settings

enum PortfolioSettings {
    private static let walletsKey = "portfolioWallets"

    static func key(for ex: ExchangeKind)        -> String? { KeychainStore.shared.get("\(ex.keychainPrefix)-key") }
    static func secret(for ex: ExchangeKind)     -> String? { KeychainStore.shared.get("\(ex.keychainPrefix)-secret") }
    static func passphrase(for ex: ExchangeKind) -> String? { KeychainStore.shared.get("\(ex.keychainPrefix)-passphrase") }

    static func save(exchange: ExchangeKind, key: String, secret: String, passphrase: String = "") {
        KeychainStore.shared.set("\(exchange.keychainPrefix)-key",    value: key)
        KeychainStore.shared.set("\(exchange.keychainPrefix)-secret", value: secret)
        if exchange.needsPassphrase {
            KeychainStore.shared.set("\(exchange.keychainPrefix)-passphrase", value: passphrase)
        }
    }

    static func remove(exchange: ExchangeKind) {
        KeychainStore.shared.remove("\(exchange.keychainPrefix)-key")
        KeychainStore.shared.remove("\(exchange.keychainPrefix)-secret")
        KeychainStore.shared.remove("\(exchange.keychainPrefix)-passphrase")
    }

    static func isConfigured(_ exchange: ExchangeKind) -> Bool {
        guard let k = key(for: exchange), !k.isEmpty else { return false }
        guard let s = secret(for: exchange), !s.isEmpty else { return false }
        if exchange.needsPassphrase {
            guard let p = passphrase(for: exchange), !p.isEmpty else { return false }
        }
        return true
    }

    static var wallets: [PortfolioWallet] {
        get {
            guard let data = UserDefaults.standard.data(forKey: walletsKey),
                  let list = try? JSONDecoder().decode([PortfolioWallet].self, from: data) else { return [] }
            return list
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: walletsKey)
        }
    }

    static func addWallet(_ w: PortfolioWallet) {
        var list = wallets.filter { $0.address != w.address }
        list.append(w)
        wallets = list
    }

    static func removeWallet(address: String) {
        wallets = wallets.filter { $0.address != address }
    }

    /// All configured exchange accounts + wallets, in deterministic order.
    static var configuredAccounts: [PortfolioAccount] {
        var accounts: [PortfolioAccount] = []
        for ex in ExchangeKind.allCases where isConfigured(ex) {
            accounts.append(PortfolioAccount(source: .exchange(ex)))
        }
        for w in wallets {
            accounts.append(PortfolioAccount(source: .wallet(w)))
        }
        return accounts
    }

    static var hasAnyAccount: Bool {
        ExchangeKind.allCases.contains(where: isConfigured) || !wallets.isEmpty
    }
}

// MARK: - Controller

@MainActor
final class PortfolioController: ObservableObject {
    static let shared = PortfolioController()
    nonisolated static let pillId = "integration_portfolio"

    @Published private(set) var accounts: [PortfolioAccount] = []
    @Published private(set) var loaded = false
    @Published private(set) var lastUpdate: Date?

    private var timer: Timer?
    private var fetching = false
    private var cancellables = Set<AnyCancellable>()

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains(Self.pillId)
    }

    private init() {
        AppState.shared.$activeIntegrations
            .map { $0.contains(Self.pillId) }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updatePolling() }
            }
            .store(in: &cancellables)
    }

    func start() { updatePolling() }

    func settingsChanged() {
        accounts = []
        loaded = false
        refresh()
    }

    func refreshIfStale(minAge: TimeInterval = 30) {
        guard Date().timeIntervalSince(lastUpdate ?? .distantPast) > minAge else { return }
        refresh()
    }

    private func updatePolling() {
        if isPillActive {
            if timer == nil {
                let t = Timer(timeInterval: 120, repeats: true) { _ in
                    MainActor.assumeIsolated { PortfolioController.shared.refresh() }
                }
                t.tolerance = 20
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
            accounts = []
            loaded = false
            lastUpdate = nil
        }
    }

    func refresh() {
        guard isPillActive, !fetching else { return }
        let configured = PortfolioSettings.configuredAccounts
        guard !configured.isEmpty else { accounts = []; loaded = true; return }
        fetching = true
        Task {
            var result: [PortfolioAccount] = []
            await withTaskGroup(of: PortfolioAccount.self) { group in
                for account in configured {
                    group.addTask { await Self.fetchAccount(account) }
                }
                for await a in group { result.append(a) }
            }
            // Stable order: match the configured order
            let ordered = configured.compactMap { conf in result.first { $0.id == conf.id } }
            // Get prices for all held symbols
            let symbols = Set(ordered.flatMap { $0.holdings.map(\.symbol) })
                .filter { !$0.hasPrefix("USD") && !$0.hasPrefix("EUR") }  // stable coins, skip
            let prices = await Self.fetchPrices(symbols: Array(symbols))
            var priced = ordered
            for i in priced.indices {
                for j in priced[i].holdings.indices {
                    let sym = priced[i].holdings[j].symbol
                    if let info = prices[sym] {
                        priced[i].holdings[j].price        = info.price
                        priced[i].holdings[j].change24h    = info.change24h
                        priced[i].holdings[j].priceHistory = info.history
                    } else if sym == "USDT" || sym == "USDC" || sym == "BUSD" || sym == "DAI" {
                        priced[i].holdings[j].price = 1.0    // stable coins ≈ $1
                    }
                }
            }
            fetching = false
            accounts = priced
            loaded = true
            lastUpdate = Date()
        }
    }

    // MARK: - Account fetch dispatch

    private nonisolated static func fetchAccount(_ account: PortfolioAccount) async -> PortfolioAccount {
        var a = account
        do {
            switch account.source {
            case .exchange(let kind):
                a.holdings = try await ExchangeFetcher.fetch(kind)
            case .wallet(let w):
                a.holdings = try await WalletFetcher.fetch(w)
            }
        } catch {
            a.fetchError = error.localizedDescription
        }
        return a
    }

    // MARK: - Price fetch (Coinbase public, no key)

    private struct PriceInfo: Sendable {
        var price: Double
        var change24h: Double?
        var history: [Double]   // 7 daily closes, oldest first
    }

    private nonisolated static func fetchPrices(symbols: [String]) async -> [String: PriceInfo] {
        guard !symbols.isEmpty else { return [:] }
        var result: [String: PriceInfo] = [:]
        await withTaskGroup(of: (String, PriceInfo?).self) { group in
            for sym in symbols {
                group.addTask {
                    let pair = "\(sym)-USD"
                    let base = "https://api.exchange.coinbase.com/products/\(pair)"

                    // Stats: last price + 24h open
                    guard let statsURL = URL(string: "\(base)/stats") else { return (sym, nil) }
                    var statsReq = URLRequest(url: statsURL, timeoutInterval: 8)
                    statsReq.setValue("application/json", forHTTPHeaderField: "Accept")
                    guard let (statsData, statsResp) = try? await URLSession.shared.data(for: statsReq),
                          (statsResp as? HTTPURLResponse)?.statusCode == 200,
                          let statsJSON = try? JSONSerialization.jsonObject(with: statsData) as? [String: Any],
                          let last = statsJSON["last"].flatMap({ Self.num($0) }) else { return (sym, nil) }
                    let open24h = statsJSON["open"].flatMap({ Self.num($0) })
                    let change = open24h.map { o in o > 0 ? (last - o) / o * 100 : 0.0 }

                    // Candles: 7 daily closes for sparkline
                    var history: [Double] = []
                    if let candlesURL = URL(string: "\(base)/candles?granularity=86400") {
                        var candlesReq = URLRequest(url: candlesURL, timeoutInterval: 8)
                        candlesReq.setValue("application/json", forHTTPHeaderField: "Accept")
                        if let (candlesData, candlesResp) = try? await URLSession.shared.data(for: candlesReq),
                           (candlesResp as? HTTPURLResponse)?.statusCode == 200,
                           let arr = try? JSONSerialization.jsonObject(with: candlesData) as? [[Any]] {
                            // Candles: [time, low, high, open, close, volume] — newest first
                            history = arr.prefix(7).compactMap { $0.count > 4 ? Self.num($0[4]) : nil }
                                .reversed()
                        }
                    }

                    return (sym, PriceInfo(price: last, change24h: change, history: history))
                }
            }
            for await (sym, info) in group {
                if let i = info { result[sym] = i }
            }
        }
        return result
    }

    private nonisolated static func num(_ v: Any) -> Double? {
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Formatting

    static func formatValue(_ usd: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = usd >= 1000 ? 0 : usd >= 1 ? 2 : 4
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: usd)) ?? String(format: "$%.2f", usd)
    }

    static func formatAmount(_ amount: Double) -> String {
        if amount == 0 { return "0" }
        if amount >= 1000 { return String(format: "%.0f", amount) }
        if amount >= 1    { return String(format: "%.4f", amount) }
        return String(format: "%.8f", amount)
    }
}

// MARK: - HMAC helpers

private enum HMACHelper {
    /// HMAC-SHA256 as hex.
    static func sha256hex(key: Data, message: String) -> String {
        let sym = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: sym)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    /// HMAC-SHA256 as base64.
    static func sha256b64(key: Data, message: String) -> String {
        let sym = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: sym)
        return Data(mac).base64EncodedString()
    }

    /// HMAC-SHA512 as base64 (Kraken).
    static func sha512b64(key: Data, message: Data) -> String {
        let sym = SymmetricKey(data: key)
        let mac = HMAC<SHA512>.authenticationCode(for: message, using: sym)
        return Data(mac).base64EncodedString()
    }

    /// SHA-256 of a string as raw Data (Kraken inner hash).
    static func sha256raw(_ input: String) -> Data {
        Data(SHA256.hash(data: Data(input.utf8)))
    }
}

// MARK: - Exchange Fetcher

private enum ExchangeFetcher {
    enum FetchError: Error, LocalizedError {
        case noCredentials
        case badResponse(String)
        case parseError

        var errorDescription: String? {
            switch self {
            case .noCredentials:    return String(localized: "portfolio.error.no-creds")
            case .badResponse(let m): return m
            case .parseError:       return String(localized: "portfolio.error.parse")
            }
        }
    }

    static func fetch(_ kind: ExchangeKind) async throws -> [PortfolioHolding] {
        switch kind {
        case .binance:  return try await fetchBinance()
        case .okx:      return try await fetchOKX()
        case .bybit:    return try await fetchBybit()
        case .kraken:   return try await fetchKraken()
        case .coinbase: return try await fetchCoinbase()
        }
    }

    // MARK: Binance

    private static func fetchBinance() async throws -> [PortfolioHolding] {
        guard let apiKey = PortfolioSettings.key(for: .binance), !apiKey.isEmpty,
              let secret = PortfolioSettings.secret(for: .binance), !secret.isEmpty,
              let secretData = secret.data(using: .utf8) else { throw FetchError.noCredentials }
        let ts = "\(Int64(Date().timeIntervalSince1970 * 1000))"
        let queryString = "timestamp=\(ts)"
        let sig = HMACHelper.sha256hex(key: secretData, message: queryString)
        guard let url = URL(string: "https://api.binance.com/api/v3/account?\(queryString)&signature=\(sig)") else {
            throw FetchError.badResponse("Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            throw FetchError.badResponse(msg)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balances = json["balances"] as? [[String: Any]] else { throw FetchError.parseError }
        return balances.compactMap { b -> PortfolioHolding? in
            guard let asset = b["asset"] as? String,
                  let free = (b["free"] as? String).flatMap(Double.init),
                  let locked = (b["locked"] as? String).flatMap(Double.init) else { return nil }
            let total = free + locked
            guard total > 0.000001 else { return nil }
            return PortfolioHolding(symbol: asset, amount: total, price: 0)
        }
    }

    // MARK: OKX

    private static func fetchOKX() async throws -> [PortfolioHolding] {
        guard let apiKey = PortfolioSettings.key(for: .okx), !apiKey.isEmpty,
              let secret = PortfolioSettings.secret(for: .okx), !secret.isEmpty,
              let passphrase = PortfolioSettings.passphrase(for: .okx), !passphrase.isEmpty,
              let secretData = secret.data(using: .utf8) else { throw FetchError.noCredentials }
        let ts = ISO8601DateFormatter().string(from: Date())
        let path = "/api/v5/account/balance"
        let message = "\(ts)GET\(path)"
        let sig = HMACHelper.sha256b64(key: secretData, message: message)
        guard let url = URL(string: "https://www.okx.com\(path)") else {
            throw FetchError.badResponse("Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,    forHTTPHeaderField: "OK-ACCESS-KEY")
        req.setValue(sig,       forHTTPHeaderField: "OK-ACCESS-SIGN")
        req.setValue(ts,        forHTTPHeaderField: "OK-ACCESS-TIMESTAMP")
        req.setValue(passphrase, forHTTPHeaderField: "OK-ACCESS-PASSPHRASE")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            throw FetchError.badResponse(msg)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]],
              let first = dataArr.first,
              let details = first["details"] as? [[String: Any]] else { throw FetchError.parseError }
        return details.compactMap { d -> PortfolioHolding? in
            guard let ccy = d["ccy"] as? String,
                  let avail = (d["availBal"] as? String).flatMap(Double.init),
                  let frozen = (d["frozenBal"] as? String).flatMap(Double.init) else { return nil }
            let total = avail + frozen
            guard total > 0.000001 else { return nil }
            return PortfolioHolding(symbol: ccy, amount: total, price: 0)
        }
    }

    // MARK: Bybit

    private static func fetchBybit() async throws -> [PortfolioHolding] {
        guard let apiKey = PortfolioSettings.key(for: .bybit), !apiKey.isEmpty,
              let secret = PortfolioSettings.secret(for: .bybit), !secret.isEmpty,
              let secretData = secret.data(using: .utf8) else { throw FetchError.noCredentials }
        let ts = "\(Int64(Date().timeIntervalSince1970 * 1000))"
        let recvWindow = "5000"
        let queryString = "accountType=UNIFIED"
        let message = "\(ts)\(apiKey)\(recvWindow)\(queryString)"
        let sig = HMACHelper.sha256hex(key: secretData, message: message)
        guard let url = URL(string: "https://api.bybit.com/v5/account/wallet-balance?\(queryString)") else {
            throw FetchError.badResponse("Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey,      forHTTPHeaderField: "X-BAPI-API-KEY")
        req.setValue(sig,         forHTTPHeaderField: "X-BAPI-SIGN")
        req.setValue(ts,          forHTTPHeaderField: "X-BAPI-TIMESTAMP")
        req.setValue(recvWindow,  forHTTPHeaderField: "X-BAPI-RECV-WINDOW")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            throw FetchError.badResponse(msg)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let list = result["list"] as? [[String: Any]],
              let first = list.first,
              let coins = first["coin"] as? [[String: Any]] else { throw FetchError.parseError }
        return coins.compactMap { c -> PortfolioHolding? in
            guard let coin = c["coin"] as? String,
                  let bal = (c["walletBalance"] as? String).flatMap(Double.init) else { return nil }
            guard bal > 0.000001 else { return nil }
            return PortfolioHolding(symbol: coin, amount: bal, price: 0)
        }
    }

    // MARK: Kraken

    private static func fetchKraken() async throws -> [PortfolioHolding] {
        guard let apiKey = PortfolioSettings.key(for: .kraken), !apiKey.isEmpty,
              let secretB64 = PortfolioSettings.secret(for: .kraken), !secretB64.isEmpty,
              let secretData = Data(base64Encoded: secretB64) else { throw FetchError.noCredentials }
        let nonce = "\(Int64(Date().timeIntervalSince1970 * 1000))"
        let path = "/0/private/Balance"
        let body = "nonce=\(nonce)"
        // Sign: SHA512( path_bytes + SHA256( nonce + body ) )
        let innerInput = nonce + body
        let innerHash = HMACHelper.sha256raw(innerInput)
        var msgData = Data(path.utf8)
        msgData.append(innerHash)
        let sig = HMACHelper.sha512b64(key: secretData, message: msgData)
        guard let url = URL(string: "https://api.kraken.com\(path)") else {
            throw FetchError.badResponse("Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "API-Key")
        req.setValue(sig,    forHTTPHeaderField: "API-Sign")
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            throw FetchError.badResponse(msg)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["error"] as? [String])?.isEmpty != false,
              let result = json["result"] as? [String: Any] else {
            let errors = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String] }?.first ?? "Parse error"
            throw FetchError.badResponse(errors)
        }
        // Kraken uses X-prefixed names: XXBT = BTC, XETH = ETH, ZUSD = USD, etc.
        return result.compactMap { (rawSym, rawVal) -> PortfolioHolding? in
            guard let val = Double(String(describing: rawVal)), val > 0.000001 else { return nil }
            let symbol = Self.krakenSymbol(rawSym)
            return PortfolioHolding(symbol: symbol, amount: val, price: 0)
        }
    }

    private static func krakenSymbol(_ raw: String) -> String {
        let map: [String: String] = [
            "XXBT": "BTC", "XETH": "ETH", "XLTC": "LTC", "XXLM": "XLM",
            "XXMR": "XMR", "XXRP": "XRP", "XZEC": "ZEC", "ZUSD": "USDT",
            "ZEUR": "EUR",  "ZGBP": "GBP", "ZCAD": "CAD", "ZJPY": "JPY",
        ]
        return map[raw] ?? (raw.hasPrefix("X") || raw.hasPrefix("Z") ? String(raw.dropFirst()) : raw)
    }

    // MARK: Coinbase (Exchange Pro)

    private static func fetchCoinbase() async throws -> [PortfolioHolding] {
        guard let apiKey = PortfolioSettings.key(for: .coinbase), !apiKey.isEmpty,
              let secret = PortfolioSettings.secret(for: .coinbase), !secret.isEmpty,
              let passphrase = PortfolioSettings.passphrase(for: .coinbase), !passphrase.isEmpty,
              let secretData = Data(base64Encoded: secret) else { throw FetchError.noCredentials }
        let ts = String(Int64(Date().timeIntervalSince1970))
        let path = "/accounts"
        let message = "\(ts)GET\(path)"
        let sig = HMACHelper.sha256b64(key: secretData, message: message)
        guard let url = URL(string: "https://api.exchange.coinbase.com\(path)") else {
            throw FetchError.badResponse("Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,      forHTTPHeaderField: "CB-ACCESS-KEY")
        req.setValue(sig,         forHTTPHeaderField: "CB-ACCESS-SIGN")
        req.setValue(ts,          forHTTPHeaderField: "CB-ACCESS-TIMESTAMP")
        req.setValue(passphrase,  forHTTPHeaderField: "CB-ACCESS-PASSPHRASE")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            throw FetchError.badResponse(msg)
        }
        guard let accounts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FetchError.parseError
        }
        return accounts.compactMap { a -> PortfolioHolding? in
            guard let currency = a["currency"] as? String,
                  let balance = (a["balance"] as? String).flatMap(Double.init),
                  balance > 0.000001 else { return nil }
            return PortfolioHolding(symbol: currency, amount: balance, price: 0)
        }
    }
}

// MARK: - Wallet Fetcher

private enum WalletFetcher {
    enum FetchError: Error, LocalizedError {
        case invalidAddress
        case networkError
        case parseError

        var errorDescription: String? {
            switch self {
            case .invalidAddress: return String(localized: "portfolio.error.bad-address")
            case .networkError:   return String(localized: "portfolio.error.network")
            case .parseError:     return String(localized: "portfolio.error.parse")
            }
        }
    }

    static func fetch(_ wallet: PortfolioWallet) async throws -> [PortfolioHolding] {
        switch wallet.kind {
        case .bitcoin:   return try await fetchBTC(address: wallet.address)
        case .dogecoin:  return try await fetchBlockchair(address: wallet.address, chain: "dogecoin",  symbol: "DOGE")
        case .litecoin:  return try await fetchBlockchair(address: wallet.address, chain: "litecoin",  symbol: "LTC")
        case .ethereum:  return try await fetchEVM(address: wallet.address, rpcURL: "https://cloudflare-eth.com",              symbol: "ETH")
        case .polygon:   return try await fetchEVM(address: wallet.address, rpcURL: "https://polygon-rpc.com",                 symbol: "POL")
        case .bnbChain:  return try await fetchEVM(address: wallet.address, rpcURL: "https://bsc-dataseed.binance.org",        symbol: "BNB")
        case .avalanche: return try await fetchEVM(address: wallet.address, rpcURL: "https://api.avax.network/ext/bc/C/rpc",   symbol: "AVAX")
        case .arbitrum:  return try await fetchEVM(address: wallet.address, rpcURL: "https://arb1.arbitrum.io/rpc",            symbol: "ETH")
        case .optimism:  return try await fetchEVM(address: wallet.address, rpcURL: "https://mainnet.optimism.io",             symbol: "ETH")
        case .base:      return try await fetchEVM(address: wallet.address, rpcURL: "https://mainnet.base.org",                symbol: "ETH")
        case .solana:    return try await fetchSOL(address: wallet.address)
        case .tron:      return try await fetchTRON(address: wallet.address)
        case .xrp:       return try await fetchXRP(address: wallet.address)
        case .cardano:   return try await fetchCardano(address: wallet.address)
        case .cosmos:    return try await fetchCosmos(address: wallet.address)
        case .near:      return try await fetchNEAR(address: wallet.address)
        }
    }

    // MARK: BTC (blockchain.info)

    private static func fetchBTC(address: String) async throws -> [PortfolioHolding] {
        guard let url = URL(string: "https://blockchain.info/balance?active=\(address)&cors=true") else {
            throw FetchError.invalidAddress
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.networkError }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addrData = json[address] as? [String: Any],
              let satoshi = addrData["final_balance"] as? Int else { throw FetchError.parseError }
        return [PortfolioHolding(symbol: "BTC", amount: Double(satoshi) / 1e8, price: 0)]
    }

    // MARK: UTXO via Blockchair (DOGE, LTC)

    private static func fetchBlockchair(address: String, chain: String, symbol: String) async throws -> [PortfolioHolding] {
        guard let url = URL(string: "https://api.blockchair.com/\(chain)/dashboards/address/\(address)") else {
            throw FetchError.invalidAddress
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.networkError }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let addrDict = dataDict[address] as? [String: Any],
              let addrInfo = addrDict["address"] as? [String: Any] else { throw FetchError.parseError }
        let satoshi: Double
        if let i = addrInfo["balance"] as? Int { satoshi = Double(i) }
        else if let s = addrInfo["balance"] as? String, let d = Double(s) { satoshi = d }
        else { throw FetchError.parseError }
        return [PortfolioHolding(symbol: symbol, amount: satoshi / 1e8, price: 0)]
    }

    // MARK: EVM (eth_getBalance JSON-RPC — works for any EVM chain)

    private static func fetchEVM(address: String, rpcURL: String, symbol: String) async throws -> [PortfolioHolding] {
        guard let url = URL(string: rpcURL) else { throw FetchError.networkError }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1,
                                   "method": "eth_getBalance", "params": [address, "latest"]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.networkError }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hexWei = json["result"] as? String,
              let wei = hexToDouble(hexWei) else { throw FetchError.parseError }
        return [PortfolioHolding(symbol: symbol, amount: wei / 1e18, price: 0)]
    }

    /// Converts a 0x-prefixed hex string to Double without integer overflow.
    private static func hexToDouble(_ hex: String) -> Double? {
        let s = hex.lowercased().hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard !s.isEmpty else { return 0 }
        var result: Double = 0
        for c in s {
            guard let digit = c.hexDigitValue else { return nil }
            result = result * 16 + Double(digit)
        }
        return result
    }

    // MARK: Solana

    private static func fetchSOL(address: String) async throws -> [PortfolioHolding] {
        guard let url = URL(string: "https://api.mainnet-beta.solana.com") else { throw FetchError.networkError }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1,
                                   "method": "getBalance", "params": [address]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.networkError }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let lamports = result["value"] as? Int else { throw FetchError.parseError }
        return [PortfolioHolding(symbol: "SOL", amount: Double(lamports) / 1e9, price: 0)]
    }

    // MARK: TRON (TronGrid)

    private static func fetchTRON(address: String) async throws -> [PortfolioHolding] {
        guard let url = URL(string: "https://api.trongrid.io/v1/accounts/\(address)") else {
            throw FetchError.invalidAddress
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.networkError }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]] else { throw FetchError.parseError }
        let sun = dataArr.first.flatMap { $0["balance"] as? Int } ?? 0
        return [PortfolioHolding(symbol: "TRX", amount: Double(sun) / 1e6, price: 0)]
    }

    // MARK: XRP Ledger

    private static func fetchXRP(address: String) async throws -> [PortfolioHolding] {
        guard let url = URL(string: "https://xrplcluster.com") else { throw FetchError.networkError }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["method": "account_info",
                                   "params": [["account": address, "ledger_index": "current"]]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.networkError }
        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let acct   = result["account_data"] as? [String: Any],
              let dropsStr = acct["Balance"] as? String,
              let drops = Double(dropsStr) else { throw FetchError.parseError }
        return [PortfolioHolding(symbol: "XRP", amount: drops / 1e6, price: 0)]
    }

    // MARK: Cardano (Koios public API)

    private static func fetchCardano(address: String) async throws -> [PortfolioHolding] {
        guard let url = URL(string: "https://api.koios.rest/api/v1/address_info") else { throw FetchError.networkError }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["_addresses": [address]])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.networkError }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first else { throw FetchError.parseError }
        let lovelace = (first["balance"] as? String).flatMap(Double.init) ?? 0
        return [PortfolioHolding(symbol: "ADA", amount: lovelace / 1e6, price: 0)]
    }

    // MARK: Cosmos Hub (REST)

    private static func fetchCosmos(address: String) async throws -> [PortfolioHolding] {
        let path = "https://rest.cosmos.directory/cosmoshub/cosmos/bank/v1beta1/balances/\(address)"
        guard let url = URL(string: path) else { throw FetchError.invalidAddress }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.networkError }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balances = json["balances"] as? [[String: Any]] else { throw FetchError.parseError }
        var holdings: [PortfolioHolding] = []
        for b in balances {
            guard let denom = b["denom"] as? String, denom == "uatom",
                  let amtStr = b["amount"] as? String, let amt = Double(amtStr), amt > 0 else { continue }
            holdings.append(PortfolioHolding(symbol: "ATOM", amount: amt / 1e6, price: 0))
        }
        return holdings
    }

    // MARK: NEAR Protocol

    private static func fetchNEAR(address: String) async throws -> [PortfolioHolding] {
        guard let url = URL(string: "https://rpc.mainnet.near.org") else { throw FetchError.networkError }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["jsonrpc": "2.0", "id": "dontcare", "method": "query",
                                   "params": ["request_type": "view_account", "finality": "final",
                                              "account_id": address]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.networkError }
        guard let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result   = json["result"] as? [String: Any],
              let amtStr   = result["amount"] as? String else { throw FetchError.parseError }
        // amount is in yoctoNEAR (1 NEAR = 1e24)
        let near = amtStr.reduce(0.0) { $0 * 10 + Double($1.wholeNumberValue ?? 0) } / 1e24
        return [PortfolioHolding(symbol: "NEAR", amount: near, price: 0)]
    }
}

// MARK: - Key validation (test before saving)

extension PortfolioController {
    /// Tests credentials by attempting a real fetch. Returns nil on success, error string on failure.
    static func validate(exchange: ExchangeKind,
                         key: String, secret: String, passphrase: String = "") async -> String? {
        // Temporarily set, test, then restore.
        let prevKey        = PortfolioSettings.key(for: exchange) ?? ""
        let prevSecret     = PortfolioSettings.secret(for: exchange) ?? ""
        let prevPassphrase = PortfolioSettings.passphrase(for: exchange) ?? ""
        PortfolioSettings.save(exchange: exchange, key: key, secret: secret, passphrase: passphrase)
        do {
            let holdings = try await ExchangeFetcher.fetch(exchange)
            _ = holdings   // success: at least an empty list is fine
            return nil
        } catch {
            // Restore previous credentials on failure
            PortfolioSettings.save(exchange: exchange,
                                   key: prevKey, secret: prevSecret, passphrase: prevPassphrase)
            return error.localizedDescription
        }
    }

    /// Validates a public wallet address by fetching its balance. Returns nil on success.
    static func validate(wallet: PortfolioWallet) async -> String? {
        do {
            _ = try await WalletFetcher.fetch(wallet)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Address validation (local, no network)

enum AddressValidator {
    /// Quick local check before hitting the network.
    static func isPlausible(_ address: String, kind: WalletKind) -> Bool {
        let a = address.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .bitcoin:
            // bech32 (bc1q…), bech32m (bc1p…), P2PKH (1…), P2SH (3…)
            if a.lowercased().hasPrefix("bc1") { return a.count >= 14 && a.count <= 90 }
            if a.hasPrefix("1") || a.hasPrefix("3") { return a.count >= 25 && a.count <= 34 }
            return false
        case .dogecoin:
            // P2PKH (D…) or P2SH (A…)
            return (a.hasPrefix("D") || a.hasPrefix("A")) && a.count >= 25 && a.count <= 34
        case .litecoin:
            if a.lowercased().hasPrefix("ltc1") { return a.count >= 26 && a.count <= 90 }
            if a.hasPrefix("L") || a.hasPrefix("M") { return a.count >= 25 && a.count <= 34 }
            return false
        case .ethereum, .polygon, .bnbChain, .avalanche, .arbitrum, .optimism, .base:
            // All EVM chains share the same 0x-prefixed 20-byte address format
            guard a.lowercased().hasPrefix("0x") else { return false }
            return a.dropFirst(2).count == 40 && a.dropFirst(2).allSatisfy(\.isHexDigit)
        case .solana:
            return a.count >= 32 && a.count <= 44
        case .tron:
            // Base58-encoded, always starts with T, 34 chars
            return a.hasPrefix("T") && a.count == 34
        case .xrp:
            return a.hasPrefix("r") && a.count >= 25 && a.count <= 35
        case .cardano:
            // Shelley mainnet (addr1…), bech32, ~103 chars
            return a.lowercased().hasPrefix("addr1") && a.count >= 50
        case .cosmos:
            // bech32, always cosmos1… + 38 chars = 45 total
            return a.hasPrefix("cosmos1") && a.count == 45
        case .near:
            // Implicit account: 64 lowercase hex chars
            if a.count == 64 { return a.allSatisfy { $0.isNumber || ($0 >= "a" && $0 <= "f") } }
            // Named account: e.g. alice.near — must contain a dot
            return a.count >= 5 && a.count <= 64 && a.contains(".")
        }
    }
}
