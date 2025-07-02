#!/bin/bash
source ./.env
#printenv | grep POSTGRES

DB_PREFIX="SR-"
SR_SERVICES=("ORCHESTRATOR" "USERS" "GROUPS" "NOTES" "RESPONSES" "NOTIFICATIONS" "CONNECTIONS")
#GET installed submodules modules to execute migrations
SR_MIGRATION_PATH="./modules/SR_MODULE_FOLDER/scripts/migrate.sh"
SR_MODULE_DIR_PREFIX="RS-"
SR_MODULES=$(ls -N ./modules/ | grep $SR_MODULE_DIR_PREFIX)

export PGPASSWORD="$POSTGRES_PASSWORD"
for service in "${SR_SERVICES[@]}"
do
  DB_NAME=$DB_PREFIX"$service"
  psql -U "$POSTGRES_USER" -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -w "socialroots-default" \
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
   export POSTGRES_DB_NAME=$DB_PREFIX${module/$SR_MODULE_DIR_PREFIX/}
   echo "=> MIGRATING $module INTO $POSTGRES_DB_NAME"
   eval "${SR_MIGRATION_PATH/SR_MODULE_FOLDER/$module} migrate"
done