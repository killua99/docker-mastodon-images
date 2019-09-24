#!/bin/sh

CONTAINER_ALREADY_STARTED="CONTAINER_ALREADY_STARTED_PLACEHOLDER"
if [[ ! -e $CONTAINER_ALREADY_STARTED ]]; then
    touch $CONTAINER_ALREADY_STARTED
    echo "-- First container startup --"

    bundle install -j $(nproc) --deployment --without development test
    yarn install --pure-lockfile

fi
