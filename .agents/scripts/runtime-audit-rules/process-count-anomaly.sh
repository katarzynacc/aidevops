#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# process-count-anomaly.sh — Detect pulse-wrapper process pile-up (t3072).
#
# Expected state after t2774 (lock released before LLM phase): 1-3 MAIN
# pulse-wrapper.sh processes may coexist legitimately. The lifecycle helper
# (_PULSE_EXPECTED_MAX_INSTANCES=3) is the authoritative threshold.
#
# On Linux, bash command-substitution subshells ($(...)) inherit the parent
# process argv, so a single pulse with several active subshells shows N+1
# lines matching "pulse-wrapper.sh" in raw `ps` output — even for a perfectly
# healthy system. pgrep -c alone is unreliable as a pile-up detector; it
# always overcounts by 4-8+ on Linux (GH#20611 explains why).
#
# PRIMARY PATH (production, LIFECYCLE_HELPER mode):
#   Delegates to pulse-lifecycle-helper.sh status which already implements
#   PPID-based filtering (Layers 1+2) and sidecar exclusion (Layer 3)
#   identical to pulse-lifecycle-helper.sh::_pulse_pids(). Exit code 3
#   from the helper means pile-up (count > _PULSE_EXPECTED_MAX_INSTANCES).
#   Triggered when PS_OUTPUT_OVERRIDE is unset and a lifecycle helper is
#   found at the standard path or LIFECYCLE_HELPER_OVERRIDE.
#
# FALLBACK PATH (test mode, PS_OUTPUT_OVERRIDE set):
#   Uses raw grep on the injected ps fixture. Tests must set LEAK_THRESHOLD
#   explicitly to a value calibrated for the fixture's PID count; the default
#   is intentionally high (15) to prevent false positives from subshells in
#   environments where the lifecycle helper is unavailable.
#
# Inputs (env):
#   PS_OUTPUT_OVERRIDE        Test fixture for ps output; enables fallback path.
#   LEAK_THRESHOLD            Max raw-grep count before firing (fallback only,
#                             default 15). Ignored when lifecycle helper is used.
#   PROC_PATTERN              Pattern to match (default 'pulse-wrapper.sh').
#   LIFECYCLE_HELPER_OVERRIDE Path override for pulse-lifecycle-helper.sh (tests).
#
# Function contract: runtime_audit_check returns 0/1; emits one JSON line
# on stdout when a finding is present.

# shellcheck shell=bash

runtime_audit_id() { printf 'process-count-anomaly\n'; return 0; }

# _pca_lifecycle_helper: resolve path to pulse-lifecycle-helper.sh.
# Returns: 0 + prints path on success; 1 if not found/executable.
_pca_lifecycle_helper() {
	# Allow test override.
	if [[ -n "${LIFECYCLE_HELPER_OVERRIDE:-}" ]]; then
		if [[ -x "${LIFECYCLE_HELPER_OVERRIDE}" ]]; then
			printf '%s\n' "${LIFECYCLE_HELPER_OVERRIDE}"
			return 0
		fi
		return 1
	fi
	local _agents_dir="${AIDEVOPS_AGENTS_DIR:-${HOME}/.aidevops/agents}"
	local _helper="${_agents_dir}/scripts/pulse-lifecycle-helper.sh"
	if [[ -x "$_helper" ]]; then
		printf '%s\n' "$_helper"
		return 0
	fi
	return 1
}

