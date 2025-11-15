EZBURN_VERSION = $(shell cat version.txt)
GO_VERSION = $(shell cat go.version)

# Stash the "node" executable because otherwise it breaks on GitHub Actions with Windows when "PATH" is changed
NODE = $(shell which node)
GO_DIR = $(shell pwd)/go/$(GO_VERSION)/go
PATH_SEPARATOR = $(shell if uname | grep -qE "MINGW|WIN32|CYGWIN"; then echo ";"; else echo ":"; fi)
GO_COMPILER = PATH="$(GO_DIR)/bin$(PATH_SEPARATOR)$(PATH)" GOROOT="$(GO_DIR)" CGO_ENABLED=0

# Strip debug info
GO_FLAGS += "-ldflags=-s -w"

# Avoid embedding the build path in the executable for more reproducible builds
GO_FLAGS += -trimpath

ezburn: version-go cmd/ezburn/*.go pkg/*/*.go internal/*/*.go go.mod
	CGO_ENABLED=0 go build $(GO_FLAGS) ./cmd/ezburn

test:
	@$(MAKE) --no-print-directory -j6 test-common

# These tests are for development
test-common: test-go vet-go no-filepath verify-source-map end-to-end-tests js-api-tests plugin-tests register-test node-unref-tests decorator-tests

# These tests are for release (the extra tests are not included in "test" because they are pretty slow)
test-all:
	@$(MAKE) --no-print-directory -j6 test-common test-deno ts-type-tests test-wasm-node test-wasm-browser lib-typecheck test-yarnpnp

check-go-version:
	@go version | grep -F " go$(GO_VERSION) " || (echo 'Please install Go version $(GO_VERSION)' && false)

# Note: Don't add "-race" here by default. The Go race detector is currently
# only supported on the following configurations:
#
#   darwin/amd64
#   darwin/arm64
#   freebsd/amd64,
#   linux/amd64
#   linux/arm64
#   linux/ppc64le
#   netbsd/amd64
#   windows/amd64
#
# Also, it isn't necessarily supported on older OS versions even if the OS/CPU
# combination is supported, such as on macOS 10.9. If you want to test using
# the race detector, you can manually add it using the EZBURN_RACE environment
# variable like this: "EZBURN_RACE=-race make test". Or you can permanently
# enable it by adding "export EZBURN_RACE=-race" to your shell profile.
test-go:
	go test $(EZBURN_RACE) ./internal/... ./pkg/...

vet-go:
	go vet ./cmd/... ./internal/... ./pkg/...

fmt-go:
	test -z "$(shell go fmt ./cmd/... ./internal/... ./pkg/... )"

go-compiler: go/$(GO_VERSION)

# Build a custom version of the Go compiler that omits buildinfo from the
# final executable (since there is no command-line option to disable this).
# This is done in an attempt to avoid poorly-implemented "security" tools
# from breaking ezburn for users solely on the basis of what version of
# Go ezburn was compiled with.
#
# Most (all?) Go-related security tooling effectivelly runs the command
# "go version ./ezburn" and then creates a false-positive report for
# ezburn for every single CVE in Go's expansive standard library. There is
# no consideration for whether or not the corresponding API is ever actually
# used by ezburn. These reports are harmful to users as they prevent users
# from using ezburn in enterprise environments where these tools are
# mandatory.
#
# These reports are all false-positives because ezburn is not a security
# boundary. It's just a tool to transform trusted text (your source code)
# into other text, and a local development server that serves a read-only
# view of your source code and is not intended for production use.
go/$(GO_VERSION):
	mkdir -p go/$(GO_VERSION) && cd go/$(GO_VERSION) && curl -LO https://go.dev/dl/go$(GO_VERSION).src.tar.gz && tar xzf go$(GO_VERSION).src.tar.gz
	cd go/$(GO_VERSION)/go && grep -qF "ctxt.buildinfo()" src/cmd/link/internal/ld/main.go # Make sure this call is still there
	cd go/$(GO_VERSION)/go/src/cmd/link/internal/ld && sed "s/ctxt.buildinfo/\\/\\/ctxt.buildinfo/" main.go > temp && mv temp main.go
	cd go/$(GO_VERSION)/go/src && if uname | grep -qE "MINGW|WIN32|CYGWIN"; then ./make.bat; else ./make.bash; fi

no-filepath:
	@! grep --color --include '*.go' -r '"path/filepath"' cmd internal pkg || ( \
		echo 'error: Use of "path/filepath" is disallowed. See https://golang.org/issue/43768' && false)

# This uses "env -i" to run in a clean environment with no environment
# variables. It then adds some environment variables back as needed.
# This is a hack to avoid a problem with the WebAssembly support in Go
# 1.17.2, which will crash when run in an environment with over 4096
# bytes of environment variable data such as GitHub Actions.
test-wasm-node: ezburn
	env -i $(shell go env) PATH="$(shell go env GOROOT)/misc/wasm:$(PATH)" GOOS=js GOARCH=wasm go test ./internal/...
	node scripts/wasm-tests.js

test-wasm-browser: platform-wasm | scripts/browser/node_modules
	cd scripts/browser && node browser-tests.js

test-deno: ezburn platform-deno
	EZBURN_BINARY_PATH="$(shell pwd)/ezburn" deno test --allow-run --allow-env --allow-net --allow-read --allow-write --no-check scripts/deno-tests.js
	@echo '✅ deno tests passed' # I couldn't find a Deno API for telling when tests have failed, so I'm doing this here instead
	EZBURN_BINARY_PATH="$(shell pwd)/ezburn" deno eval 'import { transform, stop } from "file://$(shell pwd)/deno/mod.js"; console.log((await transform("1+2")).code); stop()' | grep "1 + 2;"
	EZBURN_BINARY_PATH="$(shell pwd)/ezburn" deno eval 'import { transform, stop } from "file://$(shell pwd)/deno/wasm.js"; console.log((await transform("1+2")).code); stop()' | grep "1 + 2;"
	EZBURN_BINARY_PATH="$(shell pwd)/ezburn" deno run -A './deno/mod.js'

test-deno-windows: ezburn platform-deno
	EZBURN_BINARY_PATH=./ezburn.exe deno test --allow-run --allow-env --allow-net --allow-read --allow-write --no-check scripts/deno-tests.js

register-test: version-go | scripts/node_modules
	node scripts/ezburn.js npm/ezburn/package.json --version
	node scripts/register-test.js

verify-source-map: version-go | scripts/node_modules
	node scripts/ezburn.js npm/ezburn/package.json --version
	node scripts/verify-source-map.js

end-to-end-tests: version-go
	node scripts/ezburn.js npm/ezburn/package.json --version
	node scripts/end-to-end-tests.js

# Note: The TypeScript source code for these tests was copied from the repo
# https://github.com/ezburn/decorator-tests, which is the official location of
# the source code for these tests. Any changes to these tests should be made
# there first and then copied here afterward.
decorator-tests: ezburn
	./ezburn scripts/decorator-tests.ts --target=es2022 --outfile=scripts/decorator-tests.js
	node scripts/decorator-tests.js
	node scripts/decorator-tests.js | grep -q 'All checks passed'
	git diff --exit-code scripts/decorator-tests.js

js-api-tests: version-go
	node scripts/ezburn.js npm/ezburn/package.json --version
	node scripts/js-api-tests.js

plugin-tests: version-go
	node scripts/plugin-tests.js

ts-type-tests: | scripts/node_modules
	node scripts/ts-type-tests.js

require/old-ts/node_modules:
	cd require/old-ts && npm ci

test-old-ts: platform-neutral | require/old-ts/node_modules
	rm -fr scripts/.test-old-ts && mkdir scripts/.test-old-ts
	cp `find npm/ezburn -name '*.d.ts'` scripts/.test-old-ts
	cd scripts/.test-old-ts && ../../require/old-ts/node_modules/.bin/tsc *.d.ts
	rm -fr scripts/.test-old-ts

node-unref-tests: | scripts/node_modules
	node scripts/node-unref-tests.js

lib-typecheck: lib-typecheck-node lib-typecheck-node-nolib lib-typecheck-deno

lib-typecheck-node: | lib/node_modules
	cd lib && node_modules/.bin/tsc -noEmit -p tsconfig.json

lib-typecheck-node-nolib: | lib/node_modules
	cd lib && node_modules/.bin/tsc -noEmit -p tsconfig-nolib.json

lib-typecheck-deno: lib/deno/lib.deno.d.ts | lib/node_modules
	cd lib && node_modules/.bin/tsc -noEmit -p tsconfig-deno.json

lib/deno/lib.deno.d.ts:
	deno types > lib/deno/lib.deno.d.ts

# End-to-end tests
test-e2e: test-e2e-npm test-e2e-pnpm test-e2e-yarn test-e2e-yarn-berry test-e2e-deno

test-e2e-npm:
	# Test normal install
	rm -fr e2e-npm && mkdir e2e-npm && cd e2e-npm && echo {} > package.json && npm i ezburn
	cd e2e-npm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"
	# Test CI reinstall
	cd e2e-npm && npm ci
	cd e2e-npm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"
	# Test rebuild
	cd e2e-npm && npm rebuild && npm rebuild
	cd e2e-npm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"

	# Test install without scripts
	rm -fr e2e-npm && mkdir e2e-npm && cd e2e-npm && echo {} > package.json && npm i --ignore-scripts ezburn
	cd e2e-npm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"
	# Test CI reinstall
	cd e2e-npm && npm ci
	cd e2e-npm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"
	# Test rebuild
	cd e2e-npm && npm rebuild && npm rebuild
	cd e2e-npm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"

	# Test install without optional dependencies
	rm -fr e2e-npm && mkdir e2e-npm && cd e2e-npm && echo {} > package.json && npm i --no-optional ezburn
	cd e2e-npm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"
	# Test CI reinstall
	cd e2e-npm && npm ci
	cd e2e-npm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"
	# Test rebuild
	cd e2e-npm && npm rebuild && npm rebuild
	cd e2e-npm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"

	# Clean up
	rm -fr e2e-npm

test-e2e-pnpm:
	# Test normal install
	rm -fr e2e-pnpm && mkdir e2e-pnpm && cd e2e-pnpm && echo {} > package.json && pnpm i ezburn
	cd e2e-pnpm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"
	# Test CI reinstall
	cd e2e-pnpm && pnpm i --frozen-lockfile
	cd e2e-pnpm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"
	# Test rebuild
	cd e2e-pnpm && pnpm rebuild && pnpm rebuild
	cd e2e-pnpm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"

	# Test install without scripts
	rm -fr e2e-pnpm && mkdir e2e-pnpm && cd e2e-pnpm && echo {} > package.json && pnpm i --ignore-scripts ezburn
	cd e2e-pnpm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"
	# Test CI reinstall
	cd e2e-pnpm && pnpm i --frozen-lockfile
	cd e2e-pnpm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"
	# Test rebuild
	cd e2e-pnpm && pnpm rebuild && pnpm rebuild
	cd e2e-pnpm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"

	# Test install without optional dependencies
	rm -fr e2e-pnpm && mkdir e2e-pnpm && cd e2e-pnpm && echo {} > package.json && pnpm i --no-optional ezburn
	cd e2e-pnpm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"
	# Test CI reinstall
	cd e2e-pnpm && pnpm i --frozen-lockfile
	cd e2e-pnpm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"
	# Test rebuild
	cd e2e-pnpm && pnpm rebuild && pnpm rebuild
	cd e2e-pnpm && echo "1+2" | node_modules/.bin/ezburn | grep "1 + 2;" && node -p "require('ezburn').transformSync('1+2').code" | grep "1 + 2;"

	# Clean up
	rm -fr e2e-pnpm

test-e2e-yarn:
	# Test normal install
	rm -fr e2e-yarn && mkdir e2e-yarn && cd e2e-yarn && echo {} > package.json && touch yarn.lock && yarn set version classic && yarn add ezburn
	cd e2e-yarn && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"
	# Test CI reinstall
	cd e2e-yarn && rm -fr node_modules && yarn install --immutable
	cd e2e-yarn && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"

	# Test install without scripts
	rm -fr e2e-yarn && mkdir e2e-yarn && cd e2e-yarn && echo {} > package.json && touch yarn.lock && echo 'enableScripts: false' > .yarnrc.yml && yarn set version classic && yarn add ezburn
	cd e2e-yarn && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"
	# Test CI reinstall
	cd e2e-yarn && rm -fr node_modules && yarn install --immutable
	cd e2e-yarn && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"

	# Test install without optional dependencies
	rm -fr e2e-yarn && mkdir e2e-yarn && cd e2e-yarn && echo {} > package.json && touch yarn.lock && yarn set version classic && yarn add ezburn
	cd e2e-yarn && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"
	# Test CI reinstall
	cd e2e-yarn && rm -fr node_modules && yarn install --immutable --ignore-optional
	cd e2e-yarn && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"

	# Clean up
	rm -fr e2e-yarn

test-e2e-yarn-berry:
	# Test normal install
	rm -fr e2e-yb && mkdir e2e-yb && cd e2e-yb && echo {} > package.json && touch yarn.lock && yarn set version berry && yarn add ezburn
	cd e2e-yb && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"
	# Test CI reinstall
	cd e2e-yb && yarn install --immutable
	cd e2e-yb && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"
	# Test rebuild
	cd e2e-yb && yarn rebuild && yarn rebuild
	cd e2e-yb && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"

	# Test install without scripts
	rm -fr e2e-yb && mkdir e2e-yb && cd e2e-yb && echo {} > package.json && touch yarn.lock && echo 'enableScripts: false' > .yarnrc.yml && yarn set version berry && yarn add ezburn
	cd e2e-yb && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"
	# Test CI reinstall
	cd e2e-yb && yarn install --immutable
	cd e2e-yb && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"
	# Test rebuild
	cd e2e-yb && yarn rebuild && yarn rebuild
	cd e2e-yb && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"

	# Test install without optional dependencies
	rm -fr e2e-yb && mkdir e2e-yb && cd e2e-yb && echo {} > package.json && touch yarn.lock && yarn set version berry && yarn add --no-optional ezburn
	cd e2e-yb && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"
	# Test CI reinstall
	cd e2e-yb && yarn install --immutable
	cd e2e-yb && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"
	# Test rebuild
	cd e2e-yb && yarn rebuild && yarn rebuild
	cd e2e-yb && echo "1+2" | yarn ezburn && yarn node -p "require('ezburn').transformSync('1+2').code"

	# Clean up
	rm -fr e2e-yb

test-e2e-deno:
	deno eval 'import { transform, stop } from "https://deno.land/x/ezburn@v$(EZBURN_VERSION)/mod.js"; console.log((await transform("1+2")).code); stop()' | grep "1 + 2;"
	deno eval 'import { transform, stop } from "https://deno.land/x/ezburn@v$(EZBURN_VERSION)/wasm.js"; console.log((await transform("1+2")).code); stop()' | grep "1 + 2;"

test-yarnpnp: platform-wasm
	node scripts/test-yarnpnp.js

# Note: This used to only be rebuilt when "version.txt" was newer than
# "cmd/ezburn/version.go", but that caused the publishing script to publish
# invalid builds in the case when the publishing script failed once, the change
# to "cmd/ezburn/version.go" was reverted, and then the publishing script was
# run again, since in that case "cmd/ezburn/version.go" has a later mtime than
# "version.txt" but is still outdated.
#
# To avoid this problem, we now always run this step regardless of mtime status.
# This step still avoids writing to "cmd/ezburn/version.go" if it already has
# the correct contents, so it won't unnecessarily invalidate anything that uses
# "cmd/ezburn/version.go" as a dependency.
version-go:
	node scripts/ezburn.js --update-version-go

platform-all: go-compiler
	@$(MAKE) --no-print-directory -j4 \
		platform-aix-ppc64 \
		platform-android-arm \
		platform-android-arm64 \
		platform-android-x64 \
		platform-darwin-arm64 \
		platform-darwin-x64 \
		platform-deno \
		platform-freebsd-arm64 \
		platform-freebsd-x64 \
		platform-linux-arm \
		platform-linux-arm64 \
		platform-linux-ia32 \
		platform-linux-loong64 \
		platform-linux-mips64el \
		platform-linux-ppc64 \
		platform-linux-riscv64 \
		platform-linux-s390x \
		platform-linux-x64 \
		platform-netbsd-arm64 \
		platform-netbsd-x64 \
		platform-neutral \
		platform-openbsd-arm64 \
		platform-openbsd-x64 \
		platform-openharmony-arm64 \
		platform-sunos-x64 \
		platform-wasi-preview1 \
		platform-wasm \
		platform-win32-arm64 \
		platform-win32-ia32 \
		platform-win32-x64

platform-win32-x64: version-go go-compiler
	node scripts/ezburn.js npm/@ezburn/win32-x64/package.json --version
	$(GO_COMPILER) GOOS=windows GOARCH=amd64 go build $(GO_FLAGS) -o npm/@ezburn/win32-x64/ezburn.exe ./cmd/ezburn

platform-win32-ia32: version-go go-compiler
	node scripts/ezburn.js npm/@ezburn/win32-ia32/package.json --version
	$(GO_COMPILER) GOOS=windows GOARCH=386 go build $(GO_FLAGS) -o npm/@ezburn/win32-ia32/ezburn.exe ./cmd/ezburn

platform-win32-arm64: version-go go-compiler
	node scripts/ezburn.js npm/@ezburn/win32-arm64/package.json --version
	$(GO_COMPILER) GOOS=windows GOARCH=arm64 go build $(GO_FLAGS) -o npm/@ezburn/win32-arm64/ezburn.exe ./cmd/ezburn

platform-wasi-preview1: version-go go-compiler
	node scripts/ezburn.js npm/@ezburn/wasi-preview1/package.json --version
	$(GO_COMPILER) GOOS=wasip1 GOARCH=wasm go build $(GO_FLAGS) -o npm/@ezburn/wasi-preview1/ezburn.wasm ./cmd/ezburn

platform-unixlike: version-go go-compiler
	@test -n "$(GOOS)" || (echo "The environment variable GOOS must be provided" && false)
	@test -n "$(GOARCH)" || (echo "The environment variable GOARCH must be provided" && false)
	@test -n "$(NPMDIR)" || (echo "The environment variable NPMDIR must be provided" && false)
	node scripts/ezburn.js "$(NPMDIR)/package.json" --version
	$(GO_COMPILER) GOOS="$(GOOS)" GOARCH="$(GOARCH)" go build $(GO_FLAGS) -o "$(NPMDIR)/bin/ezburn" ./cmd/ezburn

platform-android-x64: platform-wasm
	node scripts/ezburn.js npm/@ezburn/android-x64/package.json --version

platform-android-arm: platform-wasm
	node scripts/ezburn.js npm/@ezburn/android-arm/package.json --version

platform-openharmony-arm64: platform-wasm
	node scripts/ezburn.js npm/@ezburn/openharmony-arm64/package.json --version

platform-aix-ppc64:
	@$(MAKE) --no-print-directory GOOS=aix GOARCH=ppc64 NPMDIR=npm/@ezburn/aix-ppc64 platform-unixlike

platform-android-arm64:
	@$(MAKE) --no-print-directory GOOS=android GOARCH=arm64 NPMDIR=npm/@ezburn/android-arm64 platform-unixlike

platform-darwin-x64:
	@$(MAKE) --no-print-directory GOOS=darwin GOARCH=amd64 NPMDIR=npm/@ezburn/darwin-x64 platform-unixlike

platform-darwin-arm64:
	@$(MAKE) --no-print-directory GOOS=darwin GOARCH=arm64 NPMDIR=npm/@ezburn/darwin-arm64 platform-unixlike

platform-freebsd-x64:
	@$(MAKE) --no-print-directory GOOS=freebsd GOARCH=amd64 NPMDIR=npm/@ezburn/freebsd-x64 platform-unixlike

platform-freebsd-arm64:
	@$(MAKE) --no-print-directory GOOS=freebsd GOARCH=arm64 NPMDIR=npm/@ezburn/freebsd-arm64 platform-unixlike

platform-netbsd-arm64:
	@$(MAKE) --no-print-directory GOOS=netbsd GOARCH=arm64 NPMDIR=npm/@ezburn/netbsd-arm64 platform-unixlike

platform-netbsd-x64:
	@$(MAKE) --no-print-directory GOOS=netbsd GOARCH=amd64 NPMDIR=npm/@ezburn/netbsd-x64 platform-unixlike

platform-openbsd-arm64:
	@$(MAKE) --no-print-directory GOOS=openbsd GOARCH=arm64 NPMDIR=npm/@ezburn/openbsd-arm64 platform-unixlike

platform-openbsd-x64:
	@$(MAKE) --no-print-directory GOOS=openbsd GOARCH=amd64 NPMDIR=npm/@ezburn/openbsd-x64 platform-unixlike

platform-linux-x64:
	@$(MAKE) --no-print-directory GOOS=linux GOARCH=amd64 NPMDIR=npm/@ezburn/linux-x64 platform-unixlike

platform-linux-ia32:
	@$(MAKE) --no-print-directory GOOS=linux GOARCH=386 NPMDIR=npm/@ezburn/linux-ia32 platform-unixlike

platform-linux-arm:
	@$(MAKE) --no-print-directory GOOS=linux GOARCH=arm NPMDIR=npm/@ezburn/linux-arm platform-unixlike

platform-linux-arm64:
	@$(MAKE) --no-print-directory GOOS=linux GOARCH=arm64 NPMDIR=npm/@ezburn/linux-arm64 platform-unixlike

platform-linux-loong64:
	@$(MAKE) --no-print-directory GOOS=linux GOARCH=loong64 NPMDIR=npm/@ezburn/linux-loong64 platform-unixlike

platform-linux-mips64el:
	@$(MAKE) --no-print-directory GOOS=linux GOARCH=mips64le NPMDIR=npm/@ezburn/linux-mips64el platform-unixlike

platform-linux-ppc64:
	@$(MAKE) --no-print-directory GOOS=linux GOARCH=ppc64le NPMDIR=npm/@ezburn/linux-ppc64 platform-unixlike

platform-linux-riscv64:
	@$(MAKE) --no-print-directory GOOS=linux GOARCH=riscv64 NPMDIR=npm/@ezburn/linux-riscv64 platform-unixlike

platform-linux-s390x:
	@$(MAKE) --no-print-directory GOOS=linux GOARCH=s390x NPMDIR=npm/@ezburn/linux-s390x platform-unixlike

platform-sunos-x64:
	@$(MAKE) --no-print-directory GOOS=illumos GOARCH=amd64 NPMDIR=npm/@ezburn/sunos-x64 platform-unixlike

platform-wasm: ezburn go-compiler
	node scripts/ezburn.js npm/ezburn-wasm/package.json --version
	$(GO_COMPILER) "$(NODE)" scripts/ezburn.js ./ezburn --wasm

platform-neutral: ezburn
	node scripts/ezburn.js npm/ezburn/package.json --version
	node scripts/ezburn.js ./ezburn --neutral

platform-deno: platform-wasm go-compiler
	$(GO_COMPILER) "$(NODE)" scripts/ezburn.js ./ezburn --deno

publish-all: check-go-version
	# Make sure the npm directory is pristine (including .gitignored files) since it will be published
	rm -fr npm && git checkout npm

	# Publish all platform-dependent packages first
	@$(MAKE) --no-print-directory publish-aix-ppc64
	@$(MAKE) --no-print-directory publish-android-arm
	@$(MAKE) --no-print-directory publish-android-arm64
	@$(MAKE) --no-print-directory publish-android-x64
	@$(MAKE) --no-print-directory publish-darwin-arm64
	@$(MAKE) --no-print-directory publish-darwin-x64
	@$(MAKE) --no-print-directory publish-freebsd-arm64
	@$(MAKE) --no-print-directory publish-freebsd-x64
	@$(MAKE) --no-print-directory publish-linux-arm
	@$(MAKE) --no-print-directory publish-linux-arm64
	@$(MAKE) --no-print-directory publish-linux-ia32
	@$(MAKE) --no-print-directory publish-linux-loong64
	@$(MAKE) --no-print-directory publish-linux-mips64el
	@$(MAKE) --no-print-directory publish-linux-ppc64
	@$(MAKE) --no-print-directory publish-linux-riscv64
	@$(MAKE) --no-print-directory publish-linux-s390x
	@$(MAKE) --no-print-directory publish-linux-x64
	@$(MAKE) --no-print-directory publish-netbsd-arm64
	@$(MAKE) --no-print-directory publish-netbsd-x64
	@$(MAKE) --no-print-directory publish-openbsd-arm64
	@$(MAKE) --no-print-directory publish-openbsd-x64
	@$(MAKE) --no-print-directory publish-openharmony-arm64
	@$(MAKE) --no-print-directory publish-sunos-x64
	@$(MAKE) --no-print-directory publish-wasi-preview1
	@$(MAKE) --no-print-directory publish-win32-arm64
	@$(MAKE) --no-print-directory publish-win32-ia32
	@$(MAKE) --no-print-directory publish-win32-x64

	# Publish platform-independent packages last to avoid race conditions
	@$(MAKE) --no-print-directory publish-neutral
	@$(MAKE) --no-print-directory publish-wasm

publish-win32-x64: platform-win32-x64
	cd npm/@ezburn/win32-x64 && npm publish

publish-win32-ia32: platform-win32-ia32
	cd npm/@ezburn/win32-ia32 && npm publish

publish-win32-arm64: platform-win32-arm64
	cd npm/@ezburn/win32-arm64 && npm publish

publish-wasi-preview1: platform-wasi-preview1
	cd npm/@ezburn/wasi-preview1 && npm publish

publish-aix-ppc64: platform-aix-ppc64
	cd npm/@ezburn/aix-ppc64 && npm publish

publish-android-x64: platform-android-x64
	cd npm/@ezburn/android-x64 && npm publish

publish-android-arm: platform-android-arm
	cd npm/@ezburn/android-arm && npm publish

publish-android-arm64: platform-android-arm64
	cd npm/@ezburn/android-arm64 && npm publish

publish-darwin-x64: platform-darwin-x64
	cd npm/@ezburn/darwin-x64 && npm publish

publish-darwin-arm64: platform-darwin-arm64
	cd npm/@ezburn/darwin-arm64 && npm publish

publish-freebsd-x64: platform-freebsd-x64
	cd npm/@ezburn/freebsd-x64 && npm publish

publish-freebsd-arm64: platform-freebsd-arm64
	cd npm/@ezburn/freebsd-arm64 && npm publish

publish-netbsd-arm64: platform-netbsd-arm64
	cd npm/@ezburn/netbsd-arm64 && npm publish

publish-netbsd-x64: platform-netbsd-x64
	cd npm/@ezburn/netbsd-x64 && npm publish

publish-openbsd-arm64: platform-openbsd-arm64
	cd npm/@ezburn/openbsd-arm64 && npm publish

publish-openbsd-x64: platform-openbsd-x64
	cd npm/@ezburn/openbsd-x64 && npm publish

publish-openharmony-arm64: platform-openharmony-arm64
	cd npm/@ezburn/openharmony-arm64 && npm publish

publish-linux-x64: platform-linux-x64
	cd npm/@ezburn/linux-x64 && npm publish

publish-linux-ia32: platform-linux-ia32
	cd npm/@ezburn/linux-ia32 && npm publish

publish-linux-arm: platform-linux-arm
	cd npm/@ezburn/linux-arm && npm publish

publish-linux-arm64: platform-linux-arm64
	cd npm/@ezburn/linux-arm64 && npm publish

publish-linux-loong64: platform-linux-loong64
	cd npm/@ezburn/linux-loong64 && npm publish

publish-linux-mips64el: platform-linux-mips64el
	cd npm/@ezburn/linux-mips64el && npm publish

publish-linux-ppc64: platform-linux-ppc64
	cd npm/@ezburn/linux-ppc64 && npm publish

publish-linux-riscv64: platform-linux-riscv64
	cd npm/@ezburn/linux-riscv64 && npm publish

publish-linux-s390x: platform-linux-s390x
	cd npm/@ezburn/linux-s390x && npm publish

publish-sunos-x64: platform-sunos-x64
	cd npm/@ezburn/sunos-x64 && npm publish

publish-wasm: platform-wasm
	cd npm/ezburn-wasm && npm publish

publish-neutral: platform-neutral
	cd npm/ezburn && npm publish

validate-build:
	@test -n "$(TARGET)" || (echo "The environment variable TARGET must be provided" && false)
	@test -n "$(PACKAGE)" || (echo "The environment variable PACKAGE must be provided" && false)
	@test -n "$(SUBPATH)" || (echo "The environment variable SUBPATH must be provided" && false)
	@echo && echo "🔷 Checking $(SCOPE)$(PACKAGE)"
	@rm -fr validate && mkdir validate
	@$(MAKE) --no-print-directory "$(TARGET)"
	@curl -s "https://registry.npmjs.org/$(SCOPE)$(PACKAGE)/-/$(PACKAGE)-$(EZBURN_VERSION).tgz" > validate/ezburn.tgz
	@cd validate && tar xf ezburn.tgz
	@ls -l "npm/$(SCOPE)$(PACKAGE)/$(SUBPATH)" "validate/package/$(SUBPATH)" && \
		shasum "npm/$(SCOPE)$(PACKAGE)/$(SUBPATH)" "validate/package/$(SUBPATH)" && \
		cmp "npm/$(SCOPE)$(PACKAGE)/$(SUBPATH)" "validate/package/$(SUBPATH)"
	@rm -fr validate

# This checks that the published binaries are bitwise-identical to the locally-build binaries
validate-builds:
	git fetch --all --tags && git checkout "v$(EZBURN_VERSION)"
	@$(MAKE) --no-print-directory TARGET=platform-aix-ppc64         SCOPE=@ezburn/ PACKAGE=aix-ppc64           SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-android-arm       SCOPE=@ezburn/ PACKAGE=android-arm         SUBPATH=ezburn.wasm validate-build
	@$(MAKE) --no-print-directory TARGET=platform-android-arm64     SCOPE=@ezburn/ PACKAGE=android-arm64       SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-android-x64       SCOPE=@ezburn/ PACKAGE=android-x64         SUBPATH=ezburn.wasm validate-build
	@$(MAKE) --no-print-directory TARGET=platform-darwin-arm64      SCOPE=@ezburn/ PACKAGE=darwin-arm64        SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-darwin-x64        SCOPE=@ezburn/ PACKAGE=darwin-x64          SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-freebsd-arm64     SCOPE=@ezburn/ PACKAGE=freebsd-arm64       SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-freebsd-x64       SCOPE=@ezburn/ PACKAGE=freebsd-x64         SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-linux-arm         SCOPE=@ezburn/ PACKAGE=linux-arm           SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-linux-arm64       SCOPE=@ezburn/ PACKAGE=linux-arm64         SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-linux-ia32        SCOPE=@ezburn/ PACKAGE=linux-ia32          SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-linux-loong64     SCOPE=@ezburn/ PACKAGE=linux-loong64       SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-linux-mips64el    SCOPE=@ezburn/ PACKAGE=linux-mips64el      SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-linux-ppc64       SCOPE=@ezburn/ PACKAGE=linux-ppc64         SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-linux-riscv64     SCOPE=@ezburn/ PACKAGE=linux-riscv64       SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-linux-s390x       SCOPE=@ezburn/ PACKAGE=linux-s390x         SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-linux-x64         SCOPE=@ezburn/ PACKAGE=linux-x64           SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-netbsd-arm64      SCOPE=@ezburn/ PACKAGE=netbsd-arm64        SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-netbsd-x64        SCOPE=@ezburn/ PACKAGE=netbsd-x64          SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-openbsd-arm64     SCOPE=@ezburn/ PACKAGE=openbsd-arm64       SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-openbsd-x64       SCOPE=@ezburn/ PACKAGE=openbsd-x64         SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-openharmony-arm64 SCOPE=@ezburn/ PACKAGE=openharmony-arm64   SUBPATH=ezburn.wasm validate-build
	@$(MAKE) --no-print-directory TARGET=platform-sunos-x64         SCOPE=@ezburn/ PACKAGE=sunos-x64           SUBPATH=bin/ezburn  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-wasi-preview1     SCOPE=@ezburn/ PACKAGE=wasi-preview1       SUBPATH=ezburn.wasm validate-build
	@$(MAKE) --no-print-directory TARGET=platform-wasm                              PACKAGE=ezburn-wasm        SUBPATH=ezburn.wasm validate-build
	@$(MAKE) --no-print-directory TARGET=platform-win32-arm64       SCOPE=@ezburn/ PACKAGE=win32-arm64         SUBPATH=ezburn.exe  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-win32-ia32        SCOPE=@ezburn/ PACKAGE=win32-ia32          SUBPATH=ezburn.exe  validate-build
	@$(MAKE) --no-print-directory TARGET=platform-win32-x64         SCOPE=@ezburn/ PACKAGE=win32-x64           SUBPATH=ezburn.exe  validate-build

clean:
	go clean -cache
	go clean -testcache
	rm -f ezburn
	rm -f npm/@ezburn/wasi-preview1/ezburn.wasm
	rm -f npm/@ezburn/win32-arm64/ezburn.exe
	rm -f npm/@ezburn/win32-ia32/ezburn.exe
	rm -f npm/@ezburn/win32-x64/ezburn.exe
	rm -f npm/ezburn-wasm/ezburn.wasm npm/ezburn-wasm/wasm_exec*.js
	rm -rf npm/@ezburn/aix-ppc64/bin
	rm -rf npm/@ezburn/android-arm/bin npm/@ezburn/android-arm/ezburn.wasm npm/@ezburn/android-arm/wasm_exec*.js
	rm -rf npm/@ezburn/android-arm64/bin
	rm -rf npm/@ezburn/android-x64/bin npm/@ezburn/android-x64/ezburn.wasm npm/@ezburn/android-x64/wasm_exec*.js
	rm -rf npm/@ezburn/darwin-arm64/bin
	rm -rf npm/@ezburn/darwin-x64/bin
	rm -rf npm/@ezburn/freebsd-arm64/bin
	rm -rf npm/@ezburn/freebsd-x64/bin
	rm -rf npm/@ezburn/linux-arm/bin
	rm -rf npm/@ezburn/linux-arm64/bin
	rm -rf npm/@ezburn/linux-ia32/bin
	rm -rf npm/@ezburn/linux-loong64/bin
	rm -rf npm/@ezburn/linux-mips64el/bin
	rm -rf npm/@ezburn/linux-ppc64/bin
	rm -rf npm/@ezburn/linux-riscv64/bin
	rm -rf npm/@ezburn/linux-s390x/bin
	rm -rf npm/@ezburn/linux-x64/bin
	rm -rf npm/@ezburn/netbsd-arm64/bin
	rm -rf npm/@ezburn/netbsd-x64/bin
	rm -rf npm/@ezburn/openbsd-arm64/bin
	rm -rf npm/@ezburn/openbsd-x64/bin
	rm -rf npm/@ezburn/openharmony-arm64/bin npm/@ezburn/openharmony-arm64/ezburn.wasm npm/@ezburn/openharmony-arm64/wasm_exec*.js
	rm -rf npm/@ezburn/sunos-x64/bin
	rm -rf npm/ezburn-wasm/esm
	rm -rf npm/ezburn-wasm/lib
	rm -rf npm/ezburn/bin npm/ezburn/lib npm/ezburn/install.js
	rm -rf require/*/bench/
	rm -rf require/*/demo/
	rm -rf require/*/node_modules/
	rm -rf require/yarnpnp/.pnp* require/yarnpnp/.yarn* require/yarnpnp/out*.js
	rm -rf validate

