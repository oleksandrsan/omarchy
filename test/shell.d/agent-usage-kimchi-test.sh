#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command python3

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export HOME="$test_tmp/home"
export XDG_STATE_HOME="$test_tmp/state"
export XDG_CACHE_HOME="$test_tmp/cache"
unset KIMCHI_API_KEY KIMCHI_BASE_URL KIMCHI_REGION KIMCHI_CODING_AGENT_DIR

period_end=$(python3 -c 'import datetime as dt; print((dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=20)).isoformat())')
period_start=$(python3 -c 'import datetime as dt; print((dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=11)).isoformat())')
export PERIOD_END="$period_end" PERIOD_START="$period_start"

# A Kimchi login the way the CLI leaves it.
signed_in() {
  mkdir -p "$HOME/.config/kimchi"
  jq -n --arg key "$1" --arg region "${2:-us}" '{apiKey: $key, region: $region}' >"$HOME/.config/kimchi/config.json"
}

# The gateway answers per key: credits for every key, a budget only for some,
# and nothing at all for a revoked one. Each request is logged so the test can
# check which gateway was asked.
collect() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-kimchi" REQUESTS="$test_tmp/requests" python3 - "$@" <<'PY'
import importlib.machinery, importlib.util, io, json, os, sys, urllib.error

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

credits = {
  "key-coder": {"serverless": True, "tier": "coder", "is_paid_tier": True, "remaining": "24.95", "has_credits": True},
  "key-budget": {"serverless": True, "tier": "TEAMS", "remaining": 30, "has_credits": True},
  "key-empty": {"serverless": True, "tier": "free", "remaining": "0", "has_credits": False},
}
budgets = {
  "key-budget": {"period": {"startTime": os.environ["PERIOD_START"], "endTime": os.environ["PERIOD_END"]}, "budgets": [
    {"scope": "USER", "scopeId": "u-1", "budgetLimitUsd": "50", "totalSpendUsd": "20", "providerBudgets": [
      {"provider": "anthropic", "limitType": "PROVIDER_LIMIT_TYPE_CAPPED", "budgetLimitUsd": "10", "usageUsd": "2.5"},
      {"provider": "openai", "limitType": "UNLIMITED", "usageUsd": "4"},
    ]},
  ]},
}

def urlopen(request, timeout=None):
  with open(os.environ["REQUESTS"], "a") as log:
    log.write(request.full_url + "\n")
  key = request.get_header("Authorization").split(" ", 1)[1]
  if key == "key-offline" or os.environ.get("GATEWAY_DOWN"):
    raise urllib.error.URLError("offline")
  if key == "key-revoked":
    raise urllib.error.HTTPError(request.full_url, 401, "Unauthorized", {}, None)
  answers = credits if request.full_url.endswith("/v1/credits") else budgets
  return io.BytesIO(json.dumps(answers.get(key, {"period": {"startTime": "", "endTime": ""}, "budgets": []})).encode())

collector.urllib.request.urlopen = urlopen
sys.argv = ["omarchy-agent-usage-kimchi"] + (os.environ.get("COLLECT_ARGS") or "--force").split()
collector.main()
PY
}

record=$(collect)
[[ $(jq -c '{ready, tierLabel, limits, hasLocalStats, balance}' <<<"$record") == '{"ready":false,"tierLabel":"","limits":[],"hasLocalStats":false,"balance":null}' ]] ||
  fail "a machine nobody signed in to Kimchi on gives an empty record" "$record"
[[ ! -s $test_tmp/requests ]] || fail "no key means the gateway is never asked" "$(cat "$test_tmp/requests")"
pass "a machine nobody signed in to Kimchi on gives an empty record"

signed_in key-coder
record=$(collect)
[[ $(jq -c '{ready, tierLabel, limits, balance, usageStatusText, authHelpText}' <<<"$record") == '{"ready":true,"tierLabel":"Coder","limits":[],"balance":{"remaining":24.95,"funded":0,"spent":0,"currency":"USD","estimated":false},"usageStatusText":"","authHelpText":""}' ]] ||
  fail "a Coder plan reports its plan and prepaid credits" "$record"
[[ $(sort -u "$test_tmp/requests") == $'https://llm.kimchi.dev/v1/budget\nhttps://llm.kimchi.dev/v1/credits' ]] ||
  fail "the US region asks the US gateway" "$(cat "$test_tmp/requests")"
pass "a Coder plan reports its plan and prepaid credits"

