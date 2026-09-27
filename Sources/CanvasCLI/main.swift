import Foundation

// canvas: works on the boards open in Infinite Canvas, through the app. See Invocation.swift.
let status = Invocation(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment).run()
exit(status.rawValue)
