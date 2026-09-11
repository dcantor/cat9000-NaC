#!/usr/bin/env bash
# Run the Robot Framework test suite against the lab.
#   tests/run.sh [robot options...]      e.g.  tests/run.sh --exclude internet
# Every run gets its own folder named by date and time: results/YYYY-MM-DD_HH-MM-SS/
#   configs/   running + startup config of each switch, captured before the tests
#   log.html, report.html, output.xml   Robot Framework results
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
[[ -x .venv/bin/robot ]] || { echo "error: run tests/setup.sh first" >&2; exit 1; }

ts="$(date +%Y-%m-%d_%H-%M-%S)"
out="$(cd .. && pwd)/results/$ts"
mkdir -p "$out/configs"
echo "==> results: $out"

echo "==> capturing switch configurations"
.venv/bin/python capture_configs.py "$out/configs" || echo "warning: config capture failed" >&2

echo "==> running Robot Framework suites"
.venv/bin/robot --outputdir "$out" --name "cat9000v lab" --loglevel INFO "$@" suites/
rc=$?
ln -sfn "$out" ../results/latest
echo "==> report: $out/report.html  (rc=$rc)"
exit $rc
