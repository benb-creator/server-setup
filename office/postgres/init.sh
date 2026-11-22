#!/bin/sh
# Runs once on first start: one database and one user per service.
set -e
for app in keycloak stalwart nextcloud ejabberd; do
  password=$(printenv "$(echo "$app" | tr a-z A-Z)_DB_PASSWORD")
  psql -v ON_ERROR_STOP=1 -U postgres \
    -c "CREATE USER $app PASSWORD '$password'" \
    -c "CREATE DATABASE $app OWNER $app"
done