# This also cleans directories containing cached code from other projects
clean-all: clean
	rm -fr github demo bench

################################################################################
# These npm packages are used for benchmarks. Install them in subdirectories
# because we want to install the same package name at multiple versions

require/webpack5/node_modules:
	cd require/webpack5 && npm ci

require/rollup/node_modules:
	cd require/rollup && npm ci

require/parcel2/node_modules:
	cd require/parcel2 && npm ci

lib/node_modules:
	cd lib && npm ci

scripts/node_modules:
	cd scripts && npm ci

scripts/browser/node_modules:
	cd scripts/browser && npm ci

################################################################################
# This generates browser support mappings

compat-table: ezburn
	./ezburn compat-table/src/index.ts --bundle --platform=node --external:./compat-table/repos/* --outfile=compat-table/out.js --log-level=warning --sourcemap
	node --enable-source-maps compat-table/out.js

update-compat-table: ezburn
	cd compat-table && npm i @mdn/browser-compat-data@latest caniuse-lite@latest --silent
	./ezburn compat-table/src/index.ts --bundle --platform=node --external:./compat-table/repos/* --outfile=compat-table/out.js --log-level=warning --sourcemap
	node --enable-source-maps compat-table/out.js --update

################################################################################
# This runs the test262 official JavaScript test suite through ezburn

github/test262:
	mkdir -p github
	git clone --depth 1 https://github.com/tc39/test262.git github/test262

demo/test262: | github/test262
	mkdir -p demo/test262
	cp -r github/test262/harness demo/test262/harness
	cp -r github/test262/test demo/test262/test

test262: ezburn | demo/test262
	node --experimental-vm-modules scripts/test262.js

test262-async: ezburn | demo/test262
	node --experimental-vm-modules scripts/test262-async.js

################################################################################
# This runs UglifyJS's test suite through ezburn

github/uglify:
	mkdir -p github/uglify
	cd github/uglify && git init && git remote add origin https://github.com/mishoo/uglifyjs.git
	cd github/uglify && git fetch --depth 1 origin 860aa9531b2ce660ace8379c335bb092034b6e82 && git checkout FETCH_HEAD

demo/uglify: | github/uglify
	mkdir -p demo
	cp -r github/uglify/ demo/uglify
	cd demo/uglify && npm i

uglify: ezburn | demo/uglify
	node scripts/uglify-tests.js

################################################################################
# This builds the TypeScript compiler, then uses it to type check tsc itself

github/tsc:
	mkdir -p github/tsc
	cd github/tsc && git init && git remote add origin https://github.com/Microsoft/TypeScript.git
	cd github/tsc && git fetch --depth 1 origin e6ceba084147bd00045c573a1ba9843c0bb5c721 && git checkout FETCH_HEAD

test-tsc: ezburn | github/tsc
	rm -fr demo/tsc
	mkdir -p demo/tsc/built/local
	cp -r github/tsc/src github/tsc/scripts demo/tsc
	cp github/tsc/lib/*.d.ts demo/tsc/built/local
	cd demo/tsc && node scripts/processDiagnosticMessages.mjs src/compiler/diagnosticMessages.json
	./ezburn --bundle demo/tsc/src/tsc/tsc.ts --outfile=demo/tsc/built/local/tsc.js --platform=node --target=es2018 --packages=external
	echo '{"dependencies":{"@types/node":"20.2.5","@types/microsoft__typescript-etw":"0.1.1","@types/source-map-support":"0.5.6"}}' > demo/tsc/package.json
	cd demo/tsc && npm i --silent && echo 'Type checking tsc using tsc...' && time -p node ./built/local/tsc.js -p src/compiler

################################################################################
# This builds Rollup using ezburn and then uses it to run Rollup's test suite

TEST_ROLLUP_FIND = "compilerOptions": {

TEST_ROLLUP_REPLACE += "compilerOptions": {
TEST_ROLLUP_REPLACE += "baseUrl": ".",
TEST_ROLLUP_REPLACE += "paths": { "package.json": [".\/package.json"] },

TEST_ROLLUP_FLAGS += --bundle
TEST_ROLLUP_FLAGS += --external:fsevents
TEST_ROLLUP_FLAGS += --outfile=dist/rollup.js
TEST_ROLLUP_FLAGS += --platform=node
TEST_ROLLUP_FLAGS += --target=es6
TEST_ROLLUP_FLAGS += src/node-entry.ts

github/rollup:
	mkdir -p github
	git clone --depth 1 --branch v2.60.2 https://github.com/rollup/rollup.git github/rollup

demo/rollup: | github/rollup
	mkdir -p demo
	cp -RP github/rollup/ demo/rollup
	cd demo/rollup && npm ci

	# Patch over Rollup's custom "package.json" alias using "tsconfig.json"
	cat demo/rollup/tsconfig.json | sed 's/$(TEST_ROLLUP_FIND)/$(TEST_ROLLUP_REPLACE)/' > demo/rollup/tsconfig2.json
	mv demo/rollup/tsconfig2.json demo/rollup/tsconfig.json

test-rollup: ezburn | demo/rollup
	# Skip watch tests to avoid flakes
	cd demo/rollup && ../../ezburn $(TEST_ROLLUP_FLAGS) && npm run test:only -- --fgrep watch --invert
	cd demo/rollup && ../../ezburn $(TEST_ROLLUP_FLAGS) --minify && npm run test:only -- --fgrep watch --invert

################################################################################
# This builds Preact using ezburn with splitting enabled, which had a bug at one point

PREACT_SPLITTING += import { h } from 'preact';
PREACT_SPLITTING += import { USE as use } from 'preact/hooks';
PREACT_SPLITTING += import { renderToString } from 'preact-render-to-string';
PREACT_SPLITTING += let Component = () => (use(() => {}), h('div'));
PREACT_SPLITTING += if (renderToString(h(Component)) !== '<div></div>') throw 'fail';

PREACT_HOOKS += useCallback
PREACT_HOOKS += useContext
PREACT_HOOKS += useDebugValue
PREACT_HOOKS += useEffect
PREACT_HOOKS += useErrorBoundary
PREACT_HOOKS += useImperativeHandle
PREACT_HOOKS += useLayoutEffect
PREACT_HOOKS += useMemo
PREACT_HOOKS += useReducer
PREACT_HOOKS += useRef
PREACT_HOOKS += useState

demo/preact-splitting:
	mkdir -p demo/preact-splitting/src
	cd demo/preact-splitting && echo '{}' > package.json && npm i preact@10.4.6 preact-render-to-string@5.1.10
	cd demo/preact-splitting && for h in $(PREACT_HOOKS); do echo "$(PREACT_SPLITTING)" | sed s/USE/$$h/ > src/$$h.js; done

test-preact-splitting: ezburn | demo/preact-splitting
	cd demo/preact-splitting && rm -fr out && ../../ezburn --bundle --splitting --format=esm src/*.js --outdir=out --out-extension:.js=.mjs
	cd demo/preact-splitting && for h in $(PREACT_HOOKS); do set -e && node --experimental-modules out/$$h.mjs; done
	cd demo/preact-splitting && rm -fr out && ../../ezburn --bundle --splitting --format=esm src/*.js --outdir=out --out-extension:.js=.mjs --minify --target=node12
	cd demo/preact-splitting && for h in $(PREACT_HOOKS); do set -e && node --experimental-modules out/$$h.mjs; done

################################################################################
# This builds Sucrase using ezburn and then uses it to run Sucrase's test suite

github/sucrase:
	mkdir -p github/sucrase
	cd github/sucrase && git init && git remote add origin https://github.com/alangpierce/sucrase.git
	cd github/sucrase && git fetch --depth 1 origin a4a596e5cdd57362f309ae50cc32a235d7817d34 && git checkout FETCH_HEAD

demo/sucrase: | github/sucrase
	mkdir -p demo
	cp -r github/sucrase/ demo/sucrase
	cd demo/sucrase && npm i
	cd demo/sucrase && find test -name '*.ts' | sed 's/\(.*\)\.ts/import ".\/\1"/g' > all-tests.ts
	echo '{"compilerOptions":{"useDefineForClassFields":false}}' > demo/sucrase/tsconfig.json # Sucrase tests fail if tsconfig.json is respected due to useDefineForClassFields

test-sucrase: ezburn | demo/sucrase
	cd demo/sucrase && ../../ezburn --bundle all-tests.ts --target=es6 --platform=node > out.js && npx mocha out.js
	cd demo/sucrase && ../../ezburn --bundle all-tests.ts --target=es6 --platform=node --minify > out.js && npx mocha out.js

################################################################################
# This builds Esprima using ezburn and then uses it to run Esprima's test suite

github/esprima:
	mkdir -p github/esprima
	cd github/esprima && git init && git remote add origin https://github.com/jquery/esprima.git
	cd github/esprima && git fetch --depth 1 origin fa49b2edc288452eb49441054ce6f7ff4b891eb4 && git checkout FETCH_HEAD

demo/esprima: | github/esprima
	mkdir -p demo
	cp -r github/esprima/ demo/esprima
	cd demo/esprima && npm ci

test-esprima: ezburn | demo/esprima
	cd demo/esprima && ../../ezburn --bundle src/esprima.ts --outfile=dist/esprima.js --target=es6 --platform=node && npm run all-tests
	cd demo/esprima && ../../ezburn --bundle src/esprima.ts --outfile=dist/esprima.js --target=es6 --platform=node --minify && npm run all-tests

################################################################################
# This runs terser's test suite through ezburn

github/terser:
	mkdir -p github/terser
	cd github/terser && git init && git remote add origin https://github.com/terser/terser.git
	cd github/terser && git fetch --depth 1 origin 056623c20dbbc42d2f5a34926c07133981519326 && git checkout FETCH_HEAD

demo/terser: | github/terser
	mkdir -p demo
	cp -r github/terser/ demo/terser
	cd demo/terser && npm ci && npm run build

terser: ezburn | demo/terser
	node scripts/terser-tests.js

################################################################################
# three.js demo

github/three:
	mkdir -p github
	git clone --depth 1 --branch r108 https://github.com/mrdoob/three.js.git github/three

demo/three: | github/three
	mkdir -p demo/three
	cp -r github/three/src demo/three/src

demo-three: demo-three-ezburn demo-three-rollup demo-three-webpack5 demo-three-parcel2

demo-three-ezburn: ezburn | demo/three
	rm -fr demo/three/ezburn
	time -p ./ezburn --bundle --global-name=THREE --sourcemap --minify demo/three/src/Three.js --outfile=demo/three/ezburn/Three.ezburn.js
	du -h demo/three/ezburn/Three.ezburn.js*
	shasum demo/three/ezburn/Three.ezburn.js*

demo-three-eswasm: platform-wasm | demo/three
	rm -fr demo/three/eswasm
	time -p ./npm/ezburn-wasm/bin/ezburn --bundle --global-name=THREE \
		--sourcemap --minify demo/three/src/Three.js --outfile=demo/three/eswasm/Three.eswasm.js
	du -h demo/three/eswasm/Three.eswasm.js*
	shasum demo/three/eswasm/Three.eswasm.js*

THREE_ROLLUP_CONFIG += import terser from '@rollup/plugin-terser';
THREE_ROLLUP_CONFIG += export default {
THREE_ROLLUP_CONFIG +=   output: { format: 'iife', name: 'THREE', sourcemap: true },
THREE_ROLLUP_CONFIG +=   plugins: [terser()],
THREE_ROLLUP_CONFIG += }

demo-three-rollup: | require/rollup/node_modules demo/three
	rm -fr require/rollup/demo/three demo/three/rollup
	mkdir -p require/rollup/demo/three demo/three/rollup
	echo "$(THREE_ROLLUP_CONFIG)" > require/rollup/demo/three/config.mjs
	ln -s ../../../../demo/three/src require/rollup/demo/three/src
	ln -s ../../../../demo/three/rollup require/rollup/demo/three/out
	cd require/rollup/demo/three && time -p ../../node_modules/.bin/rollup src/Three.js -o out/Three.rollup.js -c config.mjs
	du -h demo/three/rollup/Three.rollup.js*

THREE_WEBPACK5_FLAGS += --devtool=source-map
THREE_WEBPACK5_FLAGS += --mode=production
THREE_WEBPACK5_FLAGS += --output-library THREE

demo-three-webpack5: | require/webpack5/node_modules demo/three
	rm -fr require/webpack5/demo/three demo/three/webpack5
	mkdir -p require/webpack5/demo/three demo/three/webpack5
	ln -s ../../../../demo/three/src require/webpack5/demo/three/src
	ln -s ../../../../demo/three/webpack5 require/webpack5/demo/three/out
	cd require/webpack5/demo/three && time -p ../../node_modules/.bin/webpack --entry ./src/Three.js $(THREE_WEBPACK5_FLAGS) -o out/Three.webpack5.js
	du -h demo/three/webpack5/Three.webpack5.js*

demo-three-parcel2: | require/parcel2/node_modules demo/three
	rm -fr require/parcel2/demo/three demo/three/parcel2
	mkdir -p require/parcel2/demo/three demo/three/parcel2

	# Copy the whole source tree since symlinks mess up Parcel's internal package lookup for "@babel/core"
	cp -r demo/three/src require/parcel2/demo/three/src

	echo 'import * as THREE from "./src/Three.js"; window.THREE = THREE' > require/parcel2/demo/three/Three.parcel2.js
	cd require/parcel2/demo/three && time -p ../../node_modules/.bin/parcel build \
		Three.parcel2.js --dist-dir ../../../../demo/three/parcel2 --cache-dir .cache
	du -h demo/three/parcel2/Three.parcel2.js*

################################################################################
# three.js benchmark (measures JavaScript performance, same as three.js demo but 10x bigger)

bench/three: | github/three
	mkdir -p bench/three/src
	echo > bench/three/src/entry.js
	for i in 1 2 3 4 5 6 7 8 9 10; do test -d "bench/three/src/copy$$i" || cp -r github/three/src "bench/three/src/copy$$i"; done
	for i in 1 2 3 4 5 6 7 8 9 10; do echo "import * as copy$$i from './copy$$i/Three.js'; export {copy$$i}" >> bench/three/src/entry.js; done
	echo 'Line count:' && find bench/three/src -name '*.js' | xargs wc -l | tail -n 1

bench-three: bench-three-ezburn bench-three-rollup bench-three-webpack5 bench-three-parcel2

bench-three-ezburn: ezburn | bench/three
	rm -fr bench/three/ezburn
	time -p ./ezburn --bundle --global-name=THREE --sourcemap --minify bench/three/src/entry.js --outfile=bench/three/ezburn/entry.ezburn.js --timing
	du -h bench/three/ezburn/entry.ezburn.js*
	shasum bench/three/ezburn/entry.ezburn.js*

bench-three-eswasm: platform-wasm | bench/three
	rm -fr bench/three/eswasm
	time -p ./npm/ezburn-wasm/bin/ezburn --bundle --global-name=THREE \
		--sourcemap --minify bench/three/src/entry.js --outfile=bench/three/eswasm/entry.eswasm.js
	du -h bench/three/eswasm/entry.eswasm.js*
	shasum bench/three/eswasm/entry.eswasm.js*

bench-three-rollup: | require/rollup/node_modules bench/three
	rm -fr require/rollup/bench/three bench/three/rollup
	mkdir -p require/rollup/bench/three bench/three/rollup
	echo "$(THREE_ROLLUP_CONFIG)" > require/rollup/bench/three/config.mjs
	ln -s ../../../../bench/three/src require/rollup/bench/three/src
	ln -s ../../../../bench/three/rollup require/rollup/bench/three/out
	cd require/rollup/bench/three && time -p ../../node_modules/.bin/rollup src/entry.js -o out/entry.rollup.js -c config.mjs
	du -h bench/three/rollup/entry.rollup.js*

bench-three-webpack5: | require/webpack5/node_modules bench/three
	rm -fr require/webpack5/bench/three bench/three/webpack5
	mkdir -p require/webpack5/bench/three bench/three/webpack5
	ln -s ../../../../bench/three/src require/webpack5/bench/three/src
	ln -s ../../../../bench/three/webpack5 require/webpack5/bench/three/out
	cd require/webpack5/bench/three && time -p ../../node_modules/.bin/webpack --entry ./src/entry.js $(THREE_WEBPACK5_FLAGS) -o out/entry.webpack5.js
	du -h bench/three/webpack5/entry.webpack5.js*

bench-three-parcel2: | require/parcel2/node_modules bench/three
	rm -fr require/parcel2/bench/three bench/three/parcel2
	mkdir -p require/parcel2/bench/three bench/three/parcel2

	# Copy the whole source tree since symlinks mess up Parcel's internal package lookup for "@babel/core"
	cp -r bench/three/src require/parcel2/bench/three/src

	echo 'import * as THREE from "./src/entry.js"; window.THREE = THREE' > require/parcel2/bench/three/entry.parcel2.js
	cd require/parcel2/bench/three && time -p node ../../node_modules/.bin/parcel build \
		entry.parcel2.js --dist-dir ../../../../bench/three/parcel2 --cache-dir .cache
	du -h bench/three/parcel2/entry.parcel2.js*

################################################################################
# Rome benchmark (measures TypeScript performance)

ROME_TSCONFIG += {
ROME_TSCONFIG +=   \"compilerOptions\": {
ROME_TSCONFIG +=     \"sourceMap\": true,
ROME_TSCONFIG +=     \"esModuleInterop\": true,
ROME_TSCONFIG +=     \"resolveJsonModule\": true,
ROME_TSCONFIG +=     \"moduleResolution\": \"node\",
ROME_TSCONFIG +=     \"target\": \"es2019\",
ROME_TSCONFIG +=     \"module\": \"commonjs\",
ROME_TSCONFIG +=     \"baseUrl\": \".\"
ROME_TSCONFIG +=   }
ROME_TSCONFIG += }

github/rome:
	mkdir -p github/rome
	cd github/rome && git init && git remote add origin https://github.com/romejs/rome.git
	cd github/rome && git fetch --depth 1 origin d95a3a7aab90773c9b36d9c82a08c8c4c6b68aa5 && git checkout FETCH_HEAD

bench/rome: | github/rome
	mkdir -p bench/rome
	cp -r github/rome/packages bench/rome/src
	echo "$(ROME_TSCONFIG)" > bench/rome/src/tsconfig.json
	echo 'import "rome/bin/rome"' > bench/rome/src/entry.ts

	# Patch a cyclic import ordering issue that affects commonjs-style bundlers (webpack and parcel)
	echo "export { default as createHook } from './api/createHook';" > .temp
	sed "/createHook/d" bench/rome/src/@romejs/js-compiler/index.ts >> .temp
	mv .temp bench/rome/src/@romejs/js-compiler/index.ts

	# Replace "import fs = require('fs')" with "const fs = require('fs')" because
	# the TypeScript compiler strips these statements when targeting "esnext",
	# which breaks Parcel 2 when scope hoisting is enabled.
	find bench/rome/src -name '*.ts' -type f -print0 | xargs -L1 -0 sed -i '' 's/import \([A-Za-z0-9_]*\) =/const \1 =/g'
	find bench/rome/src -name '*.tsx' -type f -print0 | xargs -L1 -0 sed -i '' 's/import \([A-Za-z0-9_]*\) =/const \1 =/g'

	# Get an approximate line count
	rm -r bench/rome/src/@romejs/js-parser/test-fixtures
	echo 'Line count:' && (find bench/rome/src -name '*.ts' && find bench/rome/src -name '*.js') | xargs wc -l | tail -n 1

# This target provides an easy way to verify that the build is correct. Since
# Rome is self-hosted, we can just run the bundle to build Rome. This makes sure
# the bundle doesn't crash when run and is a good test of a non-trivial workload.
bench/rome-verify: | github/rome
	mkdir -p bench/rome-verify
	cp -r github/rome/packages bench/rome-verify/packages
	cp github/rome/package.json bench/rome-verify/package.json

bench-rome: bench-rome-ezburn bench-rome-webpack5 bench-rome-parcel2

bench-rome-ezburn: ezburn | bench/rome bench/rome-verify
	rm -fr bench/rome/ezburn
	time -p ./ezburn --bundle --sourcemap --minify bench/rome/src/entry.ts --outfile=bench/rome/ezburn/rome.ezburn.js --platform=node --timing
	time -p ./ezburn --bundle --sourcemap --minify bench/rome/src/entry.ts --outfile=bench/rome/ezburn/rome.ezburn.js --platform=node --timing
	time -p ./ezburn --bundle --sourcemap --minify bench/rome/src/entry.ts --outfile=bench/rome/ezburn/rome.ezburn.js --platform=node --timing
	du -h bench/rome/ezburn/rome.ezburn.js*
	shasum bench/rome/ezburn/rome.ezburn.js*
	cd bench/rome-verify && rm -fr ezburn && ROME_CACHE=0 node ../rome/ezburn/rome.ezburn.js bundle packages/rome ezburn

ROME_WEBPACK5_CONFIG += module.exports = {
ROME_WEBPACK5_CONFIG +=   entry: './src/entry.ts',
ROME_WEBPACK5_CONFIG +=   mode: 'production',
ROME_WEBPACK5_CONFIG +=   target: 'node',
ROME_WEBPACK5_CONFIG +=   devtool: 'source-map',
ROME_WEBPACK5_CONFIG +=   module: { rules: [{ test: /\.ts$$/, loader: 'ts-loader', options: { transpileOnly: true } }] },
ROME_WEBPACK5_CONFIG +=   resolve: {
ROME_WEBPACK5_CONFIG +=     extensions: ['.ts', '.js'],
ROME_WEBPACK5_CONFIG +=     alias: { rome: __dirname + '/src/rome', '@romejs': __dirname + '/src/@romejs' },
ROME_WEBPACK5_CONFIG +=   },
ROME_WEBPACK5_CONFIG +=   output: { filename: 'rome.webpack.js', path: __dirname + '/out' },
ROME_WEBPACK5_CONFIG += };

bench-rome-webpack5: | require/webpack5/node_modules bench/rome bench/rome-verify
	rm -fr require/webpack5/bench/rome bench/rome/webpack5
	mkdir -p require/webpack5/bench/rome bench/rome/webpack5
	echo "$(ROME_WEBPACK5_CONFIG)" > require/webpack5/bench/rome/webpack.config.js
	ln -s ../../../../bench/rome/src require/webpack5/bench/rome/src
	ln -s ../../../../bench/rome/webpack5 require/webpack5/bench/rome/out
	cd require/webpack5/bench/rome && time -p ../../node_modules/.bin/webpack
	du -h bench/rome/webpack5/rome.webpack.js*
	cd bench/rome-verify && rm -fr webpack5 && ROME_CACHE=0 node ../rome/webpack5/rome.webpack.js bundle packages/rome webpack5

ROME_PARCEL_ALIASES += "alias": {
ROME_PARCEL_ALIASES +=   $(shell ls bench/rome/src/@romejs | sed 's/.*/"\@romejs\/&": ".\/@romejs\/&",/g')
ROME_PARCEL_ALIASES +=   "rome": "./rome"
ROME_PARCEL_ALIASES += }

