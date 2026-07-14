#!/bin/bash -e

if [ "$ARG_DEBUG" != "false" ]; then
	set -x
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source "$SCRIPT_DIR/utils.sh"

echo "Cloning and checking out $ARG_REPOSITORY:$ARG_BRANCH in $ARG_CHECKOUT_LOCATION"

mkdir -p "$ARG_CHECKOUT_LOCATION"
cd "$ARG_CHECKOUT_LOCATION"

__mutex_queue_file=mutex_queue
__repo_url="https://x-access-token:$ARG_REPO_TOKEN@$ARG_GITHUB_SERVER/$ARG_REPOSITORY"

# Strip commas/whitespace AND backslashes: a literal backslash in the ticket would
# survive to awk and break field matching (awk sees it as an escape). The trailing
# '\\' in the single-quoted set is one backslash char handed to tr.
__suffix=$(printf '%s' "$ARG_TICKET_ID_SUFFIX" | tr -d ', \t\r\n\\')
__ticket_id="$GITHUB_RUN_ID-$(date +%s)-$(( RANDOM % 1000 ))-$__suffix"
echo "ticket_id=$__ticket_id" >> "$GITHUB_STATE"

# Self-describing line lets any waiter check the holder's run-attempt status.
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/${GITHUB_RUN_ATTEMPT:-1}"

set_up_repo "$__repo_url"
enqueue "$ARG_BRANCH" "$__mutex_queue_file" "$__ticket_id"
wait_for_lock "$ARG_BRANCH" "$__mutex_queue_file" "$__ticket_id"

echo "Lock successfully acquired"
