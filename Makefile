# MacDirStat — build the Rust engine, then the Swift app.
#
#   make engine   stage ../dirstat-core as .lib/libdirstat_core.a
#   make build    engine + swift build
#   make run      engine + swift run (launches the app window)
#   make test     engine + swift test
#   make app      release build bundled as MacDirStat.app

DIRSTAT_CORE_DIR ?= ../dirstat-core

.PHONY: engine build run test app clean

engine:
	Scripts/build-engine.sh $(DIRSTAT_CORE_DIR)

build: engine
	swift build

run: engine
	swift run MacDirStat

test: engine
	swift test

app: engine
	swift build -c release
	rm -rf MacDirStat.app
	mkdir -p MacDirStat.app/Contents/MacOS MacDirStat.app/Contents/Resources
	cp .build/release/MacDirStat MacDirStat.app/Contents/MacOS/MacDirStat
	cp Resources/Info.plist MacDirStat.app/Contents/Info.plist
	@echo "Built MacDirStat.app"

clean:
	rm -rf .build .lib MacDirStat.app
