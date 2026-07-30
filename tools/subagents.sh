#!/bin/sh
# oh-my-axon subagent report (Linux / WSL / macOS).
#
#   tools/subagents.sh               summarise every recorded subagent run
#   tools/subagents.sh --role NAME   one role only
#   tools/subagents.sh --log PATH    read a specific telemetry log
#   tools/subagents.sh --config PATH resolve model windows from a specific config
#   tools/subagents.sh --quiet       print only problems
#   tools/subagents.sh --help        list every flag
#
# gen-roles assigns roles to models by reading parameter counts out of their
# names, and says so: SUGGESTIONS, not measurements. This reports what actually
# happened, from the SubagentStop hook's log, so the guess can be checked.
#
# TOK/S is generated tokens over time spent in the API, both read from the
# child's own billing ledger (Axon 0.3.6+). It is never derived from
# `tokensUsed`, which is the subagent's final CONTEXT size rather than anything
# it produced -- dividing that by elapsed time yields a throughput-shaped number
# that measures nothing, and it is why this column did not exist before.
#
# Runs that generated less than MIN_OUTPUT_TOKENS are left out of the rate. At
# that size the API time is nearly all prefill, so the figure describes how long
# the prompt took to read, not how fast the model writes. Excluded runs are
# always counted out loud rather than dropped quietly.
#
# Exit codes: 0 nothing to flag, 1 at least one problem, 2 usage error.
set -eu

# Below this many generated tokens a rate is prefill, not throughput.
MIN_OUTPUT_TOKENS=100

OMA_VERSION="0.1.6"
AXON_HOME="${AXON_HOME:-$HOME/.axon}"
LOG="$AXON_HOME/telemetry/subagents.jsonl"
CONFIG="$AXON_HOME/config.toml"
ROLE=""
QUIET=0

TOOLS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=tools/lib/probe.sh
. "$TOOLS_DIR/lib/probe.sh"

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --quiet|-q) QUIET=1 ;;
        --role)
            [ $# -ge 2 ] || { echo "subagents: --role needs a name" >&2; exit 2; }
            ROLE="$2"
            shift
            ;;
        --role=*) ROLE="${1#--role=}" ;;
        --log)
            [ $# -ge 2 ] || { echo "subagents: --log needs a path" >&2; exit 2; }
            LOG="$2"
            shift
            ;;
        --log=*) LOG="${1#--log=}" ;;
        --config)
            [ $# -ge 2 ] || { echo "subagents: --config needs a path" >&2; exit 2; }
            CONFIG="$2"
            shift
            ;;
        --config=*) CONFIG="${1#--config=}" ;;
        --version) echo "oh-my-axon $OMA_VERSION"; exit 0 ;;
        -h|--help) usage ;;
        *)
            echo "subagents: unknown argument: $1" >&2
            echo "  Run tools/subagents.sh --help to see the flags this accepts." >&2
            exit 2
            ;;
    esac
    shift
done

if [ ! -f "$LOG" ]; then
    echo "subagents: no telemetry log at $LOG" >&2
    echo "  The SubagentStop hook writes it. Install it with:" >&2
    echo "    ./install.sh --with-telemetry" >&2
    echo "  Then run something that spawns a subagent." >&2
    exit 2
fi

# Overflow files exist only where a Windows hook lost a race for the main log.
# Reading them back is what keeps that fallback from being a silent data loss.
#
# Collected into the positional parameters rather than a space-separated string:
# AXON_HOME can sit under a path with a space in it, and one string split on
# whitespace would hand awk two half-filenames that do not exist.
set -- "$LOG"
for extra in "$(dirname -- "$LOG")"/subagents-overflow-*.jsonl; do
    # Skip the one already being read: --log can name an overflow file itself,
    # and counting it twice would inflate every number in the report.
    [ -f "$extra" ] && [ "$extra" != "$LOG" ] && set -- "$@" "$extra"
done

# The model windows, as a lookup awk can read before the records. A model with
# no context_window set gets Axon's own assumption of 200000, the same number
# doctor reports against.
CATALOG=$(mktemp)
trap 'rm -f "$CATALOG"' EXIT
if [ -f "$CONFIG" ]; then
    probe_parse_catalog "$CONFIG" | while IFS='	' read -r k _ _ _ _ _ _ c; do
        printf '%s\t%s\n' "$k" "$c"
    done > "$CATALOG"
fi

