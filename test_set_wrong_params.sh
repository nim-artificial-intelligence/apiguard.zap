#!/usr/bin/env bash

AUTH_TOKEN=${AUTH_TOKEN:-renerocksai}

echo "Wrong parameters:"
curl \
    -X POST                                             \
    -d '{"imit":100, "delay":50}'              \
    -H "Authorization: Bearer $AUTH_TOKEN"              \
    -H "Content-Type: application/json"                 \
    http://localhost:5501/apiguard/set_rate_limit


echo "\nEmpty object:"
curl \
    -X POST                                             \
    -d '{}'              \
    -H "Authorization: Bearer $AUTH_TOKEN"              \
    -H "Content-Type: application/json"                 \
    http://localhost:5501/apiguard/set_rate_limit


