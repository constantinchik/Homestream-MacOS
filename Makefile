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

# Regenerate AppIcon.png/.icns and docs/icon.png from Assets/AppIcon.svg
# (renders with headless Google Chrome)
CHROME ?= /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
icon:
	rm -rf .build/icon && mkdir -p .build/icon/AppIcon.iconset
	"$(CHROME)" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
		--default-background-color=00000000 --window-size=1024,1024 \
		--screenshot=$(CURDIR)/Assets/AppIcon.png "file://$(CURDIR)/Assets/AppIcon.svg" 2>/dev/null
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s Assets/AppIcon.png --out .build/icon/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) Assets/AppIcon.png --out .build/icon/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns .build/icon/AppIcon.iconset -o Assets/AppIcon.icns
	sips -Z 256 Assets/AppIcon.png --out docs/icon.png >/dev/null

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

.PHONY: build install icon zip release run clean reset dev
