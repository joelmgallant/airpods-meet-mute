#!/bin/bash
# Regenerates the press feedback sounds in Support/Sounds with ffmpeg.
# Mute = high→low (G5→C5), Unmute = low→high (C5→G5); soft sine, ~0.3 s.
set -euo pipefail
cd "$(dirname "$0")/.."

two_notes() {  # first_hz second_hz output
    local first="$1" second="$2" output="$3"
    local first_note="sin(2*PI*${first}*t)*min(1,t/0.004)*exp(-t*28)"
    local second_note="sin(2*PI*${second}*(t-0.09))*min(1,(t-0.09)/0.004)*exp(-(t-0.09)*22)"
    ffmpeg -loglevel error -y -f lavfi \
        -i "aevalsrc='0.45*(if(lt(t,0.09),${first_note},0)+if(gte(t,0.09),${second_note},0))':s=44100:d=0.32" \
        "$output"
}

two_notes 784 523.25 Support/Sounds/Mute.wav
two_notes 523.25 784 Support/Sounds/Unmute.wav
echo "Wrote Support/Sounds/Mute.wav and Support/Sounds/Unmute.wav"
