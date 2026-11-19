import Foundation
import HephaestusIPC

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

switch CLIParser.parse(Array(CommandLine.arguments.dropFirst())) {
case .failure(let e):
    fail("hephaestus-cli: \(e)\nTry 'hephaestus-cli --help'.", code: 2)
case .success(.help):
    print(CLIParser.usage)
case .success(.version):
    print("hephaestus-cli \(HephaestusVersion.current)")
case .success(.request(let request)):
    do {
        let response = try SocketClient.send(request)
        guard response.ok else { fail("Error: \(response.error ?? "unknown error")", code: 1) }
        print(CLIOutput.render(request, response))
    } catch {
        fail("\(error)", code: 1)
    }
}
