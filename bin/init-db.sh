#!/bin/bash
# Copyright (C) 2020-2026 Wicked Co-op LCA
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

#source ./.env
#printenv | grep POSTGRES

SR_SERVICES=("ORCHESTRATOR" "USERS" "GROUPS" "NOTES" "RESPONSES" "NOTIFICATIONS" "CONNECTIONS")
#GET installed submodules modules to execute migrations
SR_MIGRATION_PATH="./modules/SR_MODULE_FOLDER/scripts/migrate.sh"

#TODO: How to not depend on this hardcoded module naming?
SR_MODULE_DIR_PREFIX="RS-"
SR_MODULES=$(ls ./modules/ | grep $SR_MODULE_DIR_PREFIX)

export PGPASSWORD="$POSTGRES_PASSWORD"
for service in "${SR_SERVICES[@]}"
do
  DB_ENV_NAME="DB_NAME_$service"
  DB_NAME=${!DB_ENV_NAME}
  psql -U "$POSTGRES_USER" -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -w "$POSTGRES_DB" \
      -c "CREATE DATABASE \"$DB_NAME\";" \
      -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" to \"$POSTGRES_USER\";"
  echo "$DB_NAME... done!"
done

echo "=== Checking modules for migrations ==="
echo "MODULES: $SR_MODULES"
echo "======================================="
export POSTGRES_HOST=$POSTGRES_HOST
export POSTGRES_PORT=$POSTGRES_PORT
export POSTGRES_USER=$POSTGRES_USER
export POSTGRES_PASSWORD=$POSTGRES_PASSWORD
for module in $SR_MODULES
do
  DB_ENV_NAME="DB_NAME_${module/$SR_MODULE_DIR_PREFIX/}"
  export POSTGRES_DB_NAME=${!DB_ENV_NAME}
  echo "=> MIGRATING $module INTO $POSTGRES_DB_NAME"
  eval "${SR_MIGRATION_PATH/SR_MODULE_FOLDER/$module} migrate"
done
