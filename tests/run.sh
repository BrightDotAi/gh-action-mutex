#!/bin/bash
# Self-contained, network-free, Docker-free test harness for the mutex scripts.
# Uses a bare git repo as origin (file://), a PATH curl stub for run-status, and
# MUTEX_POLL_SECONDS/MUTEX_RETRY_SLEEP/MUTEX_FETCH_RETRY_SLEEP overrides to keep the suite fast.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UTILS="$REPO_ROOT/rootfs/scripts/utils.sh"
STUBDIR="$REPO_ROOT/tests/stubs"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required for the eviction tests but was not found on PATH"; exit 1; }
chmod +x "$STUBDIR/curl" "$STUBDIR/flaky-git/git"
export MUTEX_TEST_REAL_GIT="$(command -v git)"
export PATH="$STUBDIR:$PATH"

# shellcheck source=/dev/null
source "$UTILS"

PASS=0
FAIL=0
CURRENT=""

start()  { CURRENT="$1"; }
ok()     { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()    { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "$2" ] && echo "         $2"; }

assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected [$1] got [$2]"; fi; }
assert_ne()       { if [ "$1" != "$2" ]; then ok "$3"; else bad "$3" "did not expect [$1]"; fi; }
assert_rc()       { if [ "$1" -eq "$2" ]; then ok "$3"; else bad "$3" "expected rc $1 got $2 (log: $(cat "$WORK/out.log" 2>/dev/null | tr '\n' '|'))"; fi; }
assert_log()      { if grep -qF "$1" "$WORK/out.log"; then ok "$2"; else bad "$2" "log missing [$1]"; fi; }
assert_log_grep() { if grep -qE "$1" "$WORK/out.log"; then ok "$2"; else bad "$2" "log missing /$1/"; fi; }

BRANCH=gh-mutex
QF=mutex_queue

setup_case() {
	WORK=$(mktemp -d)
	ORIGIN="$WORK/origin.git"
	CHECKOUT="$WORK/checkout"
	git init --bare -q "$ORIGIN"
	mkdir -p "$CHECKOUT"
	export GITHUB_RUN_ID="12345"
	export GITHUB_RUN_ATTEMPT="1"
	export GITHUB_REPOSITORY="org/repo"
	export GITHUB_SERVER_URL="https://github.com"
	export GITHUB_STATE="$WORK/state"; : > "$GITHUB_STATE"
	export ARG_REPO_TOKEN="x"
	export ARG_GITHUB_SERVER="github.com"
	export ARG_DEBUG="false"
	export ARG_BRANCH="$BRANCH"
	export ARG_MAX_WAIT_SECONDS=""
	export MUTEX_POLL_SECONDS=0
	export MUTEX_RETRY_SLEEP=0
	export MUTEX_FETCH_RETRY_SLEEP=0
	export MUTEX_TEST_CURL="fail"
	unset MUTEX_TEST_URL_LOG
	RUN_URL="https://github.com/org/repo/actions/runs/12345/attempts/1"
	TICKET="12345-100-1-default"
}

teardown_case() { rm -rf "$WORK"; }

# seed origin branch with queue content read from stdin
seed_origin() {
	local tmp; tmp=$(mktemp -d)
	git -C "$tmp" init -q
	git -C "$tmp" config user.email t@t
	git -C "$tmp" config user.name t
	git -C "$tmp" checkout -q --orphan "$BRANCH"
	cat > "$tmp/$QF"
	git -C "$tmp" add "$QF"
	git -C "$tmp" commit -q -m seed --allow-empty
	git -C "$tmp" remote add origin "file://$ORIGIN"
	git -C "$tmp" push -q origin "$BRANCH"
	rm -rf "$tmp"
}

origin_queue()   { git --git-dir="$ORIGIN" show "$BRANCH:$QF" 2>/dev/null; }
nonblank_count() { origin_queue | awk 'NF' | wc -l | tr -d ' '; }
first_line()     { origin_queue | awk 'NF{print;exit}'; }
field_count()    { awk -F, '{print NF}' <<<"$1"; }
has_field1()     { origin_queue | awk -F, -v t="$1" 'NF && $1==t {found=1} END{exit !found}'; }
commit_subjects(){ git --git-dir="$ORIGIN" log --format=%s "$BRANCH"; }

