import Foundation

public enum MicState: Equatable, Sendable {
    case muted
    case unmuted
}

public enum MeetScriptMode: String, Sendable {
    case query
    case mute
    case unmute
}

public enum MeetScriptResult: Equatable, Sendable {
    case state(MicState)
    case noButton
    case unexpected(String)
}

/// The JavaScript run inside a Meet tab. The ONLY place that knows Meet's DOM.
/// Mic and camera buttons both carry data-is-muted, so we also match the
/// aria-label ("Turn off microphone" / "Turn on microphone", observed live 2026-11-09).
public enum MeetToggleJS {
    public static let source = #"""
    (function (mode) {
      var button = document.querySelector('button[data-is-muted][aria-label*="microphone" i]');
      if (!button) return 'no-button';
      var muted = button.getAttribute('data-is-muted') === 'true';
      if ((mode === 'mute' && !muted) || (mode === 'unmute' && muted)) {
        button.click();
        return mode === 'mute' ? 'muted' : 'unmuted';
      }
      return muted ? 'muted' : 'unmuted';
    })
    """#

    public static func invocation(_ mode: MeetScriptMode) -> String {
        "\(source)(\"\(mode.rawValue)\")"
    }

    public static func parse(_ output: String) -> MeetScriptResult {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "muted": .state(.muted)
        case "unmuted": .state(.unmuted)
        case "no-button": .noButton
        case let other: .unexpected(other)
        }
    }
}
