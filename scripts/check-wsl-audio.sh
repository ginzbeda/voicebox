#!/usr/bin/env bash
# Report whether this machine can play and record audio, and say what to do if not.
#
# Voicebox generates audio server-side but never plays it — playback is the client's
# job. Under WSL that client has no sound card of its own: it depends on WSLg, which
# publishes a PulseAudio socket at /mnt/wslg/PulseServer. When WSLg is missing or was
# built without audio, every player fails with a different misleading error (sox says
# "no default audio device configured", ffplay blames ALSA), so this script probes each
# layer in order and names the first one that is actually broken.
#
# Exit status: 0 both directions work, 1 output broken, 2 output works but capture does
# not. Safe to run anywhere — it only reads, and the probes are silent and sub-second.
set -uo pipefail

pass=0 out_ok=0 in_ok=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }

say "== platform =="
if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    is_wsl=1
    ok "WSL ($(uname -r))"
else
    is_wsl=0
    warn "not WSL — this script is written for WSL, results may be uninteresting"
fi

say
say "== WSLg =="
if [ "$is_wsl" = 1 ]; then
    if [ -S /mnt/wslg/PulseServer ]; then
        ok "/mnt/wslg/PulseServer socket present"
        pass=1
    elif [ -d /mnt/wslg ]; then
        bad "/mnt/wslg exists but has no PulseServer socket"
        say "        contents: $(ls -A /mnt/wslg 2>/dev/null | tr '\n' ' ')"
    else
        bad "/mnt/wslg missing entirely — WSLg is not running"
    fi
fi

say
say "== kernel sound devices =="
if [ -d /dev/snd ] && ls /dev/snd 2>/dev/null | grep -qv '^\(timer\|seq\|user\)$'; then
    ok "/dev/snd: $(ls /dev/snd | tr '\n' ' ')"
else
    # timer/seq/user are stubs the kernel always creates; a real card adds pcm*/control*.
    warn "/dev/snd has no PCM devices: $(ls /dev/snd 2>/dev/null | tr '\n' ' ' || echo '(absent)')"
fi

say
say "== pulseaudio client =="
for bin in pactl paplay parec sox ffplay; do
    if command -v "$bin" >/dev/null 2>&1; then ok "$bin"; else warn "$bin not installed"; fi
done
say "        PULSE_SERVER=${PULSE_SERVER:-(unset)}"
if command -v pactl >/dev/null 2>&1; then
    if info=$(timeout 5 pactl info 2>&1); then
        ok "pactl info: $(printf '%s' "$info" | grep -i '^Server Name' | cut -d: -f2- | xargs)"
        say "        default sink:   $(printf '%s' "$info" | grep -i '^Default Sink'   | cut -d: -f2- | xargs)"
        say "        default source: $(printf '%s' "$info" | grep -i '^Default Source' | cut -d: -f2- | xargs)"
    else
        bad "pactl info failed: $(printf '%s' "$info" | head -1)"
    fi
fi

say
say "== playback probe =="
# Generate a short, near-silent tone rather than shipping a fixture wav.
probe=$(mktemp -t voicebox-probe-XXXXXX.wav)
trap 'rm -f "$probe"' EXIT
if command -v sox >/dev/null 2>&1 && sox -n "$probe" synth 0.15 sine 440 vol 0.02 2>/dev/null; then
    for player in paplay "ffplay -nodisp -autoexit -loglevel error" aplay afplay; do
        bin=${player%% *}
        command -v "$bin" >/dev/null 2>&1 || continue
        err=$(timeout 10 $player "$probe" 2>&1)
        rc=$?
        # ffplay exits 0 even when SDL cannot open the output device, so an exit code
        # alone will happily report success into a dead sink. Every player names the
        # failure on stderr, so treat any such line as authoritative over $?.
        if [ "$rc" = 0 ] && ! printf '%s' "$err" | grep -qiE "couldn't open|could not open|cannot open|no such (audio )?device|no default|audio open failed|connection refused"; then
            ok "played via $bin"
            out_ok=1
            break
        fi
        # Prefer the device-open error over whatever the player says afterwards; ffplay
        # follows "ALSA: Couldn't open audio device" with a generic filtergraph failure
        # that tells you nothing about the real cause.
        detail=$(printf '%s' "$err" | grep -iE "couldn't open|could not open|cannot open|no such (audio )?device|no default|audio open failed" | head -1)
        bad "$bin: ${detail:-$(printf '%s' "$err" | tail -1)}"
    done
    [ "$out_ok" = 1 ] || bad "no working audio output"
else
    warn "sox unavailable — cannot build a probe tone, skipping playback test"
fi

say
say "== capture probe (needed by Claude Code /voice) =="
# Opening the device successfully is not the same as receiving audio. Under
# WSLg the RDP source connects happily and then delivers digital silence when
# Windows' default recording device is one the host cannot tap — a virtual
# mixer output, typically. Dictation then reports "no speech detected" while
# every layer here looks healthy, so measure the samples rather than the exit
# status.
if command -v sox >/dev/null 2>&1; then
    cap=$(mktemp -t voicebox-capture-XXXXXX.wav)
    if err=$(timeout 10 sox -d "$cap" trim 0 1 2>&1) && ! printf '%s' "$err" | grep -qi 'fail\|no default'; then
        peak=$(sox "$cap" -n stat 2>&1 | awk '/Maximum amplitude/ {print $3}')
        # Room tone on a live mic sits well above this; a dead channel is ~1e-5.
        if awk -v p="${peak:-0}" 'BEGIN {exit !(p > 0.0005)}'; then
            ok "captured 1s from the default input (peak amplitude $peak)"
            in_ok=1
        else
            bad "input device opens but delivers SILENCE (peak amplitude ${peak:-0})"
            say "        The capture path is connected, so this is upstream of Linux."
            say "        On WSL: set the Windows default recording device to a physical"
            say "        microphone. WSLg cannot capture from most virtual mixer outputs"
            say "        (VoiceMeeter, VB-Cable, VAIO), which yields exactly this result."
        fi
    else
        bad "sox capture: $(printf '%s' "$err" | tail -1)"
    fi
    rm -f "$cap"
else
    warn "sox not installed — Claude Code /voice requires it"
fi

say
say "== verdict =="
if [ "$out_ok" = 1 ] && [ "$in_ok" = 1 ]; then
    say "  Audio works both ways. Voicebox playback and Claude Code /voice should both function."
    exit 0
fi

if [ "$out_ok" != 1 ]; then
    say "  NO AUDIO OUTPUT — Voicebox will generate speech you cannot hear."
else
    say "  Output works, but there is NO CAPTURE DEVICE — Claude Code /voice will refuse to start."
fi

if [ "$is_wsl" = 1 ] && [ "$pass" != 1 ]; then
    cat <<'EOF'

  Cause: WSLg is not providing a PulseAudio server. To restore it:

    1. On Windows, add to %USERPROFILE%\.wslconfig:

         [wsl2]
         guiApplications=true

    2. In WSL:  sudo apt install -y pulseaudio-utils libpulse0 sox
    3. On Windows:  wsl --shutdown        (this stops every distro and container)
    4. Reopen WSL and run this script again.

  Reverting is the same edit with guiApplications=false plus another shutdown.
EOF
fi
[ "$out_ok" = 1 ] && exit 2 || exit 1