# run bash code in a set-e subshell inside the checkout; capture rc + combined log
run_in_case() {
	( cd "$CHECKOUT"; set -e; set_up_repo "file://$ORIGIN"; eval "$1" ) > "$WORK/out.log" 2>&1
	RC=$?
}

echo "== gh-action-mutex robustness suite =="

# ---------------------------------------------------------------------------
start "1: single job full cycle"
setup_case
seed_origin </dev/null
run_in_case 'enqueue "$ARG_BRANCH" "$QF" "$TICKET"; wait_for_lock "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 0 "$RC" "1: lock acquired (rc 0)"
assert_eq 1 "$(nonblank_count)" "1: exactly one line queued"
L=$(first_line)
assert_eq "$TICKET" "${L%%,*}" "1: field-1 is our ticket"
assert_eq 4 "$(field_count "$L")" "1: line has 4 fields (ACQ appended)"
assert_eq "$RUN_URL" "$(awk -F, '{print $2}' <<<"$L")" "1: field-2 is run URL"
run_in_case 'dequeue "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 0 "$RC" "1: unlock rc 0"
assert_eq 0 "$(nonblank_count)" "1: queue empty after unlock"
teardown_case

# ---------------------------------------------------------------------------
start "2: blank first line, our ticket on line 2"
setup_case
printf '\n%s\n' "$TICKET,$RUN_URL,123" | seed_origin
run_in_case 'wait_for_lock "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 0 "$RC" "2: acquired despite leading blank"
assert_eq 1 "$(nonblank_count)" "2: blank line garbage-collected"
assert_eq 4 "$(field_count "$(first_line)")" "2: our line amended with ACQ"
teardown_case

# ---------------------------------------------------------------------------
start "3: sole blank line (UI-delete artifact)"
setup_case
printf '\n' | seed_origin
run_in_case 'enqueue "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 0 "$RC" "3: enqueue rc 0"
assert_eq 1 "$(nonblank_count)" "3: no leading blank, one clean line"
assert_eq "$TICKET" "$(first_line | cut -d, -f1)" "3: line-1 field-1 is our ticket"
assert_eq 3 "$(field_count "$(first_line)")" "3: freshly enqueued line has 3 fields"
teardown_case

# ---------------------------------------------------------------------------
start "4: empty file while waiting, ticket lost -> re-enqueue (no false acquire)"
setup_case
seed_origin </dev/null
run_in_case 'wait_for_lock "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 0 "$RC" "4: rc 0"
assert_log "re-enqueuing" "4: re-enqueue path taken"
assert_eq 1 "$(nonblank_count)" "4: our line present after re-enqueue"
assert_eq 4 "$(field_count "$(first_line)")" "4: acquired legitimately (ACQ appended), not empty false-acquire"
teardown_case

# ---------------------------------------------------------------------------
start "5: old-format holder ahead -> wait, no eviction attempted"
setup_case
printf '%s\n' "oldticket123" | seed_origin
export MUTEX_TEST_CURL="completed"   # would evict if code wrongly tried
export MUTEX_POLL_SECONDS=1
export ARG_MAX_WAIT_SECONDS=1
run_in_case 'enqueue "$ARG_BRANCH" "$QF" "$TICKET"; wait_for_lock "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 1 "$RC" "5: timed out waiting (rc 1)"
if has_field1 "oldticket123"; then ok "5: old-format holder NOT evicted"; else bad "5: old-format holder NOT evicted" "it was removed"; fi
assert_log "has no run URL" "5: logged cannot-verify for old-format line"
if has_field1 "$TICKET"; then bad "5: our line self-dequeued on timeout" "still present"; else ok "5: our line self-dequeued on timeout"; fi
teardown_case

# ---------------------------------------------------------------------------
start "6: stale new-format holder (completed) -> evicted, we acquire"
setup_case
printf '%s\n' "deadticket,https://github.com/org/repo/actions/runs/111/attempts/1,100" | seed_origin
export MUTEX_TEST_CURL="completed"
run_in_case 'enqueue "$ARG_BRANCH" "$QF" "$TICKET"; wait_for_lock "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 0 "$RC" "6: acquired after eviction"
assert_eq 1 "$(nonblank_count)" "6: only our line remains"
assert_eq "$TICKET" "$(first_line | cut -d, -f1)" "6: we are the holder"
if commit_subjects | grep -qF "Evict stale holder [deadticket]"; then ok "6: eviction commit message present"; else bad "6: eviction commit message present"; fi
teardown_case

