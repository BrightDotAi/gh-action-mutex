# Queue line format: TICKET,RUN_URL,ENQ_EPOCH[,ACQ_EPOCH]. Everything keys on
# field 1 (the ticket); an old-format line with no commas has field 1 == whole
# line, so old and new versions coexist safely on the same lock branch.

# Set up the mutex repo
# args:
#   $1: repo_url
set_up_repo() {
	__repo_url=$1

	git init --quiet
	git config --local user.name "github-bot" --quiet
	git config --local user.email "github-bot@users.noreply.github.com" --quiet
	git remote remove origin 2>/dev/null || true
	git remote add origin "$__repo_url"
}

# Update the branch to the latest from the remote. Or checkout to an orphan branch
# if the remote branch genuinely doesn't exist yet.
#
# A bare `git fetch ... || true` cannot tell "branch doesn't exist" apart from a
# transient failure (network blip, auth hiccup, rate limit). Treating both the
# same silently swaps in an empty orphan branch on a transient error, which is
# safe for enqueue() (a rejected push there just triggers its own retry) but
# fatal for dequeue(): it has no retry, so it hits its "not in queue" branch and
# exits without ever removing the real ticket from the real remote queue --
# permanently deadlocking every other caller waiting on this branch.
# args:
#   $1: branch
update_branch() {
	__branch=$1
	__attempt=0
	__max_attempts=5

	# Entropy in the throwaway name avoids collisions across retries/parallel jobs.
	git switch --orphan "gh-action-mutex/temp-branch-$(date +%s)-$$-$RANDOM" --quiet
	git branch -D "$__branch" --quiet 2>/dev/null || true

	while true; do
		# lock.sh/unlock.sh run under `set -e`. A bare `VAR=$(cmd)` assignment
		# statement DOES trigger errexit if cmd fails, killing the script before
		# __fetch_status is even set. Wrapping it as the condition of an `if` is
		# the standard way to capture a command's status without errexit firing.
		if __fetch_output=$(git fetch origin "$__branch" 2>&1); then
			__fetch_status=0
		else
			__fetch_status=$?
		fi

		if [ "$__fetch_status" -eq 0 ]; then
			git checkout "$__branch" --quiet
			return
		fi

		if echo "$__fetch_output" | grep -q "couldn't find remote ref"; then
			# Genuinely the first time this branch has ever been used.
			git switch --orphan "$__branch" --quiet
			return
		fi

		__attempt=$((__attempt + 1))
		if [ "$__attempt" -ge "$__max_attempts" ]; then
			echo "::error::update_branch: git fetch origin $__branch failed $__max_attempts times, refusing to fall back to an empty orphan branch. Last output:" >&2
			echo "$__fetch_output" >&2
			exit 1
		fi

		echo "update_branch: git fetch origin $__branch failed (attempt $__attempt/$__max_attempts), retrying: $__fetch_output" >&2
		sleep $((__attempt * 2))
	done
}

# Best-effort FF-only push (never force); returns the push exit status.
# args:
#   $1: branch
git_push() {
	set +e
	git push --set-upstream origin "$1" --quiet
	__rc=$?
	set -e
	return $__rc
}

# First non-blank line (blank = empty or whitespace-only) of a file.
first_nonblank_line() {
	awk 'NF {print; exit}' "$1"
}

# Field 1 (ticket) of a line, up to the first comma.
field1() {
	printf '%s' "${1%%,*}"
}

# Number of comma-separated fields in a line.
nfields() {
	printf '%s' "$1" | awk -F, '{print NF; exit}'
}

# Does the file contain any blank (empty/whitespace-only) lines?
has_blanks() {
	grep -qE '^[[:space:]]*$' "$1"
}

