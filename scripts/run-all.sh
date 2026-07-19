#!/bin/sh

run_libreqos=0
for arg in "$@"; do
	case "$arg" in
		--libreqos)
			run_libreqos=1
			;;
		--help|-h)
			echo "Usage: ./scripts/run-all.sh [--libreqos]"
			exit 0
			;;
	esac
done

echo "=== Running all QoO testbed scripts ==="

echo "=== Running godash.sh (local) ==="
./run-godash.sh quic || echo "WARN: run-godash.sh failed"

echo "=== Running active probes (local) ==="
./run-active-probes.sh || echo "WARN: run-active-probes.sh failed"

echo "=== Running network quality test (local) ==="
./run-network-quality.sh || echo "WARN: run-network-quality.sh failed"

if [ "$run_libreqos" -eq 1 ]; then
	echo "=== Running libreqos-test.sh (needs Internet) ==="
	./run-libreqos-test.sh || echo "WARN: run-libreqos-test.sh failed"
else
	echo "=== Skipping libreqos-test.sh (pass --libreqos to enable) ==="
fi