bench-rome-parcel2: | require/parcel2/node_modules bench/rome bench/rome-verify
	rm -fr bench/rome/parcel2
	cp -r bench/rome/src bench/rome/parcel2
	rm -fr bench/rome/parcel2/node_modules
	cp -RP require/parcel2/node_modules bench/rome/parcel2/node_modules

	# Inject aliases into "package.json" to fix Parcel 2 ignoring "tsconfig.json".
	# Also inject "engines": "node" to avoid Parcel 2 mangling node globals.
	# Also inject "includeNodeModules": true or the aliases will be ignored.
	cat require/parcel2/package.json | sed '/^\}/d' > bench/rome/parcel2/package.json
	echo ', "engines": { "node": "14.0.0" }' >> bench/rome/parcel2/package.json
	echo ', "targets": { "main": { "includeNodeModules": true, "optimize": true } }' >> bench/rome/parcel2/package.json
	echo ', $(ROME_PARCEL_ALIASES) }' >> bench/rome/parcel2/package.json

	# Parcel's minifier preserves all comments in the source code by default.
	# Removing comments in the minified output requires a config file.
	echo '{ "format": { "comments": false } }' > bench/rome/parcel2/.terserrc

	cd bench/rome/parcel2 && time -p node_modules/.bin/parcel build entry.ts --dist-dir . --cache-dir .cache
	du -h bench/rome/parcel2/entry.js*
	cd bench/rome-verify && rm -fr parcel2 && ROME_CACHE=0 node ../rome/parcel2/entry.js bundle packages/rome parcel2

