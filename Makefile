.PHONY: app release promote install icon strings

# macOS app. Input to the release pipeline at build/Kay.app. Not for daily use — see `install`.
app:
	@macOS/scripts/build-app.sh

# Stage a release: notarize (asc notarize kay), sign the Sparkle zip, install it here. Publishes nothing.
# `macOS/scripts/publish.sh stage --dry-run` checks the preconditions without spending a notarization;
# `macOS/scripts/publish.sh stage --from notarize-dmg` resumes after a dropped upload.
release:
	@macOS/scripts/publish.sh stage

# Publish the staged build (GitHub release, then appcast.xml), once it has dictated here without crashing.
promote:
	@macOS/scripts/publish.sh promote

# Put the released disk image into /Applications. This is the copy to use and test.
install:
	@macOS/scripts/install-release.sh

# Re-render macOS/Resources/AppIcon.icns from macOS/scripts/make-icon.swift.
icon:
	@swift macOS/scripts/make-icon.swift .

# Regenerate the .lproj string tables from macOS/scripts/localize.py.
strings:
	@python3 macOS/scripts/localize.py
