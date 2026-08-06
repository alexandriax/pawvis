.PHONY: build release test app run icon clean

build:
	swift build

release:
	swift build -c release

test:
	swift test

app: release
	./scripts/make_app.sh

run: app
	open build/Pawvis.app

icon:
	./scripts/generate_icon.sh

clean:
	rm -rf .build build
