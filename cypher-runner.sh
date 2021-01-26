#!/usr/bin/env bash

# Order of execution...
#
# 1. We run the ONCE_SCRIPT on first execution (if present)
# 2. We always run the ALWAYS_SCRIPT (if present)
#
# Expects the following environment variables: -
#
#   CYPHER_PRE_ACTION_SLEEP   (default of 60 seconds if not specified)
#   CYPHER_ACTION_SLEEP       (default of 12 seconds if not specified)
#   CYPHER_ROOT
#   GRAPH_PASSWORD
#   NEO4J_dbms_directories_data
#   NEO4J_dbms_directories_logs

ME=cypher-runner.sh

# The graph user password is required as an environment variable.
# The user is expected to be 'neo4j'.
if [ -z "$GRAPH_PASSWORD" ]
then
    echo "($ME) $(date) No GRAPH_PASSWORD. Can't run without this."
    exit 0
fi

# The 'once' and 'always' cypher scripts
CYPHER_PATH="$CYPHER_ROOT/cypher-script"
ONCE_SCRIPT="$CYPHER_PATH/cypher-script.once"
ALWAYS_SCRIPT="$CYPHER_PATH/cypher-script.always"

# Files created (touched) when the 'first' script is run
# and when the 'always' script is run. These files are created
# even if there are no associated scripts. The 'always' file
# is erased each time we're executed and re-created after it's re-executed.
ONCE_EXECUTED_FILE="$CYPHER_PATH/once.executed"
ALWAYS_EXECUTED_FILE="$CYPHER_PATH/always.executed"

# Always remove the ALWAYS_EXECUTED_FILE.
# We re-create this when we've run the always script
# (which happens every time we start)
rm -f "$ALWAYS_EXECUTED_FILE" || true

PRE_ACTION_SLEEP_TIME=${CYPHER_PRE_ACTION_SLEEP:-60}
ACTION_SLEEP_TIME=${CYPHER_ACTION_SLEEP:-12}

echo "($ME) $(date) NEO4J_dbms_directories_data=$NEO4J_dbms_directories_data"
echo "($ME) $(date) NEO4J_dbms_directories_logs=$NEO4J_dbms_directories_logs"
echo "($ME) $(date) GRAPH_PASSWORD=$GRAPH_PASSWORD"
echo "($ME) $(date) ONCE_SCRIPT=$ONCE_SCRIPT"
echo "($ME) $(date) ALWAYS_SCRIPT=$ALWAYS_SCRIPT"
echo "($ME) $(date) ONCE_EXECUTED_FILE=$ONCE_EXECUTED_FILE"
echo "($ME) $(date) ALWAYS_EXECUTED_FILE=$ALWAYS_EXECUTED_FILE"
echo "($ME) $(date) PRE_ACTION_SLEEP_TIME=$PRE_ACTION_SLEEP_TIME"
echo "($ME) $(date) ACTION_SLEEP_TIME=$ACTION_SLEEP_TIME"

# Configurable sleep prior to the first cypher command.
# Needs to be sufficient to allow the server to start accepting connections.
echo "($ME) $(date) Pre-action sleep ($PRE_ACTION_SLEEP_TIME seconds)..."
sleep "$PRE_ACTION_SLEEP_TIME"

# The graph service has not started if there's no debug file.
DEBUG_FILE="$NEO4J_dbms_directories_logs/debug.log"
echo "($ME) $(date) Checking $DEBUG_FILE..."
until [ -f "$DEBUG_FILE" ]; do
  echo "($ME) $(date) Waiting for $DEBUG_FILE..."
  sleep "$ACTION_SLEEP_TIME"
done

# Wait until a 'ready' line exists in the debug log...
echo "($ME) $(date) Checking ready line in $DEBUG_FILE..."
READY=$(grep -c "Database graph.db is ready." < "$DEBUG_FILE")
until [ "$READY" -eq "1" ]; do
  echo "($ME) $(date) Waiting for ready line in $DEBUG_FILE..."
  sleep "$ACTION_SLEEP_TIME"
  READY=$(grep -c "Database graph.db is ready." < "$DEBUG_FILE")
