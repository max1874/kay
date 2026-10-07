.PHONY: app release install icon strings

# macOS app. Input to the release pipeline at build/Kay.app. Not for daily use — see `install`.
app:
	@macOS/scripts/build-app.sh

# Release: notarize (asc notarize kay), publish the GitHub release and appcast.xml, install it here.
# `macOS/scripts/publish.sh --dry-run` checks the preconditions without spending a notarization;
# `macOS/scripts/publish.sh --from notarize-dmg` resumes after a dropped upload.
release:
	@macOS/scripts/publish.sh

# Put the released disk image into /Applications. This is the copy to use and test.
install:
	@macOS/scripts/install-release.sh

# Re-render macOS/Resources/AppIcon.icns from macOS/scripts/make-icon.swift.
icon:
	@swift macOS/scripts/make-icon.swift .

# Regenerate the .lproj string tables from macOS/scripts/localize.py.
strings:
	@python3 macOS/scripts/localize.py
