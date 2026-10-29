on run argv
	if (count of argv) is not 1 then error "Expected exactly one volume name."
	set volumeName to item 1 of argv
	if volumeName is not "SBM" then error "Expected the SBM volume."

	tell application "Finder"
		if not (exists disk (volumeName as text)) then error "The SBM volume is not mounted."
		set targetDisk to disk (volumeName as text)
		if not (exists item "SBM.app" of targetDisk) then error "SBM.app is missing."
		if not (exists item "Applications" of targetDisk) then error "Applications is missing."
		if not (exists item "background.png" of item ".background" of targetDisk) then error "The DMG background is missing."

		set backgroundFile to (POSIX file ((POSIX path of (targetDisk as alias)) & ".background/background.png")) as alias
		open targetDisk
		set targetWindow to front window
		set current view of targetWindow to icon view
		set toolbar visible of targetWindow to false
		set statusbar visible of targetWindow to false
		set bounds of targetWindow to {200, 80, 550, 615}
		set arrangement of icon view options of targetWindow to not arranged
		set icon size of icon view options of targetWindow to 88
		set text size of icon view options of targetWindow to 12
		set background picture of icon view options of targetWindow to backgroundFile
		set position of item "SBM.app" of targetDisk to {175, 112}
		set position of item "Applications" of targetDisk to {175, 346}
		update targetDisk

		if (icon size of icon view options of targetWindow) is not 88 then error "Finder did not accept the requested icon size."
		if (bounds of targetWindow) is not {200, 80, 550, 615} then error "Finder did not accept the requested window bounds."
		if (position of item "SBM.app" of targetDisk) is not {175, 112} then error "Finder did not accept the SBM.app position."
		if (position of item "Applications" of targetDisk) is not {175, 346} then error "Finder did not accept the Applications position."
		delay 2
		close targetWindow
	end tell
end run
