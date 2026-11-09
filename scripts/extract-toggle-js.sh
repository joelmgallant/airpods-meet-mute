#!/bin/bash
# Prints MeetToggleJS.source (the JS function expression) from the Swift source.
set -euo pipefail
cd "$(dirname "$0")/.."
awk '/^    public static let source = #"""$/ {inside=1; next} /^    """#$/ {inside=0} inside' Sources/MeetMuteCore/MeetToggleJS.swift
