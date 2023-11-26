#!/usr/bin/env bash
TEST_ID=004
CLIENTS=10
REQUESTS_PER_CLIENT=500
OUTDIR=results

export APIGUARD_NUM_WORKERS=$CLIENTS
export APIGUARD_RATE_LIMIT=500

# this is identical for all load tests:
mkdir -p $OUTDIR
OUTFILE=$OUTDIR/l${TEST_ID}_c${CLIENTS}_r${REQUESTS_PER_CLIENT}.json

../zig-out/bin/apiguard &
pid=$!
sleep 2
../zig-out/bin/clientbot $CLIENTS $REQUESTS_PER_CLIENT true $OUTFILE
kill $pid
python ../plot_timeline.py $OUTFILE