# ---------------------------------------------------------------------------
start "7: cascade - two dead new-format holders ahead"
setup_case
printf '%s\n%s\n' \
	"dead1,https://github.com/org/repo/actions/runs/101/attempts/1,10" \
	"dead2,https://github.com/org/repo/actions/runs/102/attempts/1,20" | seed_origin
export MUTEX_TEST_CURL="completed"
run_in_case 'enqueue "$ARG_BRANCH" "$QF" "$TICKET"; wait_for_lock "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 0 "$RC" "7: acquired after cascade"
assert_eq 1 "$(nonblank_count)" "7: both dead holders evicted"
assert_eq "$TICKET" "$(first_line | cut -d, -f1)" "7: we are the holder"
C=$(commit_subjects | grep -cF "Evict stale holder")
assert_eq 2 "$C" "7: two eviction commits"
teardown_case

# ---------------------------------------------------------------------------
start "8: live holder (in_progress) -> not evicted"
setup_case
printf '%s\n' "liveticket,https://github.com/org/repo/actions/runs/222/attempts/1,100" | seed_origin
export MUTEX_TEST_CURL="in_progress"
export MUTEX_POLL_SECONDS=1
export ARG_MAX_WAIT_SECONDS=1
run_in_case 'enqueue "$ARG_BRANCH" "$QF" "$TICKET"; wait_for_lock "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 1 "$RC" "8: timed out (rc 1)"
if has_field1 "liveticket"; then ok "8: live holder NOT evicted"; else bad "8: live holder NOT evicted"; fi
assert_log "status=in_progress" "8: logged in_progress, not evicting"
teardown_case

# ---------------------------------------------------------------------------
start "9: curl failure / non-200 -> not evicted"
setup_case
printf '%s\n' "unknownticket,https://github.com/org/repo/actions/runs/333/attempts/1,100" | seed_origin
export MUTEX_TEST_CURL="fail"
export MUTEX_POLL_SECONDS=1
export ARG_MAX_WAIT_SECONDS=1
run_in_case 'enqueue "$ARG_BRANCH" "$QF" "$TICKET"; wait_for_lock "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 1 "$RC" "9: timed out (rc 1)"
if has_field1 "unknownticket"; then ok "9: holder NOT evicted on API error"; else bad "9: holder NOT evicted on API error"; fi
assert_log "HTTP 000" "9: logged transport failure, not evicting"
if grep -qF "eviction inert" "$WORK/out.log"; then bad "9: transient failure does not claim eviction is inert"; else ok "9: transient failure does not claim eviction is inert"; fi
teardown_case

# ---------------------------------------------------------------------------
start "10: max-wait-seconds exceeded -> self-dequeue, ::error, exit 1"
setup_case
printf '%s\n' "persistent123" | seed_origin
export MUTEX_POLL_SECONDS=1
export ARG_MAX_WAIT_SECONDS=1
run_in_case 'enqueue "$ARG_BRANCH" "$QF" "$TICKET"; wait_for_lock "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 1 "$RC" "10: exit 1 on timeout"
assert_log "::error title=Mutex wait timeout" "10: error annotation emitted"
if has_field1 "$TICKET"; then bad "10: our ticket removed from queue"; else ok "10: our ticket removed from queue"; fi
if has_field1 "persistent123"; then ok "10: holder line still present in annotation queue"; else bad "10: holder still present"; fi
teardown_case

# ---------------------------------------------------------------------------
start "11: unlock when ticket already absent -> exit 0"
setup_case
printf '%s\n' "otherticket,https://github.com/org/repo/actions/runs/444/attempts/1,100" | seed_origin
run_in_case 'dequeue "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 0 "$RC" "11: self-heal exit 0"
assert_log "already absent" "11: logged already-absent"
if has_field1 "otherticket"; then ok "11: other holder untouched"; else bad "11: other holder untouched"; fi
teardown_case

# ---------------------------------------------------------------------------
start "12: suffix sanitization"
BAD_SUFFIX="a,b c	d"
CLEAN=$(printf '%s' "$BAD_SUFFIX" | tr -d ', \t\r\n')
assert_eq "abcd" "$CLEAN" "12: commas/whitespace stripped from suffix"
T="99-100-5-$CLEAN"
case "$T" in *,*) bad "12: ticket contains a comma";; *) ok "12: ticket contains no comma";; esac
case "$T" in *" "*) bad "12: ticket contains a space";; *) ok "12: ticket contains no space";; esac
teardown_case 2>/dev/null || true