# shellcheck disable=SC2016
REPORT=$(awk -v want="$ROLE" -v quiet="$QUIET" -v logpath="$LOG" -v catfile="$CATALOG" \
             -v minout="$MIN_OUTPUT_TOKENS" '
    # One value out of one flat record, by key rather than by position, so a
    # record written by an older version still reads correctly.
    function jval(line, key,   pat, s, q) {
        pat = "\"" key "\"[[:space:]]*:[[:space:]]*"
        if (!match(line, pat)) return ""
        s = substr(line, RSTART + RLENGTH)
        if (substr(s, 1, 1) == "\"") {
            s = substr(s, 2)
            q = index(s, "\"")
            return (q > 0) ? substr(s, 1, q - 1) : s
        }
        match(s, /^[^,}]*/)
        s = substr(s, RSTART, RLENGTH)
        gsub(/[[:space:]]/, "", s)
        return (s == "null") ? "" : s
    }
    # No asort in POSIX awk, and a few hundred records do not need better than
    # an insertion sort.
    function median(vals, n,   i, j, t, a) {
        if (n == 0) return -1
        for (i = 1; i <= n; i++) a[i] = vals[i]
        for (i = 2; i <= n; i++) {
            t = a[i]; j = i - 1
            while (j > 0 && a[j] > t) { a[j + 1] = a[j]; j-- }
            a[j + 1] = t
        }
        if (n % 2) return a[(n + 1) / 2]
        return (a[n / 2] + a[n / 2 + 1]) / 2
    }
    function dur(ms) {
        if (ms < 0) return "-"
        if (ms < 10000) return sprintf("%.1fs", ms / 1000)
        if (ms < 600000) return sprintf("%ds", int(ms / 1000 + 0.5))
        return sprintf("%dm%02ds", int(ms / 60000), int((ms % 60000) / 1000 + 0.5))
    }
    function toks(t) {
        if (t < 0) return "-"
        if (t < 1000) return sprintf("%d", t)
        return sprintf("%.1fk", t / 1000)
    }

    # Keyed on the filename, not on NR == FNR: with no config to read the
    # catalog file is empty, FNR never advances past it, and the NR == FNR form
    # swallows the whole log as catalog lines -- reporting an empty log to
    # anyone whose --config path was wrong.
    FILENAME == catfile { win[$1] = $2 + 0; incat[$1] = 1; next }

    {
        role = jval($0, "subagentType")
        if (role == "") next
        if (want != "" && role != want) next
        if (!(role in runs)) {
            order[++nroles] = role
            # Created up front, not sprung into existence by a later `++`.
            # Leaving these to be auto-created made gawk 5.2.1 corrupt its heap
            # and die with "internal error: segfault" -- while mawk, which is
            # what CI runs, was perfectly happy. Do not "simplify" this away:
            # the failure it prevents is invisible on Ubuntu and fatal on any
            # gawk system (Fedora, RHEL, Homebrew).
            thin[role] = 0; noledger[role] = 0; shortbilled[role] = 0
            cfgattr[role] = 0; incomp[role] = 0; nr[role] = 0
        }
        runs[role]++
        total++

        m = jval($0, "model")
        if (m == "") { nomodel++ } else {
            if (index(SUBSEP seen[role] SUBSEP, SUBSEP m SUBSEP) == 0) {
                seen[role] = (seen[role] == "" ? m : seen[role] SUBSEP m)
            }
        }

        ec = jval($0, "exitCode")
        if (ec == "0") ok[role]++
        else if (ec == "1") { bad[role]++; e = jval($0, "error"); if (e != "") lasterr[role] = e }
        else if (ec == "-1") canc[role]++
        else other[role]++

        d = jval($0, "durationMs")
        if (d != "") { durs[role, ++nd[role]] = d + 0 }
        tk = jval($0, "tokensUsed")
        if (tk != "") {
            tks[role, ++nt[role]] = tk + 0
            if (tk + 0 > peak[role]) peak[role] = tk + 0
            if (!(role in floor_) || tk + 0 < floor_[role]) floor_[role] = tk + 0
            if (gfloor == 0 || tk + 0 < gfloor) gfloor = tk + 0
        }
        tc = jval($0, "toolCalls")
        if (tc != "") { tcs[role, ++nc[role]] = tc + 0 }
        tn = jval($0, "turns")
        if (tn != "") { tns[role, ++nn[role]] = tn + 0 }

        # Generated tokens over API time, from the child ledger. Kept as a rate
        # per run and then taken at the median, rather than one ratio of two
        # grand totals: a single long run would otherwise decide the figure for
        # a role that is mostly short ones.
        ot = jval($0, "outputTokens")
        ad = jval($0, "apiDurationMs")
        mcount = jval($0, "modelCount")
        short_bill = (jval($0, "usageIncomplete") == "true")
        if (short_bill) { incomp[role]++ }
        if (mcount == "" || mcount + 0 == 0) {
            noledger[role]++
        } else if (short_bill) {
            # Excluded on purpose. An under-counted numerator over a full
            # denominator understates the rate, and a quietly low number is
            # worse than none.
            shortbilled[role]++
        } else if (ot + 0 >= minout && ad + 0 > 0) {
            rates[role, ++nr[role]] = (ot + 0) * 1000.0 / (ad + 0)
        } else {
            thin[role]++
        }
        if (jval($0, "modelSource") == "config") { cfgattr[role]++ }
    }

    END {
        if (total == 0) {
            if (want != "") {
                printf "PROBLEM\tno records for role \"%s\". Roles are recorded exactly as the task tool named them.\n", want
            } else {
                printf "PROBLEM\t%s holds no readable records.\n", logpath
            }
            exit
        }

        if (!quiet) {
            printf "HEAD\toh-my-axon subagents -- %d run(s) across %d role(s) from %s\n", total, nroles, logpath
            if (gfloor > 0) {
                printf "HEAD2\tSmallest run recorded: %s of context. That is close to the fixed cost of a spawn, before a subagent does any work.\n", toks(gfloor)
            }
            printf "ROW\t%-10s %-10s %5s %14s %9s %12s %8s %10s %10s\n", \
                "ROLE", "MODEL", "RUNS", "OK/FAIL/CANC", "MED DUR", "TURNS/CALLS", \
                "TOK/S", "PEAK CTX", "OF WINDOW"
        }

        for (i = 1; i <= nroles; i++) {
            r = order[i]
            nmodels = split(seen[r], ms, SUBSEP)
            label = (nmodels == 0) ? "?" : ((nmodels == 1) ? ms[1] : ms[nmodels] "+" (nmodels - 1))

            # Three cases, kept apart on purpose. A window read from the config
            # supports a finding; the 200000 Axon assumes supports a note; a
            # model that is not in the catalog at all supports neither, and
            # printing a percentage against a number nobody set would dress a
            # guess up as a measurement.
            w = 0; known = 0; assumed = 0
            if (nmodels >= 1) {
                if ((ms[nmodels] in win) && win[ms[nmodels]] > 0) {
                    w = win[ms[nmodels]]; known = 1
                } else if (ms[nmodels] in incat) {
                    w = 200000; assumed = 1
                }
            }

            pct = (peak[r] > 0 && w > 0) ? sprintf("%d%%", int(peak[r] * 100 / w + 0.5)) : "-"

            if (!quiet) {
                for (j = 1; j <= nd[r]; j++) dtmp[j] = durs[r, j]
                for (j = 1; j <= nn[r]; j++) ntmp[j] = tns[r, j]
                for (j = 1; j <= nc[r]; j++) ctmp[j] = tcs[r, j]
                mt = median(ntmp, nn[r]); mc = median(ctmp, nc[r])
                for (j = 1; j <= nr[r]; j++) rtmp[j] = rates[r, j]
                mrate = median(rtmp, nr[r])
                rate_s = (mrate < 0) ? "-" : \
                    ((mrate >= 10) ? sprintf("%d", int(mrate + 0.5)) : sprintf("%.1f", mrate))
                printf "ROW\t%-10s %-10s %5d %14s %9s %12s %8s %10s %10s\n", \
                    substr(r, 1, 10), substr(label, 1, 10), runs[r], \
                    sprintf("%d/%d/%d", ok[r] + 0, bad[r] + 0, canc[r] + 0), \
                    dur(median(dtmp, nd[r])), \
                    sprintf("%s/%s", (mt < 0 ? "-" : sprintf("%g", mt)), (mc < 0 ? "-" : sprintf("%g", mc))), \
                    rate_s, toks(peak[r] > 0 ? peak[r] : -1), pct
            }

            # Axon compacts at 85% of the window, so a role that got that high
            # was summarising its own context instead of doing the work. Stated
            # as a finding only when the window came from the config.
            if (peak[r] > 0 && w > 0 && peak[r] * 100 / w >= 85) {
                if (known) {
                    printf "PROBLEM\t%s peaked at %s of %s'\''s %s window (%d%%). Axon compacts at 85%%, so this role was compacting mid-run: give it a model with more room, or split the task.\n", \
                        r, toks(peak[r]), label, toks(w), int(peak[r] * 100 / w + 0.5)
                } else {
                    printf "NOTE\t%s peaked at %s, which would be %d%% of the 200000 Axon assumes for %s. Set context_window on that model to find out whether it really compacted.\n", \
                        r, toks(peak[r]), int(peak[r] * 100 / w + 0.5), label
                }
            }
            if (bad[r] > 0) {
                if (lasterr[r] != "") {
                    printf "PROBLEM\t%s failed %d of %d run(s). Most recent error: %s\n", r, bad[r], runs[r], lasterr[r]
                } else {
                    printf "PROBLEM\t%s failed %d of %d run(s), with no error text recorded.\n", r, bad[r], runs[r]
                }
            }
            if (other[r] > 0) {
                printf "PROBLEM\t%s has %d run(s) with no exit status. Axon reports one only for completed, failed and cancelled.\n", r, other[r]
            }
            if (nmodels > 1) {
                printf "NOTE\t%s ran on %d different models over this log (%s). Its medians mix them.\n", r, nmodels, seen[r]
            }
            if (nmodels >= 1 && !(ms[nmodels] in incat)) {
                printf "NOTE\t%s ran on \"%s\", which is not in your catalog now, so there is no window to measure its context against. Those numbers describe a model you have since renamed or removed.\n", r, ms[nmodels]
            }
            # Every run left out of TOK/S is named. A rate over an unstated
            # subset is the same failure as a rate over the wrong number.
            excluded = thin[r] + noledger[r] + shortbilled[r]
            if (excluded > 0) {
                why = ""
                if (thin[r] > 0) {
                    why = why sprintf("; %d had too little generation to time, where API time is nearly all prefill (the bar is %d tokens)", thin[r], minout)
                }
                if (noledger[r] > 0) {
                    why = why sprintf("; %d with no ledger (Axon before 0.3.6)", noledger[r])
                }
                if (shortbilled[r] > 0) {
                    why = why sprintf("; %d reported a short bill, which would understate the rate", shortbilled[r])
                }
                if (nr[r] == 0) {
                    printf "NOTE\t%s has no TOK/S -- every run was excluded%s.\n", r, why
                } else {
                    printf "NOTE\t%s computed TOK/S from %d of %d run(s)%s.\n", r, nr[r], runs[r], why
                }
            }
            # An authoritative name comes from the child itself. A name resolved
            # from config is only as current as the config.
            if (cfgattr[r] > 0) {
                printf "NOTE\t%s had the model resolved from config on %d of %d run(s), not reported by Axon. Those names are right only if the config has not changed since.\n", \
                    r, cfgattr[r], runs[r]
            }
            if (incomp[r] > 0) {
                printf "NOTE\t%s reported an incomplete bill on %d run(s), so its token totals are a floor rather than a count.\n", r, incomp[r]
            }
            if (nmodels > 1 && nr[r] > 0) {
                printf "NOTE\t%s mixes %d models, so its TOK/S is a median across different machines rather than the speed of any one of them.\n", r, nmodels
            }
            # Once per model, not once per role that happens to use it.
            if (assumed && peak[r] > 0 && peak[r] * 100 / w < 85 && !(ms[nmodels] in notedwin)) {
                notedwin[ms[nmodels]] = 1
                printf "NOTE\t%s sets no context_window, so \"of window\" for it is against the 200000 Axon assumes. tools/doctor.sh reports what the server actually serves.\n", label
            }
        }

        if (nomodel > 0) {
            printf "NOTE\t%d record(s) carry no model. They predate the shared parser being installed, or were written with no config.toml present.\n", nomodel
        }
    }
' "$CATALOG" "$@")

# Split awk's tagged lines back into sections so the table stays together and
# problems keep doctor.sh'"'"'s trailing placement.
printf '%s\n' "$REPORT" | sed -n 's/^HEAD\t//p; s/^HEAD2\t//p'
[ "$QUIET" = "1" ] || echo
printf '%s\n' "$REPORT" | sed -n 's/^ROW\t/  /p'

NOTES=$(printf '%s\n' "$REPORT" | sed -n 's/^NOTE\t//p')
PROBLEMS=$(printf '%s\n' "$REPORT" | sed -n 's/^PROBLEM\t//p')

if [ -n "$NOTES" ] && [ "$QUIET" != "1" ]; then
    echo
    echo "Notes:"
    printf '%s\n' "$NOTES"
fi

if [ -z "$PROBLEMS" ]; then
    if [ "$QUIET" != "1" ]; then
        echo
        echo "No problems found."
    fi
    exit 0
fi

[ "$QUIET" = "1" ] || echo
echo "Problems:"
printf '%s\n' "$PROBLEMS"
exit 1
