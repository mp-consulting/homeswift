#!/bin/sh
# Installs Ubuntu packages, from Ubuntu's own servers or, when they fail, from a mirror outside ubuntu.com:
# GitHub's runners have at times failed to resolve every ubuntu.com name. The Dockerfile and CI's Linux job use it.
set -e
export DEBIAN_FRONTEND=noninteractive
install() { apt-get update && apt-get install -y --no-install-recommends "$@"; }
if ! install "$@"; then
    echo "Ubuntu's servers failed: trying mirrors.ocf.berkeley.edu" >&2
    sed -i -E \
        -e 's#http://([a-z]+\.)?(archive|security)\.ubuntu\.com/ubuntu#http://mirrors.ocf.berkeley.edu/ubuntu#' \
        -e 's#http://([a-z]+\.)?ports\.ubuntu\.com/ubuntu-ports#http://mirrors.ocf.berkeley.edu/ubuntu-ports#' \
        /etc/apt/sources.list.d/ubuntu.sources
    install "$@"
fi
rm -rf /var/lib/apt/lists/*
