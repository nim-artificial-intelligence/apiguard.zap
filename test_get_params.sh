#!/usr/bin/env bash

AUTH_TOKEN=${AUTH_TOKEN:-renerocksai}

curl -H "Authorization: Bearer $AUTH_TOKEN" http://localhost:5500/api_guard/get_rate_limit


