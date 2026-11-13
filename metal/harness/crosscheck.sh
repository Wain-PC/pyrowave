#!/bin/bash
# Cross-checks the Metal port against upstream's Vulkan reference tools.
#
# For every test clip it Metal-encodes through each input path, decodes the result
# with both the Metal and the Vulkan decoder, and reports PSNR against the source
# and between the two decoders. Where the Vulkan encoder runs it also checks the
# opposite direction.
#
# usage: crosscheck.sh <pwmetal> <vkref build dir> <work dir> [profile ...]
#   profiles: 420-8 444-8 420-10 444-10 (default: all four)
#
# Needs ffmpeg. On macOS the Vulkan tools run through MoltenVK (Homebrew molten-vk and
# vulkan-loader). The loader path is set here, not by the caller, because macOS strips
# DYLD_* variables when a script is started through /bin/bash.
set -u

if [ "$(uname)" = Darwin ]; then
	BREW_PREFIX=${HOMEBREW_PREFIX:-/opt/homebrew}
	export VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-$BREW_PREFIX/etc/vulkan/icd.d/MoltenVK_icd.json}
	export DYLD_FALLBACK_LIBRARY_PATH=${DYLD_FALLBACK_LIBRARY_PATH:-$BREW_PREFIX/lib}
fi

PWMETAL=$1
VKREF=$2
WORK=$3
shift 3
PROFILES=${*:-420-8 444-8 420-10 444-10}

mkdir -p "$WORK"
cd "$WORK" || exit 1

FAILURES=0
# Lowest acceptable PSNR (dB) between the two decoders on the same stream.
MIN_DECODER_AGREEMENT=${MIN_DECODER_AGREEMENT:-60}

psnr() {
	ffmpeg -hide_banner -nostats -i "$1" -i "$2" -lavfi psnr -f null - 2>&1 |
		sed -n 's/.*average:\([0-9.a-z]*\).*/\1/p' | tail -1
}

pix_fmt() {
	case $1 in
	420-8) echo yuv420p ;;
	444-8) echo yuv444p ;;
	420-10) echo yuv420p10le ;;
	444-10) echo yuv444p10le ;;
	esac
}

# profile, name, lavfi source, size, optional video filter
make_clip() {
	local profile=$1 name=$2 source=$3 size=$4 filter=${5:-null}
	local out="src_${name}_${size}_${profile}.y4m"
	[ -f "$out" ] || ffmpeg -hide_banner -loglevel error -y -f lavfi -i "${source}=size=${size}:rate=60" \
		-vf "$filter" -frames:v 4 -pix_fmt "$(pix_fmt "$profile")" -color_range tv -strict -1 "$out"
	echo "$out"
}

check() {
	local label=$1 value=$2 minimum=$3
	if [ -z "$value" ]; then
		echo "    FAIL  $label: no result"
		FAILURES=$((FAILURES + 1))
	elif [ "$value" != inf ] && [ "$(echo "$value < $minimum" | bc -l)" = 1 ]; then
		echo "    FAIL  $label: $value dB (minimum $minimum)"
		FAILURES=$((FAILURES + 1))
	else
		echo "    ok    $label: $value dB"
	fi
}

run_clip() {
	local profile=$1 clip=$2 bytes=$3
	local base=${clip%.y4m}_$bytes
	echo "  $clip @ $bytes bytes/frame"

	local inputs="surface"
	case $profile in *-8) inputs="cpu surface" ;; esac

	for input in $inputs; do
		local stream="${base}_metal_${input}.pyrowave"
		if ! "$PWMETAL" encode "$clip" "$stream" "$bytes" "$input" 2>/dev/null; then
			echo "    FAIL  Metal encode ($input)"
			FAILURES=$((FAILURES + 1))
			continue
		fi

		"$PWMETAL" decode "$stream" "${stream%.pyrowave}__metal.y4m" 2>/dev/null
		"$VKREF/pyrowave-decode" "$stream" "${stream%.pyrowave}__vulkan.y4m" >/dev/null 2>&1

		echo "    Metal encode ($input): source vs Metal decode $(psnr "$clip" "${stream%.pyrowave}__metal.y4m") dB," \
			"source vs Vulkan decode $(psnr "$clip" "${stream%.pyrowave}__vulkan.y4m") dB"
		check "Metal vs Vulkan decoder on the Metal stream ($input)" \
			"$(psnr "${stream%.pyrowave}__metal.y4m" "${stream%.pyrowave}__vulkan.y4m")" "$MIN_DECODER_AGREEMENT"
	done

	local stream="${base}_vulkan.pyrowave"
	if "$VKREF/pyrowave-encode" "$clip" "$stream" "$bytes" >/dev/null 2>&1 && [ -s "$stream" ] &&
		[ "$(wc -c <"$stream")" -gt 100 ]; then
		"$PWMETAL" decode "$stream" "${stream%.pyrowave}__metal.y4m" 2>/dev/null
		"$VKREF/pyrowave-decode" "$stream" "${stream%.pyrowave}__vulkan.y4m" >/dev/null 2>&1
		echo "    Vulkan encode: source vs Metal decode $(psnr "$clip" "${stream%.pyrowave}__metal.y4m") dB," \
			"source vs Vulkan decode $(psnr "$clip" "${stream%.pyrowave}__vulkan.y4m") dB"
		check "Metal vs Vulkan decoder on the Vulkan stream" \
			"$(psnr "${stream%.pyrowave}__metal.y4m" "${stream%.pyrowave}__vulkan.y4m")" "$MIN_DECODER_AGREEMENT"
	else
		echo "    skip  Vulkan encoder unavailable on this driver"
	fi
}

for profile in $PROFILES; do
	echo "== $profile"
	# A smooth synthetic pattern, a noisy one that stresses rate control, and odd sizes.
	run_clip "$profile" "$(make_clip "$profile" testsrc2 testsrc2 1920x1080)" 400000
	run_clip "$profile" "$(make_clip "$profile" testsrc2 testsrc2 1920x1080)" 60000
	run_clip "$profile" "$(make_clip "$profile" mandelbrot mandelbrot 3840x2160)" 1500000
	run_clip "$profile" "$(make_clip "$profile" noise testsrc2 1280x720 "noise=alls=30:allf=t+u")" 150000
	run_clip "$profile" "$(make_clip "$profile" odd testsrc2 1366x768)" 200000
done

rm -f ./*__metal.y4m ./*__vulkan.y4m
echo
if [ "$FAILURES" -eq 0 ]; then
	echo "All checks passed."
else
	echo "$FAILURES check(s) failed."
fi
exit "$FAILURES"