: >"$test_tmp/requests"
signed_in key-coder eu
collect >/dev/null
[[ $(sort -u "$test_tmp/requests") == $'https://llm.eu.kimchi.dev/v1/budget\nhttps://llm.eu.kimchi.dev/v1/credits' ]] ||
  fail "the EU region asks the EU gateway" "$(cat "$test_tmp/requests")"
: >"$test_tmp/requests"
KIMCHI_BASE_URL="https://gateway.example/openai/v1/" collect >/dev/null
[[ $(sort -u "$test_tmp/requests") == $'https://gateway.example/v1/budget\nhttps://gateway.example/v1/credits' ]] ||
  fail "KIMCHI_BASE_URL names the gateway, without its OpenAI path" "$(cat "$test_tmp/requests")"
pass "the gateway follows Kimchi's region and KIMCHI_BASE_URL"

record=$(KIMCHI_API_KEY=key-budget collect)
[[ $(jq -c '{tierLabel, limit: (.limits[0] | {label, title, percent}), gauge: (.balance | .funded == 50 and .spent == 20)}' <<<"$record") == '{"tierLabel":"Teams","limit":{"label":"Budget","title":"Monthly","percent":0.4},"gauge":true}' ]] ||
  fail "a monthly spend budget becomes a Monthly limit and funds the balance gauge" "$record"
[[ $(jq -c '[.limits[1:][] | {title, percent}]' <<<"$record") == '[{"title":"Anthropic Monthly","percent":0.25}]' ]] ||
  fail "a capped provider is a scoped allowance on the budget's clock, an uncapped one isn't" "$record"
[[ $(jq -r '.limits[0].resetsAt' <<<"$record") == "$period_end" ]] || fail "the budget resets when its period ends" "$record"
pass "a monthly spend budget becomes a Monthly limit with its provider caps"

record=$(KIMCHI_API_KEY=key-empty collect)
[[ $(jq -c '{tierLabel, empty: (.balance.remaining == 0), usageStatusText}' <<<"$record") == '{"tierLabel":"Community","empty":true,"usageStatusText":"Out of credits, rate limited"}' ]] ||
  fail "an empty balance says Kimchi is rate limited" "$record"
pass "an empty balance says Kimchi is rate limited"

record=$(KIMCHI_API_KEY=key-revoked collect)
[[ $(jq -c '{ready, usageStatusText, retry: .retryAdvised}' <<<"$record") == '{"ready":true,"usageStatusText":"Waiting for auth","retry":null}' ]] ||
  fail "a rejected key asks for a sign-in" "$record"
record=$(KIMCHI_API_KEY=key-offline collect)
[[ $(jq -c '{usageStatusText, retry: .retryAdvised}' <<<"$record") == '{"usageStatusText":"Kimchi credits unavailable","retry":true}' ]] ||
  fail "an unreachable gateway asks for a sooner retry" "$record"
pass "a rejected key and an unreachable gateway are told apart"

# A gateway that stops answering leaves the last numbers up, dimmed and dated,
# rather than an empty section.
record=$(KIMCHI_API_KEY=key-budget collect)
fetched=$(jq -r '.limitsFetchedAt' <<<"$record")
(( fetched > 0 )) && [[ $(jq -r '.limitsStale' <<<"$record") == false ]] || fail "a live answer is dated and not stale" "$record"
record=$(KIMCHI_API_KEY=key-budget GATEWAY_DOWN=1 collect)
[[ $(jq -c '{tierLabel, stale: .limitsStale, at: .limitsFetchedAt, limits: (.limits | length), kept: (.balance.remaining == 30), usageStatusText, retry: .retryAdvised}' <<<"$record") == '{"tierLabel":"Teams","stale":true,"at":'"$fetched"',"limits":2,"kept":true,"usageStatusText":"","retry":true}' ]] ||
  fail "an outage keeps the last credits and budgets, marked stale" "$record"
record=$(KIMCHI_API_KEY=key-coder GATEWAY_DOWN=1 collect)
[[ $(jq -c '{tierLabel, limits}' <<<"$record") == '{"tierLabel":"Coder","limits":[]}' ]] ||
  fail "another key never shows the last key's numbers" "$record"
pass "an outage keeps the last credits and budgets, marked stale"