# ---------------------------------------------------------------------------
start "13: CAS eviction race -> abort, no wrong line removed"
setup_case
# origin line-1 is 'otherline'; we observed a now-gone 'deadline' as holder.
printf '%s\n%s\n' \
	"otherline,https://github.com/org/repo/actions/runs/999/attempts/1,50" \
	"$TICKET,$RUN_URL,60" | seed_origin
export MUTEX_TEST_CURL="completed"
STALE="deadline,https://github.com/org/repo/actions/runs/111/attempts/1,10"
run_in_case 'update_branch "$ARG_BRANCH"; try_evict "$ARG_BRANCH" "$QF" "$TICKET" "'"$STALE"'"'
assert_rc 0 "$RC" "13: try_evict returns 0"
assert_log "Queue changed before eviction; aborting" "13: CAS abort logged"
assert_eq 2 "$(nonblank_count)" "13: nothing removed (both lines intact)"
if has_field1 "otherline"; then ok "13: actual holder untouched"; else bad "13: actual holder untouched"; fi
teardown_case

# ---------------------------------------------------------------------------
start "14: backslash in suffix is sanitized away (lock.sh sanitizer)"
setup_case
# Mirror lock.sh's suffix sanitizer on a backslash-bearing suffix.
BAD_SUFFIX='a\t,b\c'
CLEAN=$(printf '%s' "$BAD_SUFFIX" | tr -d ', \t\r\n\\')
assert_eq "atbc" "$CLEAN" "14: backslash + commas/ws stripped from suffix"
case "$CLEAN" in *\\*) bad "14: clean suffix still has a backslash";; *) ok "14: clean suffix has no backslash";; esac
BSTICKET="77-100-9-$CLEAN"
seed_origin </dev/null
run_in_case 'enqueue "$ARG_BRANCH" "$QF" "'"$BSTICKET"'"; dequeue "$ARG_BRANCH" "$QF" "'"$BSTICKET"'"'
assert_rc 0 "$RC" "14: enqueue+dequeue sanitized ticket rc 0"
assert_eq 0 "$(nonblank_count)" "14: queue empty after dequeue"
teardown_case

# ---------------------------------------------------------------------------
start "15: awk helpers match a line with a literal backslash (ENVIRON pin, not -v)"
setup_case
# A ticket carrying a literal backslash-t: -v would escape-process it and never
# match the on-disk line; ENVIRON passes it verbatim. Pins the F1 fix directly.
BSLINE='tick\tet,https://github.com/org/repo/actions/runs/1/attempts/1,10'
BSTICK='tick\tet'
F="$WORK/bsq"
printf '%s\n' "$BSLINE" > "$F"
assert_eq 1 "$(queue_position "$BSTICK" "$F")" "15: queue_position finds the backslash ticket"
cp "$F" "$F.a"; remove_exact "$BSLINE" "$F.a"
assert_eq 0 "$(awk 'NF' "$F.a" | wc -l | tr -d ' ')" "15: remove_exact drops the backslash line"
cp "$F" "$F.b"; remove_by_field1 "$BSTICK" "$F.b"
assert_eq 0 "$(awk 'NF' "$F.b" | wc -l | tr -d ' ')" "15: remove_by_field1 drops the backslash line"
teardown_case

# ---------------------------------------------------------------------------
start "16: github.com holder derives api.github.com attempts URL"
setup_case
seed_origin </dev/null
export MUTEX_TEST_CURL="in_progress"
export MUTEX_TEST_URL_LOG="$WORK/urls.log"; : > "$MUTEX_TEST_URL_LOG"
GH="ghholder,https://github.com/myorg/myrepo/actions/runs/555/attempts/3,10"
run_in_case 'try_evict "$ARG_BRANCH" "$QF" "$TICKET" "'"$GH"'"'
assert_rc 0 "$RC" "16: try_evict rc 0"
assert_eq "https://api.github.com/repos/myorg/myrepo/actions/runs/555/attempts/3" "$(cat "$MUTEX_TEST_URL_LOG")" "16: github.com -> api.github.com/repos/.../attempts/N"
teardown_case

