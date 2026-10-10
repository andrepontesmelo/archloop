# lanes.sh — the single source of archloop model-lane routing (sourced).
# Roles resolve to LANE_* in run.sh; presets in bin/archloop; the ui
# summary default in scripts/ui/common.sh. Never duplicate these ids.
LANE_BIG="zai/glm-5.3"          # strong lane: scan/gate primaries
LANE_FLASH="zai/glm-5.3-flash"  # cheap lane: impl, and cheap-preset scan/impl
LANE_FALLBACK="opencode/space-bunny-free"  # provider-class retry; MUST stay
                                             # on a different provider than the
                                             # primaries above (free tier, not PAYG)