done

echo "($ME) $(date) Post ready pause..."
sleep "$ACTION_SLEEP_TIME"

# Must wait for the 'auth' file.
# If we continue when this isn't present
# then the password will fail to be set.
echo "($ME) $(date) Checking $NEO4J_dbms_directories_data/dbms/auth..."
until [ -f "$NEO4J_dbms_directories_data/dbms/auth" ]; do
  echo "($ME) $(date) Waiting for $NEO4J_dbms_directories_data/dbms/auth..."
  sleep "$ACTION_SLEEP_TIME"
done

echo "($ME) $(date) Pre password pause..."
sleep "$ACTION_SLEEP_TIME"

# Attempt to change the initial password...
# ...but only if it looks like it's already been done.
#
# i.e. if the 'dbms/auth' file contains 'password_change_required'.
# i.e. if it looks like this...
#
#  'neo4j:SHA-256,C84A[...]:password_change_required'
#
# Note: There's a race-condition here. If we do this too early
#       it's effect is lost - it must be done once we believe
#       the DB is running. So CYPHER_PRE_NEO4J_SLEEP must be long enough
#       to ensure the graph is running.
NEEDS_PASSWORD=$(grep -c password_change_required < "$NEO4J_dbms_directories_data/dbms/auth")
if [ "$NEEDS_PASSWORD" -eq "1" ]; then
  echo "($ME) $(date) Setting neo4j password..."
  /var/lib/neo4j/bin/cypher-shell -u neo4j -p neo4j "CALL dbms.changePassword('$GRAPH_PASSWORD')" || true
fi

# Wait for the password change
echo "($ME) $(date) Checking neo4j password..."
NEEDS_PASSWORD=$(grep -c password_change_required < "$NEO4J_dbms_directories_data/dbms/auth")
until [ "$NEEDS_PASSWORD" -eq "0" ]; do
  echo "($ME) $(date) Waiting for neo4j password..."
  sleep "$ACTION_SLEEP_TIME"
  NEEDS_PASSWORD=$(grep -c password_change_required < "$NEO4J_dbms_directories_data/dbms/auth")
done

# Forced sleep
echo "($ME) $(date) Post password pause..."
sleep 4

# Run the ONCE_SCRIPT
# (if the ONCE_EXECUTED_FILE is not present)...
if [[ ! -f "$ONCE_EXECUTED_FILE" && -f "$ONCE_SCRIPT" ]]; then
    echo "($ME) $(date) Trying $ONCE_SCRIPT..."
    echo "[SCRIPT BEGIN]"
    cat "$ONCE_SCRIPT"
    echo "[SCRIPT END]"
    until /var/lib/neo4j/bin/cypher-shell -u neo4j -p "$GRAPH_PASSWORD" < "$ONCE_SCRIPT"
    do
        echo "($ME) $(date) No joy, waiting..."
        sleep "$ACTION_SLEEP_TIME"
    done
    echo "($ME) $(date) .once script executed."
else
    echo "($ME) $(date) No .once script (or not first incarnation)."
fi
echo "($ME) $(date) Touching $ONCE_EXECUTED_FILE..."
touch "$ONCE_EXECUTED_FILE"

# Always run the ALWAYS_SCRIPT...
if [ -f "$ALWAYS_SCRIPT" ]; then
    echo "($ME) $(date) Trying $ALWAYS_SCRIPT..."
    echo "[SCRIPT BEGIN]"
    cat "$ALWAYS_SCRIPT"
    echo "[SCRIPT END]"
    until /var/lib/neo4j/bin/cypher-shell -u neo4j -p "$GRAPH_PASSWORD" < "$ALWAYS_SCRIPT"
    do
        echo "($ME) $(date) No joy, waiting..."
        sleep "$ACTION_SLEEP_TIME"
    done
    echo "($ME) $(date) .always script executed."
else
    echo "($ME) $(date) No .always script."
fi
echo "($ME) $(date) Touching $ALWAYS_EXECUTED_FILE..."
touch "$ALWAYS_EXECUTED_FILE"

echo "($ME) $(date) Finished."