# Drop blank lines in place.
gc_blanks() {
	awk '/[^[:space:]]/' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# 1-based position of our ticket among non-blank lines (field-1 match); empty if absent.
queue_position() {
	awk -F, -v t="$1" '/[^[:space:]]/ { i++; if ($1 == t) { print i; exit } }' "$2"
}

# Remove every line whose field 1 == ticket, and drop blanks, in place.
# Field/whole-line filtering (never a sed regex) because a run URL contains slashes.
remove_by_field1() {
	awk -F, -v t="$1" '/[^[:space:]]/ && $1 != t' "$2" > "$2.tmp" && mv "$2.tmp" "$2"
}

# Add to the queue (iterative; FF-push retry on rejection). No-op if already queued.
# args:
#   $1: branch  $2: queue_file  $3: ticket_id
# uses global RUN_URL
enqueue() {
	__branch=$1
	__queue_file=$2
	__ticket_id=$3

	echo "[$__ticket_id] Enqueuing to branch $__branch, file $__queue_file"

	while : ; do
		update_branch "$__branch"
		touch "$__queue_file"

		if [ -n "$(queue_position "$__ticket_id" "$__queue_file")" ]; then
			echo "[$__ticket_id] Already in the queue"
			return 0
		fi

		echo "[$__ticket_id] Adding ourself to the queue file $__queue_file"
		gc_blanks "$__queue_file"
		echo "$__ticket_id,$RUN_URL,$(date +%s)" >> "$__queue_file"

		git add "$__queue_file"
		git commit -m "[$__ticket_id] Enqueue ($GITHUB_REPOSITORY run $GITHUB_RUN_ID attempt ${GITHUB_RUN_ATTEMPT:-1})" --quiet

		if git_push "$__branch"; then
			return 0
		fi
		sleep "${MUTEX_RETRY_SLEEP:-1}"
	done
}

# Append the advisory ACQ_EPOCH to our own line once we hold the lock.
# Advisory metadata only: acquisition never depends on it and a failed amend
# must not block or fail the lock step (best-effort, bounded retries).
# args:
#   $1: branch  $2: queue_file  $3: ticket_id
acquire_amend() {
	__branch=$1
	__queue_file=$2
	__ticket_id=$3

	__attempt=0
	while [ "$__attempt" -lt 5 ]; do
		__attempt=$((__attempt + 1))

		__line=$(first_nonblank_line "$__queue_file")
		if [ "$(field1 "$__line")" != "$__ticket_id" ]; then
			return 0
		fi
		# Only amend a pristine 3-field line; old-format (1) or already-amended (4) → skip.
		if [ "$(nfields "$__line")" -ne 3 ]; then
			return 0
		fi

		__new="$__line,$(date +%s)"
		awk -v L="$__line" -v NEW="$__new" '/[^[:space:]]/ { if ($0 == L) print NEW; else print }' \
			"$__queue_file" > "$__queue_file.tmp" && mv "$__queue_file.tmp" "$__queue_file"

		git add "$__queue_file"
		git commit -m "[$__ticket_id] Acquire" --quiet

		if git_push "$__branch"; then
			return 0
		fi
		sleep "${MUTEX_RETRY_SLEEP:-1}"
		update_branch "$__branch"
	done

	echo "[$__ticket_id] Could not persist acquire timestamp after retries; proceeding"
	return 0
}

# Wait for the lock to become available (iterative).
# args:
#   $1: branch  $2: queue_file  $3: ticket_id
# uses globals RUN_URL, MUTEX_POLL_SECONDS
wait_for_lock() {
	__branch=$1
	__queue_file=$2
	__ticket_id=$3

	while : ; do
		update_branch "$__branch"
		touch "$__queue_file"

		__first=$(first_nonblank_line "$__queue_file")
		__pos=$(queue_position "$__ticket_id" "$__queue_file")

		# Empty/all-blank queue OR our ticket missing (e.g. evicted or a UI blank-out):
		# re-enqueue and re-evaluate. Never proceed without seeing our own ticket.
		if [ -z "$__first" ] || [ -z "$__pos" ]; then
			echo "[$__ticket_id] Not present in queue (empty or lost); re-enqueuing"
			enqueue "$__branch" "$__queue_file" "$__ticket_id"
			continue
		fi

		__holder=$(field1 "$__first")
		if [ "$__holder" = "$__ticket_id" ]; then
			acquire_amend "$__branch" "$__queue_file" "$__ticket_id"
			return 0
		fi

		echo "[$__ticket_id] Waiting for lock - Current lock assigned to [$__holder]"
		sleep "${MUTEX_POLL_SECONDS:-5}"
	done
}

# Remove ourselves from the queue (iterative). Self-heals when our ticket is
# already absent (evicted or manually cleaned): exit 0, do not corrupt the queue.
# args:
#   $1: branch  $2: queue_file  $3: ticket_id
dequeue() {
	__branch=$1
	__queue_file=$2
	__ticket_id=$3

	while : ; do
		update_branch "$__branch"
		touch "$__queue_file"

		__first=$(first_nonblank_line "$__queue_file")
		__pos=$(queue_position "$__ticket_id" "$__queue_file")
		__changed=0

		if [ -n "$__first" ] && [ "$(field1 "$__first")" = "$__ticket_id" ]; then
			echo "[$__ticket_id] Unlocking"
			__message="[$__ticket_id] Unlock"
			remove_by_field1 "$__ticket_id" "$__queue_file"
			__changed=1
		elif [ -n "$__pos" ]; then
			echo "[$__ticket_id] Dequeueing. We don't have the lock!"
			__message="[$__ticket_id] Dequeue"
			remove_by_field1 "$__ticket_id" "$__queue_file"
			__changed=1
		else
			echo "[$__ticket_id] Ticket already absent (evicted or cleaned); self-healing"
			__message="[$__ticket_id] Garbage-collect blank lines"
			if has_blanks "$__queue_file"; then
				gc_blanks "$__queue_file"
				__changed=1
			fi
		fi

		if [ "$__changed" -eq 0 ]; then
			echo "[$__ticket_id] Queue unchanged; nothing to commit"
			return 0
		fi

		git add "$__queue_file"
		if git diff --cached --quiet; then
			echo "[$__ticket_id] No net change; nothing to commit"
			return 0
		fi
		git commit -m "$__message" --quiet

		if git_push "$__branch"; then
			return 0
		fi
		sleep "${MUTEX_RETRY_SLEEP:-1}"
	done
}
