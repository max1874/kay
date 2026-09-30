.PHONY: app release install icon

# Input to the release pipeline at build/Kay.app. Not for daily use — see `install`.
app:
	@scripts/build-app.sh

# Notarize through the account pipeline (asc notarize kay) and publish a GitHub release.
# `scripts/publish.sh --dry-run` checks the preconditions without spending a notarization.
release:
	@scripts/publish.sh

# Put the released disk image into /Applications. This is the copy to use and test.
install:
	@scripts/install-release.sh

# Re-render Resources/AppIcon.icns from scripts/make-icon.swift.
icon:
	@swift scripts/make-icon.swift .
