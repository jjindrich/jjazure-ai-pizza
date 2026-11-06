#!/bin/bash
set -e

environment_values=$(azd env get-values)
while IFS= read -r line; do
  [ -n "$line" ] || continue
  key=${line%%=*}
  value=${line#*=}
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
    \'*\') value=${value#\'}; value=${value%\'} ;;
  esac
  export "$key=$value"
done <<< "$environment_values"

if [ -z "${SQL_SERVER:-}" ] || [ -z "${SQL_DATABASE:-}" ]; then
  echo "ERROR: SQL_SERVER and SQL_DATABASE must be set in the azd environment." >&2
  exit 1
fi

if ! command -v sqlcmd >/dev/null 2>&1; then
  echo "ERROR: 'sqlcmd' is not installed or not on PATH. Install the modern go-sqlcmd tool." >&2
  exit 1
fi

sqlcmd \
  -S "${SQL_SERVER}.database.windows.net" \
  -d "$SQL_DATABASE" \
  --authentication-method ActiveDirectoryDefault \
  -i ./infra/sql/schema.sql

./scripts/grant-sql-access.sh