################################################################################
# React admin benchmark (measures performance of an application-like setup)

READMIN_HTML = <meta charset=utf8><div id=root></div><script src=index.js type=module></script>

github/react-admin:
	mkdir -p github
	git clone --depth 1 --branch v4.6.1 https://github.com/marmelab/react-admin.git github/react-admin

bench/readmin: | github/react-admin
	mkdir -p bench/readmin
	cp -r github/react-admin bench/readmin/repo
	cd bench/readmin/repo && yarn # This takes approximately forever

bench-readmin: bench-readmin-ezburn

READMIN_EZBURN_FLAGS += --alias:data-generator-retail=./bench/readmin/repo/examples/data-generator/src
READMIN_EZBURN_FLAGS += --alias:ra-core=./bench/readmin/repo/packages/ra-core/src
READMIN_EZBURN_FLAGS += --alias:ra-data-fakerest=./bench/readmin/repo/packages/ra-data-fakerest/src
READMIN_EZBURN_FLAGS += --alias:ra-data-graphql-simple=./bench/readmin/repo/packages/ra-data-graphql-simple/src
READMIN_EZBURN_FLAGS += --alias:ra-data-graphql=./bench/readmin/repo/packages/ra-data-graphql/src
READMIN_EZBURN_FLAGS += --alias:ra-data-simple-rest=./bench/readmin/repo/packages/ra-data-simple-rest/src
READMIN_EZBURN_FLAGS += --alias:ra-i18n-polyglot=./bench/readmin/repo/packages/ra-i18n-polyglot/src
READMIN_EZBURN_FLAGS += --alias:ra-input-rich-text=./bench/readmin/repo/packages/ra-input-rich-text/src
READMIN_EZBURN_FLAGS += --alias:ra-language-english=./bench/readmin/repo/packages/ra-language-english/src
READMIN_EZBURN_FLAGS += --alias:ra-language-french=./bench/readmin/repo/packages/ra-language-french/src
READMIN_EZBURN_FLAGS += --alias:ra-ui-materialui=./bench/readmin/repo/packages/ra-ui-materialui/src
READMIN_EZBURN_FLAGS += --alias:react-admin=./bench/readmin/repo/packages/react-admin/src
READMIN_EZBURN_FLAGS += --bundle
READMIN_EZBURN_FLAGS += --define:process.env.REACT_APP_DATA_PROVIDER=null
READMIN_EZBURN_FLAGS += --format=esm
READMIN_EZBURN_FLAGS += --loader:.png=file
READMIN_EZBURN_FLAGS += --loader:.svg=file
READMIN_EZBURN_FLAGS += --minify
READMIN_EZBURN_FLAGS += --sourcemap
READMIN_EZBURN_FLAGS += --splitting
READMIN_EZBURN_FLAGS += --target=esnext
READMIN_EZBURN_FLAGS += --timing
READMIN_EZBURN_FLAGS += bench/readmin/repo/examples/demo/src/index.tsx

bench-readmin-ezburn: ezburn | bench/readmin
	rm -fr bench/readmin/ezburn
	time -p ./ezburn $(READMIN_EZBURN_FLAGS) --outdir=bench/readmin/ezburn
	echo "$(READMIN_HTML)" > bench/readmin/ezburn/index.html
	du -h bench/readmin/ezburn/index.js*
	shasum bench/readmin/ezburn/index.js*

bench-readmin-eswasm: platform-wasm | bench/readmin
	rm -fr bench/readmin/eswasm
	time -p ./npm/ezburn-wasm/bin/ezburn $(READMIN_EZBURN_FLAGS) --outdir=bench/readmin/eswasm
	echo "$(READMIN_HTML)" > bench/readmin/eswasm/index.html
	du -h bench/readmin/eswasm/index.js*
	shasum bench/readmin/eswasm/index.js*
