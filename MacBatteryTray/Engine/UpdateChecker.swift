import Foundation
import AppKit

/// GitHub Release 更新信息模型
public struct UpdateInfo: Sendable {
    public let currentVersion: String
    public let latestVersion: String
    public let hasUpdate: Bool
    public let releaseTitle: String
    public let releaseNotes: String
    public let releaseURL: URL
    public let downloadURL: URL?

    public init(
        currentVersion: String,
        latestVersion: String,
        hasUpdate: Bool,
        releaseTitle: String,
        releaseNotes: String,
        releaseURL: URL,
        downloadURL: URL? = nil
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.hasUpdate = hasUpdate
        self.releaseTitle = releaseTitle
        self.releaseNotes = releaseNotes
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
    }
}

/// 检查更新状态
public enum UpdateCheckStatus: Sendable {
    case idle
    case checking
    case upToDate(version: String)
    case updateAvailable(UpdateInfo)
    case failure(String)
}

/// GitHub Release 更新检查服务引擎（支持 REST API + Web 302 重定向双通道保底）
public final class UpdateChecker: @unchecked Sendable {
    public static let shared = UpdateChecker()

    public static let repoOwner = "MrcolorH"
    public static let repoName = "MacBatteryTray"

    /// 当前本地 App 版本
    public var currentVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.3"
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init() {}

    /// 执行检查更新（异步，双通道保底）
    public func checkForUpdates() async -> UpdateCheckStatus {
        let currentVer = currentVersion

        // 通道 1: 尝试通过 GitHub REST API 获取完整发布元数据
        if let apiResult = await fetchViaAPI(currentVersion: currentVer) {
            return apiResult
        }

        // 通道 2: 若 API 遇 Rate Limit 限制，通过 GitHub Web 302 重定向解析最新 Tag
        if let webResult = await fetchViaWebRedirect(currentVersion: currentVer) {
            return webResult
        }

        return .failure("未能获取最新版本信息，请检查网络连接")
    }

    // MARK: - 通道 1: REST API
    private func fetchViaAPI(currentVersion: String) async -> UpdateCheckStatus? {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest") else {
            return nil
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("MacBatteryTray-App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return nil
            }

            let latestVer = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let releaseTitle = json["name"] as? String ?? "MacBatteryTray \(tagName)"
            let releaseNotes = json["body"] as? String ?? ""
            let htmlURLStr = json["html_url"] as? String ?? "https://github.com/\(Self.repoOwner)/\(Self.repoName)/releases/latest"
            let releaseURL = URL(string: htmlURLStr) ?? URL(string: "https://github.com/\(Self.repoOwner)/\(Self.repoName)/releases")!

            // 查找 zip 资产下载地址
            var downloadURL: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let assetName = asset["name"] as? String, assetName.hasSuffix(".zip"),
                       let downloadURLStr = asset["browser_download_url"] as? String,
                       let validURL = URL(string: downloadURLStr) {
                        downloadURL = validURL
                        break
                    }
                }
            }

            let hasUpdate = Self.isVersion(latestVer, higherThan: currentVersion)
            let info = UpdateInfo(
                currentVersion: currentVersion,
                latestVersion: latestVer,
                hasUpdate: hasUpdate,
                releaseTitle: releaseTitle,
                releaseNotes: releaseNotes,
                releaseURL: releaseURL,
                downloadURL: downloadURL
            )

            if hasUpdate {
                return .updateAvailable(info)
            } else {
                return .upToDate(version: currentVersion)
            }
        } catch {
            return nil
        }
    }

    // MARK: - 通道 2: Web 302 重定向
    private func fetchViaWebRedirect(currentVersion: String) async -> UpdateCheckStatus? {
        guard let url = URL(string: "https://github.com/\(Self.repoOwner)/\(Self.repoName)/releases/latest") else {
            return nil
        }

        // 不自动跟随重定向以捕获 302 Location
        let config = URLSessionConfiguration.ephemeral
        let delegate = RedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        do {
            _ = try await session.data(for: request)
            guard let location = delegate.redirectedLocation else {
                return nil
            }

            // location 如: https://github.com/MrcolorH/MacBatteryTray/releases/tag/v1.0.2
            let tag = location.lastPathComponent
            let latestVer = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            guard !latestVer.isEmpty else { return nil }

            let hasUpdate = Self.isVersion(latestVer, higherThan: currentVersion)
            let info = UpdateInfo(
                currentVersion: currentVersion,
                latestVersion: latestVer,
                hasUpdate: hasUpdate,
                releaseTitle: "MacBatteryTray \(tag)",
                releaseNotes: "发现最新版本 \(tag)，点击前往 GitHub 页面查看更新详情并下载。",
                releaseURL: location,
                downloadURL: nil
            )

            if hasUpdate {
                return .updateAvailable(info)
            } else {
                return .upToDate(version: currentVersion)
            }
        } catch {
            return nil
        }
    }

    /// 语义化版本号大小比较 (如 "1.0.2" 比 "1.0.1" 高)
    public static func isVersion(_ remote: String, higherThan local: String) -> Bool {
        let rParts = remote.replacingOccurrences(of: "v", with: "").split(separator: ".").compactMap { Int($0) }
        let lParts = local.replacingOccurrences(of: "v", with: "").split(separator: ".").compactMap { Int($0) }

        let maxCount = max(rParts.count, lParts.count)
        for i in 0..<maxCount {
            let r = i < rParts.count ? rParts[i] : 0
            let l = i < lParts.count ? lParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }
}

// 阻止 URLSession 自动重定向以捕获 Location Header
private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _redirectedLocation: URL?

    var redirectedLocation: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _redirectedLocation
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        self._redirectedLocation = request.url
        lock.unlock()
        // 阻止继续重定向
        completionHandler(nil)
    }
}
