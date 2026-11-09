-- Runs JavaScript in the first Meet call tab of a Chromium browser and prints the result.
-- Usage: osascript scripts/run-meet-js.applescript <bundle-id> <javascript>
on run argv
	set bundleID to item 1 of argv
	set js to item 2 of argv
	using terms from application "Google Chrome"
		tell application id bundleID
			repeat with browserWindow in windows
				repeat with browserTab in tabs of browserWindow
					if (URL of browserTab) starts with "https://meet.google.com/" then
						return execute browserTab javascript js
					end if
				end repeat
			end repeat
		end tell
	end using terms from
	return "no Meet tab in " & bundleID
end run
