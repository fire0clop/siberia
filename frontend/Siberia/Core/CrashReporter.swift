import Foundation

// MARK: – Lightweight file-based crash reporter

/// Catches unhandled exceptions and uncaught signals, writes a crash log to
/// the app's Documents directory, and posts the log on the next launch.
enum CrashReporter {

	private static let crashFileName = "last_crash.log"

	static var crashLogURL: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
			.appendingPathComponent(crashFileName)
	}

	// MARK: Setup — call once from AppDelegate / App.init

	static func setup() {
		installExceptionHandler()
		installSignalHandlers()
	}

	// MARK: Read & clear on next launch

	/// Returns the crash log from the previous session (if any) and deletes it.
	static func consumePreviousCrashLog() -> String? {
		let url = crashLogURL
		guard FileManager.default.fileExists(atPath: url.path),
		      let text = try? String(contentsOf: url, encoding: .utf8)
		else { return nil }
		try? FileManager.default.removeItem(at: url)
		return text
	}

	// MARK: – Private

	private static func installExceptionHandler() {
		// NSSetUncaughtExceptionHandler accepts a regular closure — no C pointer constraint here.
		NSSetUncaughtExceptionHandler { exception in
			let report = _buildCrashReport(
				type: "NSException",
				reason: exception.reason ?? "(no reason)",
				callStack: exception.callStackSymbols
			)
			_writeCrashReport(report)
		}
	}

	private static func installSignalHandlers() {
		// Each signal() call needs a C function pointer (no captured context).
		// We register the same top-level handler for all fatal signals.
		signal(SIGABRT, _siberiaSignalHandler)
		signal(SIGILL,  _siberiaSignalHandler)
		signal(SIGSEGV, _siberiaSignalHandler)
		signal(SIGFPE,  _siberiaSignalHandler)
		signal(SIGBUS,  _siberiaSignalHandler)
		signal(SIGPIPE, _siberiaSignalHandler)
		signal(SIGTRAP, _siberiaSignalHandler)
	}
}

// MARK: – Top-level helpers (no captured context → valid C function pointers)

// Called from signal handler — must be async-signal-safe enough for our purposes.
func _siberiaSignalHandler(_ sig: Int32) {
	let report = _buildCrashReport(
		type: "Signal \(_signalName(sig))",
		reason: "Received signal \(sig)",
		callStack: Thread.callStackSymbols
	)
	_writeCrashReport(report)
	// Re-raise with default handler so OS records the crash normally.
	signal(sig, SIG_DFL)
	raise(sig)
}

func _buildCrashReport(type: String, reason: String, callStack: [String]) -> String {
	var lines = ["=== Siberia Crash Report ==="]
	lines.append("Date:    \(ISO8601DateFormatter().string(from: Date()))")
	lines.append("Type:    \(type)")
	lines.append("Reason:  \(reason)")
	lines.append("")
	lines.append("Call Stack:")
	lines.append(contentsOf: callStack)
	return lines.joined(separator: "\n")
}

func _writeCrashReport(_ report: String) {
	try? report.write(to: CrashReporter.crashLogURL, atomically: true, encoding: .utf8)
}

func _signalName(_ sig: Int32) -> String {
	switch sig {
	case SIGABRT: return "SIGABRT"
	case SIGILL:  return "SIGILL"
	case SIGSEGV: return "SIGSEGV"
	case SIGFPE:  return "SIGFPE"
	case SIGBUS:  return "SIGBUS"
	case SIGPIPE: return "SIGPIPE"
	case SIGTRAP: return "SIGTRAP"
	default:      return "SIG\(sig)"
	}
}
