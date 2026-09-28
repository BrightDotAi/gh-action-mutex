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
		sleep $((__attempt * ${MUTEX_FETCH_RETRY_SLEEP:-2}))
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
# ENVIRON (not -v): awk -v escape-processes backslashes, so a ticket with a literal
# backslash would never match the on-disk line. ENVIRON passes the value verbatim.
queue_position() {
	T="$1" awk -F, '/[^[:space:]]/ { i++; if ($1 == ENVIRON["T"]) { print i; exit } }' "$2"
}

# Remove every line whose field 1 == ticket, and drop blanks, in place.
# Field/whole-line filtering (never a sed regex) because a run URL contains slashes.
remove_by_field1() {
	T="$1" awk -F, '/[^[:space:]]/ && $1 != ENVIRON["T"]' "$2" > "$2.tmp" && mv "$2.tmp" "$2"
}

# Remove exactly one whole line (fixed-string) and drop blanks, in place.
remove_exact() {
	L="$1" awk '/[^[:space:]]/ && $0 != ENVIRON["L"]' "$2" > "$2.tmp" && mv "$2.tmp" "$2"
}

# Add to the queue (iterative; FF-push retry on rejection). No-op if already queued.
# args:
#   $1: branch  $2: queue_file  $3: ticket_id
# No /attempts/N unless the attempt is known: guessing 1 can name a completed attempt and evict a live re-run.
build_run_url() {
	__base="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
	case "${GITHUB_RUN_ATTEMPT:-}" in
		''|*[!0-9]*) printf '%s\n' "$__base" ;;
		*)           printf '%s/attempts/%s\n' "$__base" "$GITHUB_RUN_ATTEMPT" ;;
	esac
}

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
		# Empty-commit guard: a no-op staging must not abort the script under set -e.
		if git diff --cached --quiet; then
			echo "[$__ticket_id] Nothing to commit; already enqueued"
			return 0
		fi
		git commit -m "[$__ticket_id] Enqueue ($GITHUB_REPOSITORY run $GITHUB_RUN_ID attempt ${GITHUB_RUN_ATTEMPT:-unknown})" --quiet

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

	# Advisory only: isolate the entire body in a subshell and swallow ANY failure
	# (awk/mv/commit under set -e included) so a bad amend can never fail the lock step.
	if ! (
		set -e
		__attempt=0
		while [ "$__attempt" -lt 5 ]; do
			__attempt=$((__attempt + 1))

			__line=$(first_nonblank_line "$__queue_file")
			if [ "$(field1 "$__line")" != "$__ticket_id" ]; then
				exit 0
			fi
			# Only amend a pristine 3-field line; old-format (1) or already-amended (4) → skip.
			if [ "$(nfields "$__line")" -ne 3 ]; then
				exit 0
			fi

			__new="$__line,$(date +%s)"
			# ENVIRON (not -v): -v escape-processes backslashes; a line with a literal
			# backslash would never match and the amend would silently no-op.
			L="$__line" NEW="$__new" awk '/[^[:space:]]/ { if ($0 == ENVIRON["L"]) print ENVIRON["NEW"]; else print }' \
				"$__queue_file" > "$__queue_file.tmp" && mv "$__queue_file.tmp" "$__queue_file"

			git add "$__queue_file"
			git commit -m "[$__ticket_id] Acquire" --quiet

			if git_push "$__branch"; then
				exit 0
			fi
			sleep "${MUTEX_RETRY_SLEEP:-1}"
			update_branch "$__branch"
		done

		echo "[$__ticket_id] Could not persist acquire timestamp after retries; proceeding"
		exit 0
	); then
		echo "[$__ticket_id] Acquire-amend failed (advisory); proceeding without timestamp"
	fi
	return 0
}