runtime_audit_check() {
	local threshold="${LEAK_THRESHOLD:-15}"
	local pattern="${PROC_PATTERN:-pulse-wrapper.sh}"

	# -----------------------------------------------------------------------
	# PRIMARY PATH: delegate to pulse-lifecycle-helper.sh when available and
	# not in test mode (PS_OUTPUT_OVERRIDE unset). The helper uses PPID-based
	# filtering identical to _pulse_pids() so subshells and sidecars are
	# excluded from the count. Exit code 3 = pile-up.
	# -----------------------------------------------------------------------
	if [[ -z "${PS_OUTPUT_OVERRIDE:-}" ]]; then
		local _helper=""
		if _helper=$(_pca_lifecycle_helper 2>/dev/null); then
			local _status_out="" _status_rc=0
			_status_out=$("$_helper" status 2>&1) || _status_rc=$?

			if [[ "$_status_rc" -ne 3 ]]; then
				# Not a pile-up — normal state (0) or status output issue (non-3 error).
				return 0
			fi

			# Pile-up detected. Extract the main instance count from status output.
			local _main_count=""
			_main_count=$(printf '%s' "$_status_out" | grep -oE 'running \([0-9]+ instance' | grep -oE '[0-9]+' | head -1)
			[[ "$_main_count" =~ ^[0-9]+$ ]] || _main_count="?"
			local _max_instances="${AIDEVOPS_PULSE_EXPECTED_MAX_INSTANCES:-3}"

			local title="runtime-audit: ${pattern} MAIN process pile-up (${_main_count} > ${_max_instances})"
			local body
			body=$(cat <<MARKDOWN
## Task

\`pulse-lifecycle-helper.sh status\` reports a pile-up: **${_main_count} MAIN** \`${pattern}\` instances alive, exceeding the expected maximum of ${_max_instances} (GH#21903, t2774).

Expected state (post-t2774): 1-3 MAIN instances may legitimately coexist.
- Cycle N's LLM phase + cycle N+1's deterministic phase = 2 (most common).
- Cycle N + N+1 + N+2 acquiring the lock = 3 (rare but normal).
- Any count beyond ${_max_instances} indicates launchd/systemd respawn outpacing cycle completion or hung LLM phases.

**Note:** raw \`pgrep -c pulse-wrapper.sh\` is NOT a reliable pile-up indicator.
On Linux, bash command-substitution subshells (\$(...)) inherit the parent's
argv, so a single healthy pulse cycle can show 5-10 matching lines in raw ps
output (GH#20611). \`pulse-lifecycle-helper.sh status\` uses PPID-based
filtering to count only canonical top-level instances.

## Evidence

\`pulse-lifecycle-helper.sh status\` output:
\`\`\`
${_status_out}
\`\`\`

## Why

This is a structural blind spot of the supervisor LLM — it never inspects
\`ps\`. A genuine pile-up (>3 MAIN instances) accumulates silently until
CPU/memory pressure becomes visible. Each lingering pulse holds open fds,
scratch dirs, and may block or duplicate dispatch.

## How

1. Run: \`pulse-lifecycle-helper.sh status\` to see current MAIN + sidecar counts.
2. Run: \`systemctl --user status aidevops-supervisor-pulse.service\` (Linux) or
   \`launchctl list com.aidevops.supervisor-pulse\` (macOS) for scheduler state.
3. Check \`~/.aidevops/logs/pulse-wrapper.log\` for hung-cycle evidence:
   look for cycles with no log progress for >30 min.
4. If stuck cycles are confirmed: \`pulse-lifecycle-helper.sh restart\` to
   stop all instances cleanly and let the scheduler respawn a fresh cycle.
5. If the scheduler itself is respawning too fast (e.g. systemd \`Restart=always\`
   with a too-short \`RestartSec\`), set \`PULSE_MIN_INTERVAL_S\` higher or
   increase the timer interval.

## Acceptance Criteria

1. Root cause identified (hung LLM phase, scheduler respawn loop, or lock bug).
2. Fix applied; \`pulse-lifecycle-helper.sh status\` exits 0 (not 3) in steady state.

## Verification

After fix and pulse restart:
\`\`\`
pulse-lifecycle-helper.sh status
\`\`\`
should report \`Pulse: running (1 instance)\` or \`Pulse: running (2 instances)\`
and exit 0 (not 3). The raw pgrep count may still be 5-10 due to subshells —
this is expected and correct.

<!-- aidevops:generator=runtime-audit detector=process-count-anomaly -->
MARKDOWN
)
			jq -n --arg id "process-count-anomaly" --arg title "$title" --arg body "$body" \
				'{id: $id, title: $title, body: $body}'
			return 1
		fi
		# Lifecycle helper not found — fall through to raw-grep fallback.
	fi

	# -----------------------------------------------------------------------
	# FALLBACK PATH: raw grep count (test mode via PS_OUTPUT_OVERRIDE, or
	# lifecycle helper unavailable). LEAK_THRESHOLD defaults to 15 here to
	# account for bash subshells inflating the raw count on Linux.
	# -----------------------------------------------------------------------
	local ps_out
	if [[ -n "${PS_OUTPUT_OVERRIDE:-}" ]]; then
		ps_out="$PS_OUTPUT_OVERRIDE"
	else
		ps_out=$(ps -ax -o pid=,command= 2>/dev/null) || ps_out=""
	fi

	if [[ -z "$ps_out" ]]; then
		return 0
	fi

	# Count lines that contain the pattern but exclude greps of itself
	local matches
	matches=$(printf '%s\n' "$ps_out" | grep -F "$pattern" | grep -vE 'grep|runtime-audit|runtime-health-audit')
	local count
	count=$(printf '%s\n' "$matches" | grep -cE '\S' 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0

	if [[ "$count" -le "$threshold" ]]; then
		return 0
	fi

	local title="runtime-audit: ${pattern} process count anomaly (${count} > ${threshold})"
	local body
	body=$(cat <<MARKDOWN
## Task

The raw process table shows ${count} processes matching \`${pattern}\`,
exceeding the fallback threshold of ${threshold}. This detector is running in
fallback mode (lifecycle helper unavailable or test mode).

**Important:** raw \`ps | grep pulse-wrapper.sh\` overcounts on Linux because
bash command-substitution subshells inherit the parent's argv (GH#20611). A
single healthy pulse cycle routinely shows 5-10 matching lines. The lifecycle
helper's PPID-based filtering is the authoritative source. If this firing is
in production (not a test), install \`pulse-lifecycle-helper.sh\` at the
standard path and re-run the audit.

## Evidence

\`\`\`
$(printf '%s\n' "$matches" | head -20)
\`\`\`

(Showing first 20 of ${count} matches.)

## Why

In fallback mode (no lifecycle helper), this detector uses raw grep which
overcounts subshells. A high raw count (>15) may still indicate a real
pile-up even accounting for subshells.

## How

1. Check if \`pulse-lifecycle-helper.sh\` is installed:
   \`ls ~/.aidevops/agents/scripts/pulse-lifecycle-helper.sh\`
2. If installed, run: \`pulse-lifecycle-helper.sh status\` for the authoritative
   MAIN process count (PPID-filtered, excludes subshells and sidecars).
3. If the authoritative count also shows pile-up (exit code 3 or >3 instances):
   \`pulse-lifecycle-helper.sh restart\` and identify the root cause.

## Acceptance Criteria

1. Root cause identified.
2. \`pulse-lifecycle-helper.sh status\` exits 0 in steady state.

## Verification

\`\`\`
pulse-lifecycle-helper.sh status
\`\`\`

<!-- aidevops:generator=runtime-audit detector=process-count-anomaly -->
MARKDOWN
)

	jq -n --arg id "process-count-anomaly" --arg title "$title" --arg body "$body" \
		'{id: $id, title: $title, body: $body}'
	return 1
}
