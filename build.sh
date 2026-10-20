#!/bin/sh
set -eu
cd "$(dirname "$0")"
SWIFTC=${SWIFTC:-/usr/bin/swiftc}
"$SWIFTC" -swift-version 6 -Osize -wmo -warnings-as-errors \
  -Xlinker -dead_strip git-wt-add.swift -o git-wt-add
strip -x git-wt-add
ls -l git-wt-add | awk '{print "built git-wt-add (" $5 " bytes)"}'
