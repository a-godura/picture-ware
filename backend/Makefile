.PHONY: test lint build deploy smoke killswitch-reset tripwire-reset clean

# Smaller binaries; lambda.norpc drops the unused legacy RPC entrypoint.
export GOFLAGS := -trimpath -tags=lambda.norpc -ldflags=-s

test:
	go vet ./...
	go test ./...

lint:
	sam validate --lint

build: lint
	sam build

deploy: build
	sam deploy

smoke:
	./scripts/smoke.sh

killswitch-reset:
	./scripts/killswitch-reset.sh

tripwire-reset:
	./scripts/tripwire-reset.sh

clean:
	rm -rf .aws-sam