# Attempt to evict the current (line-1) holder, but only on positive evidence
# (the holder's run attempt is completed). Never evicts on doubt.
# args:
#   $1: branch  $2: queue_file  $3: ticket_id  $4: observed holder line
try_evict() {
	__branch=$1
	__queue_file=$2
	__ticket_id=$3
	__holder_line=$4
	__holder=$(field1 "$__holder_line")

	# field 2 = run URL; old-format lines have none → cannot verify, never evict.
	__url=$(printf '%s' "$__holder_line" | awk -F, '{print $2}')
	if [ -z "$__url" ] || [ "$__url" = "$__holder_line" ]; then
		echo "[$__ticket_id] Holder [$__holder] has no run URL (old-format); cannot verify, not evicting"
		return 0
	fi

	# Attempt-specific endpoint: a re-run makes the plain runs endpoint report the
	# latest attempt, masking an orphaned earlier attempt as still alive.
	if [[ "$__url" =~ ^(https?)://([^/]+)/(.+)/actions/runs/([0-9]+)/attempts/([0-9]+)$ ]]; then
		__server=${BASH_REMATCH[2]}
		__orgrepo=${BASH_REMATCH[3]}
		__runid=${BASH_REMATCH[4]}
		__att=${BASH_REMATCH[5]}
	else
		echo "[$__ticket_id] Holder [$__holder] URL not a recognized run-attempt URL; not evicting"
		return 0
	fi

	# The queue file is writable by anyone with push; never send the token to a host it names.
	__expected=${ARG_GITHUB_SERVER:-github.com}
	case "$__server" in www.github.com) __server=github.com ;; esac
	case "$__expected" in www.github.com) __expected=github.com ;; esac
	if [ "$__server" != "$__expected" ]; then
		echo "::warning title=Mutex holder on unexpected server::[$__ticket_id] Holder [$__holder] URL names $__server, not $__expected; not evicting"
		return 0
	fi

	if [ "$__server" = "github.com" ]; then
		__api="https://api.github.com/repos/$__orgrepo/actions/runs/$__runid/attempts/$__att"
	else
		__api="https://$__server/api/v3/repos/$__orgrepo/actions/runs/$__runid/attempts/$__att"
	fi

	__out=$(curl -s --max-time 10 -w '\n%{http_code}' \
		-H "Authorization: Bearer $ARG_REPO_TOKEN" \
		-H "Accept: application/vnd.github+json" \
		"$__api" 2>/dev/null) || __out=$'\n000'
	__code=${__out##*$'\n'}
	__resp=${__out%$'\n'*}
	case "$__code" in
		200) ;;
		401|403|404)
			# Silent here = the original wedge: holders stay stuck and nothing says why.
			if [ -z "${__MUTEX_INERT_WARNED:-}" ]; then
				echo "::warning title=Mutex stale-lock eviction inert::HTTP $__code reading holder run status; repo-token needs actions:read on $__orgrepo. Stale holders will not be auto-evicted."
				__MUTEX_INERT_WARNED=1
			fi
			echo "[$__ticket_id] Could not query holder [$__holder] run status (HTTP $__code); not evicting"
			return 0 ;;
		*)
			echo "[$__ticket_id] Could not query holder [$__holder] run status (HTTP $__code); not evicting"
			return 0 ;;
	esac
	if [ -z "$__resp" ]; then
		echo "[$__ticket_id] Holder [$__holder] run status response empty; not evicting"
		return 0
	fi

	# `|| true`: a jq parse failure must yield empty status (→ not evicting), not
	# abort the script under set -e.
	__status=$(printf '%s' "$__resp" | jq -r '.status // empty' 2>/dev/null || true)
	if [ -z "$__status" ]; then
		echo "[$__ticket_id] Holder [$__holder] status unparseable; not evicting"
		return 0
	fi
	if [ "$__status" != "completed" ]; then
		echo "[$__ticket_id] Holder [$__holder] run status=$__status; not evicting"
		return 0
	fi

	# CAS: re-fetch and confirm the same line is still the holder before removing it.
	update_branch "$__branch"
	if [ "$(first_nonblank_line "$__queue_file")" != "$__holder_line" ]; then
		echo "[$__ticket_id] Queue changed before eviction; aborting"
		return 0
	fi

	echo "[$__ticket_id] Evicting stale holder [$__holder] (run attempt completed)"
	remove_exact "$__holder_line" "$__queue_file"
	git add "$__queue_file"
	# Empty-commit guard: a no-op removal must not abort the script under set -e.
	if git diff --cached --quiet; then
		echo "[$__ticket_id] Eviction produced no change; nothing to commit"
		return 0
	fi
	git commit -m "[$__ticket_id] Evict stale holder [$__holder] (run attempt completed)" --quiet
	if ! git_push "$__branch"; then
		# Do not blind-retry: let the wait loop re-fetch and re-evaluate from scratch.
		echo "[$__ticket_id] Eviction push rejected; will re-evaluate"
	fi
	return 0
}

