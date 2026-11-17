import AIUsageCore
import Foundation

enum OpenAIAPICreditsClient {
    enum FetchError: Error {
        case http(Int)
        case malformed
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    static func fetchSpend(apiKey: String, cycle: DateInterval, now: Date) async throws -> Decimal {
        let start = Int(cycle.start.timeIntervalSince1970)
        let end = Int(min(now, cycle.end).timeIntervalSince1970)
        guard start < end else { return 0 }
        var url = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        let query = [
            URLQueryItem(name: "start_time", value: String(start)),
            URLQueryItem(name: "end_time", value: String(end)),
            URLQueryItem(name: "limit", value: "32"),
        ]
        var spend: Decimal = 0
        var seenCursors: Set<String> = []
        var cursor: String?
        repeat {
            url.queryItems = query + (cursor.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            var request = URLRequest(url: url.url!, timeoutInterval: 20)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { throw FetchError.malformed }
            guard (200..<300).contains(status) else { throw FetchError.http(status) }
            let page = try JSONDecoder().decode(OpenAIAPICredits.CostsPage.self, from: data)
            spend += page.spend
            cursor = page.nextPage
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw FetchError.malformed
            }
        } while cursor != nil
        return max(0, spend)
    }
}