# Tokens come from assistant messages in the pi session files: cached input
# kept apart, a repeated entry counted once, user turns and other entries
# skipped.
sessions="$HOME/.config/kimchi/harness/sessions/--home-me--"
mkdir -p "$sessions"
now=$(python3 -c 'import datetime as dt; print(dt.datetime.now(dt.timezone.utc).isoformat())')
now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
reply() {
  jq -nc --arg id "$1" --arg at "$2" --arg model "$3" --argjson usage "$4" \
    '{type: "message", id: $id, timestamp: $at, message: {role: "assistant", model: $model, provider: "kimchi-dev", usage: $usage}}'
}
{
  jq -nc '{type: "session", id: "s-1"}'
  jq -nc --arg at "$now" '{type: "message", id: "u-1", timestamp: $at, message: {role: "user", content: "hi", usage: {input: 999}}}'
  reply a-1 "$now" minimax-m3 '{"input": 100, "output": 20, "cacheRead": 800, "cacheWrite": 5, "totalTokens": 925}'
  reply a-1 "$now" minimax-m3 '{"input": 100, "output": 20, "cacheRead": 800, "cacheWrite": 5, "totalTokens": 925}'
  reply a-2 "$now" glm-5.3 '{"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 75}'
  jq -nc --arg at "$now" '{type: "custom", id: "c-1", timestamp: $at, data: {usage: {input: 999}}}'
} >"$sessions/today.jsonl"
{
  reply b-1 "2026-01-02T10:00:00Z" minimax-m3 '{"input": 300, "output": 30, "cacheRead": 0, "cacheWrite": 0}'
} >"$sessions/old.jsonl"
jq -nc --argjson at "$now_ms" '{type: "message", id: "a-3", message: {role: "assistant", model: "glm-5.3", timestamp: $at, usage: {input: 10, output: 5}}}' >>"$sessions/today.jsonl"

record=$(KIMCHI_API_KEY=key-coder collect)
[[ $(jq -c '{hasLocalStats, todayPrompts, todaySessions, totalPrompts, totalSessions, activeDays, todayTotalTokens, todayTokensByModel, today: .recentDays[6].messageCount}' <<<"$record") == '{"hasLocalStats":true,"todayPrompts":3,"todaySessions":1,"totalPrompts":4,"totalSessions":2,"activeDays":2,"todayTotalTokens":1015,"todayTokensByModel":{"minimax-m3":925,"glm-5.3":90},"today":1015}' ]] ||
  fail "Kimchi counts sessions, prompts, and tokens from its session files" "$record"
[[ $(jq -cS '.modelUsage' <<<"$record") == '{"glm-5.3":{"cacheCreationInputTokens":0,"cacheReadInputTokens":0,"inputTokens":85,"outputTokens":5},"minimax-m3":{"cacheCreationInputTokens":5,"cacheReadInputTokens":800,"inputTokens":400,"outputTokens":50}}' ]] ||
  fail "Kimchi's tokens by model keep cached input apart" "$record"
pass "Kimchi counts sessions, prompts, and tokens from its session files"

# KIMCHI_CODING_AGENT_DIR moves the harness, as it does for the CLI.
mkdir -p "$test_tmp/harness/sessions/--elsewhere--"
reply x-1 "$now" kimi-k2.6 '{"input": 7, "output": 3}' >"$test_tmp/harness/sessions/--elsewhere--/s.jsonl"
record=$(KIMCHI_API_KEY=key-coder KIMCHI_CODING_AGENT_DIR="$test_tmp/harness" collect)
[[ $(jq -c '{totalSessions, todayTokensByModel}' <<<"$record") == '{"totalSessions":1,"todayTokensByModel":{"kimi-k2.6":10}}' ]] ||
  fail "KIMCHI_CODING_AGENT_DIR names the harness the sessions are read from" "$record"
pass "KIMCHI_CODING_AGENT_DIR names the harness the sessions are read from"

# A limits-only refresh reuses the last scan rather than reading every session.
KIMCHI_API_KEY=key-coder collect >/dev/null
reply b-2 "$now" minimax-m3 '{"input": 1, "output": 1}' >"$sessions/later.jsonl"
record=$(KIMCHI_API_KEY=key-coder COLLECT_ARGS="--limits-only" collect)
[[ $(jq -r '.totalSessions' <<<"$record") == 2 ]] || fail "a limits-only refresh reuses the session scan" "$record"
pass "a limits-only refresh reuses the session scan"

# A scan from another day is never reused, so yesterday's sessions don't
# count as today's after midnight.
jq '.day = "2000-01-01"' "$XDG_CACHE_HOME/omarchy/agent-usage/kimchi-stats.json" >"$test_tmp/stats.json"
mv "$test_tmp/stats.json" "$XDG_CACHE_HOME/omarchy/agent-usage/kimchi-stats.json"
record=$(KIMCHI_API_KEY=key-coder COLLECT_ARGS="--limits-only" collect)
[[ $(jq -r '.totalSessions' <<<"$record") == 3 ]] || fail "a scan from another day is made again" "$record"
pass "a scan from another day is made again"
