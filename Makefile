APP = HomeStream.app
BUNDLE = .build/$(APP)

build:
	swift build -c release
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp -f .build/release/Homestream $(BUNDLE)/Contents/MacOS/Homestream
	cp -f Info.plist $(BUNDLE)/Contents/Info.plist
	cp -f Assets/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(BUNDLE)

# Replace the bundle (cp -r into an existing .app nests it instead of updating)
install: build
	pkill -x Homestream || true
	rm -rf /Applications/$(APP)
	ditto $(BUNDLE) /Applications/$(APP)

# Zip the app bundle for distribution
ZIP = .build/HomeStream.app.zip
zip: build
	rm -f $(ZIP)
	ditto -c -k --keepParent $(BUNDLE) $(ZIP)

# Cut a GitHub release: make release VERSION=1.1.0
release:
	@test -n "$(VERSION)" || { echo "Usage: make release VERSION=x.y.z"; exit 1; }
	@git diff --quiet && git diff --cached --quiet || { echo "Working tree not clean; commit first"; exit 1; }
	@test "$$(git branch --show-current)" = main || { echo "Release from main"; exit 1; }
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" -c "Set :CFBundleVersion $(VERSION)" Info.plist
	$(MAKE) zip
	git commit -m "Release v$(VERSION)" Info.plist
	git tag v$(VERSION)
	git push origin main v$(VERSION)
	gh release create v$(VERSION) $(ZIP) --title "HomeStream v$(VERSION)" --generate-notes

run: build
	open $(BUNDLE)

clean:
	swift package clean
	rm -rf .build/$(APP)

reset:
	pkill -x Homestream || true
	tccutil reset ScreenCapture com.homestream.app
	tccutil reset Camera com.homestream.app

dev: install reset
	open /Applications/$(APP)

.PHONY: build install zip release run clean reset dev
