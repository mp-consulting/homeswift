import Foundation
import HomeswiftUI

/// `homeswift users`: the web UI's accounts in `ui-users.json`, from a shell. The Synology package's install
/// wizard creates the first one this way, and it is how a forgotten password is reset. Passwords are read from
/// standard input, never from the arguments, which other users of the machine can see.
enum UsersCommands {
    static let usage = """
        usage: homeswift users list
               homeswift users add <username> [--admin]
                                                     the password on standard input; the first account is an
                                                     administrator, a later one with --admin
               homeswift users password <username>   sets it without the current one, from standard input
               homeswift users check <username>      checks a password on standard input against the policy
        A running bridge reads the accounts when it starts: restart it after a change.
        """

    static func run(arguments: [String], storagePath: URL) throws {
        let store = UserStore(url: storagePath.appendingPathComponent("ui-users.json"))
        switch (arguments.first, arguments.count) {
        case ("list", 1):
            store.usernames.forEach { say($0) }
        case ("add", let count) where count == 2 || (count == 3 && arguments[2] == "--admin"):
            let user = try store.create(username: arguments[1], password: readPassword(), admin: arguments.count == 3)
            say("Added \(user.username)\(user.admin ? ", an administrator" : ""); restart the bridge for the web UI to know it.")
        case ("password", 2):
            guard store.contains(arguments[1]) else { throw CommandError("no user \(arguments[1]); homeswift users list shows them") }
            try store.resetPassword(username: arguments[1], to: readPassword())
            say("Changed the password of \(arguments[1]); restart the bridge for the web UI to use it.")
        case ("check", 2):
            let strength = PasswordPolicy.evaluate(try readPassword(), username: arguments[1])
            guard strength.isAcceptable else {
                throw CommandError("the password is too weak: \(strength.problems.joined(separator: "; "))")
            }
        default:
            throw CommandError(usage)
        }
    }

    /// The first line of standard input; a terminal gets a prompt without echo.
    static func readPassword() throws -> String {
        if isatty(STDIN_FILENO) != 0 {
            guard let typed = getpass("Password: ") else { throw CommandError("no password") }
            return String(cString: typed)
        }
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            throw CommandError("no password on standard input")
        }
        return line
    }
}
