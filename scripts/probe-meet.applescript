-- Prints the first Meet tab's URL and the state of every button[data-is-muted] in it.
-- Usage: osascript scripts/probe-meet.applescript com.vivaldi.Vivaldi
on run argv
	set bundleID to item 1 of argv
	set js to "JSON.stringify(Array.from(document.querySelectorAll('button[data-is-muted]')).map(function (b) { return {label: b.getAttribute('aria-label'), muted: b.getAttribute('data-is-muted')}; }))"
	using terms from application "Google Chrome"
		tell application id bundleID
			repeat with browserWindow in windows
				repeat with browserTab in tabs of browserWindow
					if (URL of browserTab) starts with "https://meet.google.com/" then
						return (URL of browserTab) & linefeed & (execute browserTab javascript js)
					end if
				end repeat
			end repeat
		end tell
	end using terms from
	return "no Meet tab in " & bundleID
end run
