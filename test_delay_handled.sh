#!/usr/bin/env bash

AUTH_TOKEN=${AUTH_TOKEN:-renerocksai}

curl -H "Authorization: Bearer $AUTH_TOKEN" http://localhost:5501/apiguard/request_access\?handle_delay=true

