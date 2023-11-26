#!/usr/bin/env bash
TEST_ID=006
CLIENTS=3
REQUESTS_PER_CLIENT=500
OUTDIR=results
EVERY_N_REQUESTS=50
EVERY_N_DELAY_MS=5000

export APIGUARD_NUM_WORKERS=$CLIENTS
export APIGUARD_RATE_LIMIT=500

# this is identical for all load tests:
mkdir -p $OUTDIR
OUTFILE=$OUTDIR/l${TEST_ID}_c${CLIENTS}_r${REQUESTS_PER_CLIENT}s${EVERY_N_REQUESTS}d${EVERY_N_DELAY_MS}.json

../zig-out/bin/apiguard &
pid=$!
sleep 2
../zig-out/bin/clientbot $CLIENTS $REQUESTS_PER_CLIENT true $OUTFILE $EVERY_N_REQUESTS $EVERY_N_DELAY_MS
kill $pid
python ../plot_timeline.py $OUTFILE

