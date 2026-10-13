import Darwin
import Foundation

@main struct DecodeProbe {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3 else { throw nativeError("image output.bgra") }
            let image = try decodeCapture(CommandLine.arguments[1])
            try Data(image.bgra).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            print("\(image.width) \(image.height)")
        } catch {
            print(error.localizedDescription)
            exit(1)
        }
    }
}
