REGISTRY ?= ssoonan0770
VERSION ?= latest

.PHONY: build push 

all: build 

build:
	docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/jitter-producer:$(VERSION) ./producer --push
	docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/jitter-consumer:$(VERSION) ./consumer --push

run-local:
	cd consumer && go run main.go &1
	sleep 2
	cd producer && TARGET_ADDRESS=localhost:8080 go run main.go