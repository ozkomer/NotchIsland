import Foundation

/// `notch bambu-login`, `bambu-token` and `bambu-logout`: sign in to the Bambu
/// Lab account from the terminal. The password is typed without echo, sent
/// only to Bambu's own servers, and never stored; only the session token is
/// kept, in the keychain.
enum BambuLogin {
    private static let api = "https://api.bambulab.com/v1/user-service/user"

    private struct Reply {
        var status: Int
        var json: [String: Any]
        var text: String
        var cookies: [String: String]
    }

    static func run(_ action: String) -> Int32 {
        switch action {
        case "bambu-logout":
            BambuAccount.delete()
            print("Bambu oturumu silindi.")
            return 0

        case "bambu-token":
            print("Bambu hesabınızın oturum belirtecini (token) yapıştırın. Yazdığınız görünmez.")
            let token = readSecret("Token: ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return fail("Boş bırakıldı.") }
            return store(token)

        default:
            return login()
        }
    }

    // MARK: Sign-in

    private static func login() -> Int32 {
        print("Bambu Lab hesabınızla giriş. Parola yalnızca Bambu'nun sunucusuna gönderilir ve saklanmaz.")
        print("E-posta: ", terminator: "")
        guard let email = readLine()?.trimmingCharacters(in: .whitespaces), !email.isEmpty else { return fail("E-posta gerekli.") }
        let password = readSecret("Parola: ")
        guard !password.isEmpty else { return fail("Parola gerekli.") }

        let first = request("\(api)/login", json: ["account": email, "password": password, "apiError": ""])
        if let blocked = blockedMessage(first) { return fail(blocked) }
        if let token = first.json["accessToken"] as? String, !token.isEmpty { return store(token) }

        switch first.json["loginType"] as? String {
        case "verifyCode":
            let sent = request("\(api)/sendemail/code", json: ["email": email, "type": "codeLogin"])
            guard sent.status == 200 else { return fail("Doğrulama kodu istenemedi (HTTP \(sent.status)).") }
            print("E-postanıza bir doğrulama kodu gönderildi.")
            print("Kod: ", terminator: "")
            let code = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            let second = request("\(api)/login", json: ["account": email, "code": code])
            if let token = second.json["accessToken"] as? String, !token.isEmpty { return store(token) }
            return fail("Kod kabul edilmedi (HTTP \(second.status)).")

        case "tfa":
            guard let key = first.json["tfaKey"] as? String else { return fail("İki adımlı doğrulama anahtarı gelmedi.") }
            let csrf = request("https://bambulab.com/api/csrf", method: "GET")
            guard let csrfToken = csrf.cookies["bbl_csrf_token"] else {
                return fail("İki adımlı doğrulama başlatılamadı (HTTP \(csrf.status)).")
            }
            print("Doğrulama uygulamanızdaki kod: ", terminator: "")
            let code = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            let second = request("https://bambulab.com/api/sign-in/tfa", json: ["tfaKey": key, "tfaCode": code],
                                 headers: ["x-bbl-csrf-token": csrfToken, "Cookie": "bbl_csrf_token=\(csrfToken)"])
            if let token = second.cookies["token"], !token.isEmpty { return store(token) }
            return fail("Kod kabul edilmedi (HTTP \(second.status)).")

        default:
            return fail("Giriş başarısız (HTTP \(first.status)). E-posta ya da parola yanlış olabilir.")
        }
    }

    /// Bambu's site sits behind a bot filter that may turn a plain client away.
    private static func blockedMessage(_ reply: Reply) -> String? {
        guard reply.status == 403 || reply.status == 429 else { return nil }
        return """
        Bambu'nun sunucusu bu istemciyi engelledi (HTTP \(reply.status)).
        Bunun yerine tarayıcıdan giriş yapıp oturum belirtecini verebilirsiniz:
          1. bambulab.com adresinde giriş yapın.
          2. Tarayıcının geliştirici araçlarında bambulab.com çerezlerinden "token" değerini kopyalayın.
          3. `notch bambu-token` komutunu çalıştırıp yapıştırın.
        """
    }

    private static func store(_ token: String) -> Int32 {
        guard BambuAccount.save(token) else { return fail("Oturum anahtar zincirine kaydedilemedi.") }
        // Tell the running app to pick up the new session.
        DistributedNotificationCenter.default().postNotificationName(
            Commands.notification, object: nil, userInfo: ["action": "bambu-reload", "id": "-"], deliverImmediately: true)
        Thread.sleep(forTimeInterval: 0.05)
        print("Giriş kaydedildi. Baskı başladığında adada görünecek.")
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }

    // MARK: Plumbing

    private static func request(_ url: String, method: String = "POST", json: [String: Any]? = nil,
                                headers: [String: String] = [:]) -> Reply {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NotchIsland", forHTTPHeaderField: "User-Agent")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        var reply = Reply(status: 0, json: [:], text: "", cookies: [:])
        let done = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                reply.status = http.statusCode
                let fields = (http.allHeaderFields as? [String: String]) ?? [:]
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: request.url!) {
                    reply.cookies[cookie.name] = cookie.value
                }
            }
            if let data {
                reply.text = String(decoding: data, as: UTF8.self)
                reply.json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            done.signal()
        }.resume()
        done.wait()
        return reply
    }

    /// Reads a line from the terminal without showing what is typed.
    private static func readSecret(_ prompt: String) -> String {
        print(prompt, terminator: "")
        fflush(stdout)
        var original = termios()
        let isTerminal = tcgetattr(STDIN_FILENO, &original) == 0
        if isTerminal {
            var silent = original
            silent.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &silent)
        }
        let line = readLine() ?? ""
        if isTerminal {
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            print("")
        }
        return line
    }
}
