# Shared set-id arithmetic. Sourced by every driver so they cannot disagree
# about what "older than N days" means.
#
# Age comes from the SET ID, never from a file timestamp. Object stores have
# no directory mtime, copying a set rewrites file times, and rsync -a
# preserves them while a plain cp does not -- three different answers to the
# same question. The id is the one piece of information that survives every
# destination unchanged.
#
# Set ids are the timestamp directory names backup-platform.sh creates:
# YYYYMMDDTHHMMSSZ, always UTC.

# set_id_epoch <set-id> -> seconds since epoch on stdout, or non-zero if the
# id is not a timestamp we recognise.
set_id_epoch() {
  case "$1" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) : ;;
    *) return 1 ;;
  esac
  # Reformat to something every date(1) accepts. GNU and BusyBox disagree on
  # almost everything else about parsing.
  local y="${1:0:4}" mo="${1:4:2}" d="${1:6:2}" h="${1:9:2}" mi="${1:11:2}" s="${1:13:2}"
  date -u -d "${y}-${mo}-${d} ${h}:${mi}:${s} UTC" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%d %H:%M:%S" "${y}-${mo}-${d} ${h}:${mi}:${s}" +%s 2>/dev/null
}

# set_is_older_than <set-id> <days> -> 0 when it should be pruned.
#
# An unparseable id is NEVER old enough. Deleting something we cannot date is
# how a backup system loses the one set someone renamed by hand.
set_is_older_than() {
  local epoch cutoff
  epoch="$(set_id_epoch "$1")" || return 1
  cutoff=$(( $(date -u +%s) - ($2 * 86400) ))
  [ "${epoch}" -lt "${cutoff}" ]
}
