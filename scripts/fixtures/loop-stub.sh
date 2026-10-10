#!/usr/bin/env bash
# loop-stub.sh — stand-in for archloop-loop.sh in bin/archloop tests.
# Records how it was launched (env + args) into $STUB_LAUNCH_ENV. With
# STUB_LOOP_HOLD=1 it then sleeps, so the CLI's already-running refusal has a
# live process to detect. Keeps the CLI test hermetic: no real loop, no
# worktrees, no model calls.
{ echo "HOME=$HOME"
  env | grep -E '^(ARCHLOOP_MODEL_(SCAN|IMPL|GATE)|ARCHLOOP_IDLE_TIMEOUT|ARCHLOOP_MAX_ITEMS|ARCHLOOP_MAX_LOOPS)='
  echo "ARGS=$*"
} > "${STUB_LAUNCH_ENV:?STUB_LAUNCH_ENV not set}"
[ "${STUB_LOOP_HOLD:-0}" = "1" ] && sleep 15