# Validate the max-wait-seconds input: empty = unbounded; else must be a non-negative int.
# Fail fast (rc 1 + ::error) rather than silently treating garbage as unbounded.
validate_max_wait() {
	if [ -n "${1:-}" ] && ! printf '%s' "$1" | grep -qE '^[0-9]+$'; then
		echo "::error title=Invalid max-wait-seconds::max-wait-seconds must be a non-negative integer (got '$1')"
		return 1
	fi
	return 0
}

# Wait for the lock to become available (iterative, to carry eviction-check state).
# args:
#   $1: branch  $2: queue_file  $3: ticket_id
# uses globals RUN_URL, ARG_MAX_WAIT_SECONDS, MUTEX_POLL_SECONDS
wait_for_lock() {
	__branch=$1
	__queue_file=$2
	__ticket_id=$3

	__start=$(date +%s)
	__last_holder=""
	__last_check=0
	__first_iter=1

	while : ; do
		update_branch "$__branch"
		touch "$__queue_file"

		__first=$(first_nonblank_line "$__queue_file")
		__pos=$(queue_position "$__ticket_id" "$__queue_file")
		__holder=$(field1 "$__first")

		# Already the holder: acquire immediately, regardless of the wait budget.
		if [ -n "$__first" ] && [ "$__holder" = "$__ticket_id" ]; then
			acquire_amend "$__branch" "$__queue_file" "$__ticket_id"
			return 0
		fi

		__now=$(date +%s)

		# max-wait-seconds: self-dequeue, emit an error annotation, and fail.
		# Evaluated BEFORE the re-enqueue path so a timeout still fires even while
		# we are repeatedly re-enqueuing a lost/evicted ticket.
		if [ -n "${ARG_MAX_WAIT_SECONDS:-}" ] && [ "${ARG_MAX_WAIT_SECONDS}" -gt 0 ]; then
			__waited=$((__now - __start))
			if [ "$__waited" -gt "$ARG_MAX_WAIT_SECONDS" ]; then
				__holder_line=$__first
				__queue_dump=$(awk '/[^[:space:]]/ {printf "%s%%0A", $0}' "$__queue_file")
				echo "[$__ticket_id] Max wait exceeded (${__waited}s > ${ARG_MAX_WAIT_SECONDS}s); self-dequeuing"
				dequeue "$__branch" "$__queue_file" "$__ticket_id"
				echo "::error title=Mutex wait timeout::Waited ${__waited}s (limit ${ARG_MAX_WAIT_SECONDS}s) for the mutex.%0ACurrent holder: ${__holder_line}%0AQueue:%0A${__queue_dump}Check whether the holder run is still running."
				exit 1
			fi
		fi

		# Empty/all-blank queue OR our ticket missing (e.g. evicted or a UI blank-out):
		# re-enqueue and re-evaluate. Never proceed without seeing our own ticket.
		if [ -z "$__first" ] || [ -z "$__pos" ]; then
			echo "[$__ticket_id] Not present in queue (empty or lost); re-enqueuing"
			enqueue "$__branch" "$__queue_file" "$__ticket_id"
			__last_holder=""
			__last_check=0
			__first_iter=1
			continue
		fi

		# Eviction-check triggers: (t1) first wait iteration, (t2) holder changed,
		# (t3) same holder every 60*(position-1)s.
		__do_check=0
		if [ "$__first_iter" -eq 1 ]; then
			__do_check=1
		elif [ "$__holder" != "$__last_holder" ]; then
			__do_check=1
		else
			__interval=$((60 * (__pos - 1)))
			if [ "$__interval" -gt 0 ] && [ $((__now - __last_check)) -ge "$__interval" ]; then
				__do_check=1
			fi
		fi
		__first_iter=0
		if [ "$__holder" != "$__last_holder" ]; then
			__last_holder=$__holder
		fi

		if [ "$__do_check" -eq 1 ]; then
			__last_check=$__now
			try_evict "$__branch" "$__queue_file" "$__ticket_id" "$__first"
			continue
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
