#!/bin/bash
export KONG_NGINX_DAEMON=off
kong migrations bootstrap -c /usr/local/kong/kong.conf --vv
kong  migrations up -c /usr/local/kong/kong.conf --vv
kong reload -c /usr/local/kong/kong.conf --vv
kong restart -c /usr/local/kong/kong.conf --vv