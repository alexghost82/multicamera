import Darwin
import Foundation

@main
struct RelayGuardianDriver {
    static func main() {
        exit(RelayLeaseGuardian.run(arguments: CommandLine.arguments))
    }
}
