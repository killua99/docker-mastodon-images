#!/usr/bin/env bash

set -e

MASTODON_VERSION="v${1:-2.9.3}"
TAG="${1:-latest}"

cat <<EOF

We're about to build docker 🚢 image for the next platforms:

    - linux/amd64
    - linux/arm64
    - linux/arm/v7

If you wish to build for only one platform please ask for help: ``./build.sh --help (-h)``

EOF

time docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -t killua99/mastodon-alpine:${TAG} . --push
