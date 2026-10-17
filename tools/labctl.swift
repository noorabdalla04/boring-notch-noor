// labctl: send commands to the NoorLab sandbox (see boringNotch/extensions/NoorLab.swift)
// and wait for each to finish. Prints any `state` lines the lab logs.
import Foundation

let log = URL(fileURLWithPath: NSHomeDirectory()
    + "/Library/Containers/theboringteam.boringnotch.noor/Data/tmp/noor-lab/lab.log")

func lines() -> [String] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

for command in CommandLine.arguments.dropFirst() {
    let start = lines().count
    DistributedNotificationCenter.default().postNotificationName(
        .init("noor.lab"), object: command, userInfo: nil, deliverImmediately: true)
    let deadline = Date().addingTimeInterval(20)
    var done = false
    while Date() < deadline {
        let now = lines()
        if now.count > start, now[start...].contains("ok \(command)") {
            for line in now[start...] where line.hasPrefix("state ") || line.hasPrefix("reminders ") || line.hasPrefix("unknown") {
                print(line)
            }
            done = true
            break
        }
        usleep(40_000)
    }
    if !done { print("timeout: \(command)"); exit(1) }
}
