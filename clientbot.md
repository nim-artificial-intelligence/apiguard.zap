# ClientBot

The clientbot allows for flexible testing of the server.

### Building it

The bot gets built along with the server when you run `zig build`.

### Running it

You run it from the commandline:

```console
Usage: clientbot num-threads requests-per-thread handle_delay outfile [n (requests)] [sleep_ms]

 num-threads          : how many clients should be simulated; 1 thread per client
 requests-per-thread  : how many requests should each client make
 handle_delay         : whether `?handle_delay=true` should be passed to force server_side_delay
 outfile              : filename to write the JSON output to
 n (requests)         : OPTIONAL: let client sleep every n requests
 sleep_ms             : OPTIONAL: if n: how long the client should sleep
```

### Pre-Configured runs

Check out the [load_tests](./load_tests/) folder for scripts and its
[results](./load_tests/results/) folder for the generated results. It contains
pre-configured load-tests. They all follow the following format:

```bash
#!/usr/bin/env bash
TEST_ID=005
CLIENTS=2
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

```