# ---------------------------------------------------------------------------
start "17: GHES holder on the configured server -> https /api/v3 attempts URL"
setup_case
seed_origin </dev/null
export ARG_GITHUB_SERVER="ghe.example.com"
export MUTEX_TEST_CURL="in_progress"
export MUTEX_TEST_URL_LOG="$WORK/urls.log"; : > "$MUTEX_TEST_URL_LOG"
GHES="ghesholder,http://ghe.example.com/myorg/myrepo/actions/runs/777/attempts/2,10"
run_in_case 'try_evict "$ARG_BRANCH" "$QF" "$TICKET" "'"$GHES"'"'
assert_rc 0 "$RC" "17: try_evict rc 0"
assert_eq "https://ghe.example.com/api/v3/repos/myorg/myrepo/actions/runs/777/attempts/2" "$(cat "$MUTEX_TEST_URL_LOG")" "17: GHES -> https://<server>/api/v3/..., never the line's http scheme"
teardown_case

# ---------------------------------------------------------------------------
start "18: holder URL without /attempts/N -> no API call, no eviction"
setup_case
seed_origin </dev/null
export MUTEX_TEST_CURL="completed"   # would evict if it wrongly reached the API
export MUTEX_TEST_URL_LOG="$WORK/urls.log"; : > "$MUTEX_TEST_URL_LOG"
NOATT="noattholder,https://github.com/org/repo/actions/runs/888,10"
run_in_case 'try_evict "$ARG_BRANCH" "$QF" "$TICKET" "'"$NOATT"'"'
assert_rc 0 "$RC" "18: try_evict rc 0"
assert_log "not a recognized run-attempt URL" "18: rejected non-attempt URL"
assert_eq "" "$(cat "$MUTEX_TEST_URL_LOG")" "18: no API call attempted (URL log empty)"
teardown_case

# ---------------------------------------------------------------------------
start "19: odd/unparseable statuses -> not evicted"
setup_case
seed_origin </dev/null
HL="oddholder,https://github.com/org/repo/actions/runs/999/attempts/1,10"
for st in badjson empty queued; do
	export MUTEX_TEST_CURL="$st"
	run_in_case 'try_evict "$ARG_BRANCH" "$QF" "$TICKET" "'"$HL"'"'
	assert_rc 0 "$RC" "19: try_evict rc 0 ($st)"
	assert_log "not evicting" "19: not evicting on status=$st"
done
teardown_case

# ---------------------------------------------------------------------------
start "20: max-wait-seconds validation"
setup_case
run_in_case 'validate_max_wait "60s"'
assert_rc 1 "$RC" "20: rc 1 on non-integer max-wait"
assert_log "Invalid max-wait-seconds" "20: error annotation emitted"
run_in_case 'validate_max_wait "120"'
assert_rc 0 "$RC" "20: rc 0 on valid integer"
run_in_case 'validate_max_wait ""'
assert_rc 0 "$RC" "20: rc 0 on empty (unbounded)"
teardown_case

# ---------------------------------------------------------------------------
start "21: dequeue on persistent fetch failure -> exit 1, never silent success"
setup_case
printf '%s\n' "$TICKET,$RUN_URL,100" | seed_origin
run_in_case 'git remote set-url origin "file://$WORK/missing.git"; dequeue "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 1 "$RC" "21: dequeue fails loudly"
assert_log "refusing to fall back" "21: ::error explains the refusal"
if grep -qF "already absent" "$WORK/out.log"; then bad "21: not misreported as already-absent"; else ok "21: not misreported as already-absent"; fi
if has_field1 "$TICKET"; then ok "21: real ticket left on origin for eviction"; else bad "21: real ticket left on origin for eviction"; fi
teardown_case

# ---------------------------------------------------------------------------
start "22: transient fetch failure -> retried, then dequeues cleanly"
setup_case
printf '%s\n' "$TICKET,$RUN_URL,100" | seed_origin
export MUTEX_TEST_FETCH_FAILS_FILE="$WORK/fetch_fails"; echo 2 > "$MUTEX_TEST_FETCH_FAILS_FILE"
run_in_case 'export PATH="$STUBDIR/flaky-git:$PATH"; dequeue "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 0 "$RC" "22: dequeue succeeds after retries"
assert_log "attempt 2/5" "22: retried through both transient failures"
if grep -qF "attempt 3/5" "$WORK/out.log"; then bad "22: stopped retrying once fetch recovered"; else ok "22: stopped retrying once fetch recovered"; fi
if has_field1 "$TICKET"; then bad "22: ticket removed from origin"; else ok "22: ticket removed from origin"; fi
unset MUTEX_TEST_FETCH_FAILS_FILE
teardown_case

