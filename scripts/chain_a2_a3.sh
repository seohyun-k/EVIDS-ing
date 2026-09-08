#!/usr/bin/env bash
# Chains A2 main collection -> (on clean completion) -> A3 main collection.
# Lives outside both a2-work/a3-work git worktrees since it bridges two
# separate branches (A2_Attack, A3_Attack) rather than belonging to either.
#
# Completion detection (explicit, not just "the process returned"): BOTH (a)
# the A2 orchestrator's own exit code == 0, AND (b) its console log contains
# the literal "ALL $ROUNDS ROUNDS COMPLETE" marker line that
# collect_a2_rounds.sh prints as its last action - same convention as A1's
# orchestrator log. Belt-and-suspenders: exit code alone could in principle
# be 0 from a degenerate/empty run, and the marker alone doesn't rule out a
# crash after it printed - checking both is what "완전히 종료" means here.
# A3 only starts if both hold; otherwise the chain stops and reports why.
#
# Usage: chain_a2_a3.sh [ROUNDS=5] [DUR=3600] [A2_DATA=/workspace/data/a2_main] [A3_DATA=/workspace/data/a3_main]
set -u
ROUNDS=${1:-5}
DUR=${2:-3600}
A2_DATA=${3:-/workspace/data/a2_main}
A3_DATA=${4:-/workspace/data/a3_main}
mkdir -p "$A2_DATA" "$A3_DATA"
A2_CONSOLE=$A2_DATA/orchestrator_console.log
A3_CONSOLE=$A3_DATA/orchestrator_console.log
CHAIN_LOG=/workspace/data/chain_a2_a3.log

log(){ echo "[chain $(date -u +%FT%TZ)] $*" | tee -a "$CHAIN_LOG" >&2; }

log "A2 START: $ROUNDS rounds x ${DUR}s -> $A2_DATA (console: $A2_CONSOLE)"
bash /workspace/a2-work/Attack/A2/collect_a2_rounds.sh "$ROUNDS" "$DUR" "$A2_DATA" > "$A2_CONSOLE" 2>&1
rc2=$?
log "A2 DONE exit=$rc2"

if grep -q "ALL $ROUNDS ROUNDS COMPLETE" "$A2_CONSOLE"; then marker2=발견; else marker2=미발견; fi
if [ "$rc2" -ne 0 ] || [ "$marker2" = 미발견 ]; then
  log "A2가 정상 완료되지 않음 (exit=$rc2, marker=$marker2) -> A3 시작하지 않음"
  exit 1
fi

log "A2 정상 완료 확인 (exit=0 + marker) -> A3 START: $ROUNDS rounds x ${DUR}s -> $A3_DATA (console: $A3_CONSOLE)"
bash /workspace/a3-work/Attack/A3/a3_collect_rounds.sh "$ROUNDS" "$DUR" "$A3_DATA" > "$A3_CONSOLE" 2>&1
rc3=$?
log "A3 DONE exit=$rc3"

if [ "$rc3" -eq 0 ] && grep -q "ALL $ROUNDS ROUNDS COMPLETE" "$A3_CONSOLE"; then
  log "ALL DONE (A2+A3 chain complete, rc2=$rc2 rc3=$rc3)"
else
  log "A3가 정상 완료되지 않음 (exit=$rc3) -> 확인 필요"
  exit 1
fi