# ---------------------------------------------------------------------------
start "23: lock branch not yet on origin -> orphan path, no retries"
setup_case
run_in_case 'enqueue "$ARG_BRANCH" "$QF" "$TICKET"; wait_for_lock "$ARG_BRANCH" "$QF" "$TICKET"'
assert_rc 0 "$RC" "23: first-ever lock acquired"
if grep -qF "retrying" "$WORK/out.log"; then bad "23: missing branch not treated as fetch failure"; else ok "23: missing branch not treated as fetch failure"; fi
if has_field1 "$TICKET"; then ok "23: branch created with our ticket"; else bad "23: branch created with our ticket"; fi
teardown_case

# ---------------------------------------------------------------------------
start "24: holder URL names another server -> token never sent, not evicted"
setup_case
EVIL="evilholder,https://attacker.example/o/r/actions/runs/1/attempts/1,10"
printf '%s\n' "$EVIL" | seed_origin
export MUTEX_TEST_CURL="completed"   # would evict if the request were made
export MUTEX_TEST_URL_LOG="$WORK/urls.log"; : > "$MUTEX_TEST_URL_LOG"
run_in_case 'try_evict "$ARG_BRANCH" "$QF" "$TICKET" "'"$EVIL"'"'
assert_rc 0 "$RC" "24: try_evict rc 0"
assert_eq "" "$(cat "$MUTEX_TEST_URL_LOG")" "24: no request made to the named host"
assert_log "unexpected server" "24: ::warning names the refusal"
if has_field1 "evilholder"; then ok "24: holder not evicted"; else bad "24: holder not evicted"; fi
teardown_case

# ---------------------------------------------------------------------------
start "25: HTTP 403 -> not evicted, inert warning emitted once per job"
setup_case
H="deadholder,https://github.com/org/repo/actions/runs/555/attempts/1,10"
printf '%s\n' "$H" | seed_origin
export MUTEX_TEST_CURL="http403"
run_in_case 'try_evict "$ARG_BRANCH" "$QF" "$TICKET" "'"$H"'"; try_evict "$ARG_BRANCH" "$QF" "$TICKET" "'"$H"'"'
assert_rc 0 "$RC" "25: try_evict rc 0"
assert_eq 1 "$(grep -c 'eviction inert' "$WORK/out.log")" "25: inert warning emitted exactly once across two checks"
assert_eq 2 "$(grep -c 'run status (HTTP 403); not evicting' "$WORK/out.log")" "25: each check still logs its own outcome"
assert_log "actions:read" "25: warning names the missing permission"
if has_field1 "deadholder"; then ok "25: holder not evicted"; else bad "25: holder not evicted"; fi
teardown_case

# ---------------------------------------------------------------------------
start "26: 401/404 warn as inert; 429/500 are transient; none evict"
for M in http401 http404 http429 http500; do
	setup_case
	H="holder,https://github.com/org/repo/actions/runs/556/attempts/1,10"
	printf '%s\n' "$H" | seed_origin
	export MUTEX_TEST_CURL="$M"
	run_in_case 'try_evict "$ARG_BRANCH" "$QF" "$TICKET" "'"$H"'"'
	if has_field1 "holder"; then ok "26[$M]: not evicted"; else bad "26[$M]: not evicted"; fi
	case "$M" in
		http401|http404) assert_log "eviction inert" "26[$M]: inert warning" ;;
		*) if grep -qF "eviction inert" "$WORK/out.log"; then bad "26[$M]: transient, no inert warning"; else ok "26[$M]: transient, no inert warning"; fi ;;
	esac
	teardown_case
done

# ---------------------------------------------------------------------------
start "27: www.github.com holder is the configured github.com, not refused"
setup_case
seed_origin </dev/null
export MUTEX_TEST_CURL="in_progress"
export MUTEX_TEST_URL_LOG="$WORK/urls.log"; : > "$MUTEX_TEST_URL_LOG"
W="wwwholder,https://www.github.com/org/repo/actions/runs/888/attempts/1,10"
run_in_case 'try_evict "$ARG_BRANCH" "$QF" "$TICKET" "'"$W"'"'
assert_eq "https://api.github.com/repos/org/repo/actions/runs/888/attempts/1" "$(cat "$MUTEX_TEST_URL_LOG")" "27: www.github.com -> api.github.com"
teardown_case

# ---------------------------------------------------------------------------
echo
echo "== results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
