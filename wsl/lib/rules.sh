#!/usr/bin/env bash
# rules.conf parsing and policy execution. Sourced, never executed directly.
set -uo pipefail

KNOWN_POLICIES='purge age keep-newest pw-orphan vacuum'

# _rule_arg_ok POLICY ARG -> 0 if ARG is a valid argument for POLICY
#
# The arg used to pass unchecked. `age` strips one lowercase `d` and hands the
# rest to awk, where a non-number compares as text: `age 30D` / `age 1w`
# deleted 5-day-old entries and `age -` deleted everything. `keep-newest -1`
# became `tail -n +0`, every entry a target.
#   age          whole days, optional `d`. 0 is allowed: it means "no activity
#                for more than one whole day" (see age_stale_entries), not
#                "everything". Leading zeros are harmless, awk reads 08 as 8.
#   keep-newest  integer >= 1, no leading zero: `$((08))` is a bash octal error.
#   vacuum       bytes with optional K/M/G/T, uppercase only: journalctl
#                documents those, and numfmt --from=iec (the freed-bytes
#                estimate) rejects lowercase. 0 would mean "no limit" to
#                journalctl but "free it all" to the estimate, so it is refused.
#   purge, pw-orphan  arg unused (`-` by convention); anything is accepted.
_rule_arg_ok() {
  local policy="$1" arg="$2"
  case "$policy" in
    age)         [[ "$arg" =~ ^[0-9]+d?$ ]] ;;
    keep-newest) [[ "$arg" =~ ^[1-9][0-9]*$ ]] ;;
    vacuum)      [[ "$arg" =~ ^[1-9][0-9]*[KMGT]?$ ]] ;;
    *)           return 0 ;;
  esac
}

# rules_parse FILE -> path|policy|arg|auto
#
# Non-zero on a missing file, a malformed line, or an unknown policy, and the
# callers must read it through a command substitution (`parsed=$(rules_parse
# ...)`) rather than `done < <(rules_parse ...)`: a process substitution's exit
# status is not the loop's, so under that form every error here exited 0 and a
# typo'd --rules path made `maint clean` a silent no-op that reported success.
#
# Parsed with a regex rather than awk field-splitting so a path may contain
# spaces: the greedy first group takes everything up to the LAST three
# whitespace-separated fields, which are policy/arg/auto. `NF >= 4` used to
# split such a path into fragments and bind the wrong columns, then drop the
# line without a word.
rules_parse() {
  local file="$1" line path policy arg auto real rc=0 n=0
  [ -f "$file" ] || { log_err "rules file not found: $file"; return 1; }
  # `|| [ -n "$line" ]` so a last line with no trailing newline is still read.
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    # A BOM is what Notepad and PS 5.1's UTF8 encoding put in front of line 1
    # (config.sh strips it the same way). Left in, it became part of a
    # first-line rule's path, which then matched no directory and silently
    # freed nothing, or a lone invisible "malformed rule" before a comment.
    [ "$n" -eq 1 ] && line="${line#$'\xef\xbb\xbf'}"
    line="${line%%#*}"
    [[ "$line" =~ [^[:space:]] ]] || continue
    if [[ ! "$line" =~ ^[[:space:]]*(.*[^[:space:]])[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
      log_err "malformed rule (want: path policy arg auto): $line"
      rc=1
      continue
    fi
    path="${BASH_REMATCH[1]}"
    policy="${BASH_REMATCH[2]}"
    arg="${BASH_REMATCH[3]}"
    auto="${BASH_REMATCH[4]}"
    case "$path" in
      "~/"*) path="$HOME/${path#\~/}" ;;
      "~")   path="$HOME" ;;
    esac
    # "|" is this function's own output delimiter, so a path carrying one would
    # be re-split into different fields by every caller's `IFS='|' read`.
    case "$path" in
      *"|"*) log_err "rule path may not contain '|': $path"; rc=1; continue ;;
    esac
    # Normalised the way safe_rm normalises every target (lexical_path). A
    # trailing "/" or "/." made find resolve a symlinked root while the
    # targets kept the link's spelling (~/.cache/lnk//id_rsa for a lnk that
    # points at ~/.ssh), which the lexical guard then judged as deletable.
    path=$(lexical_path "$path")
    if [ -L "$path" ]; then
      # A root that is itself a symlink is walked nowhere by `find` (-P, the
      # default): purge, age and keep-newest listed nothing, clean reported
      # success and recorded a run, audit showed the link's byte length.
      # Resolved once so the walk and the guard both see the real directory.
      # The spelled root is judged first: ~/.config pointing at another disk
      # must stay protected by its name, not become deletable through it.
      if is_protected "$path"; then
        log_err "rule path is protected: $path"; rc=1; continue
      fi
      if ! real=$(readlink -f -- "$path") || [ -z "$real" ]; then
        log_err "cannot resolve symlinked rule path: $path"; rc=1; continue
      fi
      log_info "rule path $path is a symlink; using $real"
      path="$real"
    fi
    case " $KNOWN_POLICIES " in
      *" $policy "*) ;;
      *) log_err "unknown policy: $policy"; rc=1; continue ;;
    esac
    if ! _rule_arg_ok "$policy" "$arg"; then
      log_err "bad argument '$arg' for $policy: $line"
      rc=1
      continue
    fi
    # Exact yes/no only. clean_run treats anything but "yes" as "no", so an
    # unchecked `Yes`, `true` or a swapped arg/auto pair (`purge yes -`) used
    # to parse cleanly and silently never run on plain `maint clean`.
    case "$auto" in
      yes|no) ;;
      *) log_err "auto must be yes or no, got '$auto': $line"; rc=1; continue ;;
    esac
    printf '%s|%s|%s|%s\n' "$path" "$policy" "$arg" "$auto"
  done < "$file"
  return "$rc"
}

# age_stale_entries ROOT DAYS -> top-level entries of ROOT with no activity in DAYS
#
# Activity of an entry is the newest of: atime and mtime of every non-directory
# in it (the entry itself if it is not a directory), and mtime of every
# directory in it, the entry included. Directory atime is never read: readdir
# refreshes it, so `du` in `maint audit` / `maint space` used to keep every
# entry alive, while a file opened by path refreshes nothing above it and an
# entry in daily use could go. Symlinks are not followed (find's default), so
# a link counts by its own times and the walk stays inside ROOT. One walk per
# root, aggregated per entry.
#
# Stale means more than DAYS whole days old, the same rounding as
# `find -atime +DAYS`. Fails closed: an entry holding a directory the walk
# cannot read or enter is kept with a warning, and if find fails for any other
# reason nothing in ROOT is a target and the function returns non-zero, so the
# rule counts as failed.
age_stale_entries() {
  local root="$1" days="$2" tmp rec name
  tmp=$(mktemp -d) || { log_warn "age: no temp dir for $root; nothing there is removed this run"; return 1; }
  # Unreadable directories are pruned and emitted as E records instead of being
  # left to find's stderr, so the failure is tied to its entry through %P.
  # Records are NUL-separated end to end, into awk and out of it, so a name with
  # a newline cannot split one into a forged record. awk tags each output
  # record: T a target, K an entry kept unscanned, M one holding a mount.
  # -xdev matches `du -x` in dir_bytes. -ignore_readdir_race: a file that
  # vanishes mid-walk (a busy npx cache) is skipped instead of failing the root.
  # %D is the device: -xdev still lists a mount point but not what is under it,
  # and `rm -rf` would descend into it, so an entry holding one is kept (M).
  local rootdev
  rootdev=$(stat -c %d -- "$root") || { log_warn "age: cannot stat $root; nothing there is removed this run"; rm -rf "$tmp"; return 1; }
  find "$root" -xdev -ignore_readdir_race -mindepth 1 \
      \( -type d \( ! -readable -o ! -executable \) -printf 'E %D 0 0 %P\0' -prune \) \
      -o \( -type d -printf 'D %D 0 %T@ %P\0' \) \
      -o -printf 'F %D %A@ %T@ %P\0' 2>"$tmp/err" \
    | awk -v RS='\0' -v ORS='\0' -v now="$(date +%s)" -v days="$days" -v rootdev="$rootdev" '
      {
        kind = $1; dev = $2; a = $3; m = $4
        rel = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ [^ ]+ /, "", rel)
        top = rel; sub(/\/.*/, "", top)
        seen[top] = 1
        if (dev != rootdev) { mnt[top] = 1; next }
        if (kind == "E") { bad[top] = 1; next }
        # A time more than a day ahead of now is unknown, not "in use": a file
        # dated 2030 must not pin its entry. The day of slack keeps a file
        # written during the walk (a hair past `now`) counting as fresh. An
        # entry left with no known time at all is kept.
        if (a > now + 86400) a = 0
        if (m > now + 86400) m = 0
        t = (a > m) ? a : m
        if (t == 0) next
        if (!(top in last) || t > last[top]) last[top] = t
      }
      END {
        for (top in seen) {
          if (top in mnt) print "M " top
          else if (top in bad) print "K " top
          else if ((top in last) && int((now - last[top]) / 86400) > days) print "T " top
        }
      }' > "$tmp/out"
  local st=("${PIPESTATUS[@]}")
  if [ "${st[0]}" -ne 0 ] || [ "${st[1]}" -ne 0 ]; then
    log_warn "age: scan of $root failed; nothing there is removed this run: $(tr '\n' ' ' < "$tmp/err")"
    rm -rf "$tmp"
    return 1
  fi
  # `IFS=` and a fixed two-char tag rather than `read kind name`, which would
  # trim the spaces a name may begin or end with. The callers read targets one
  # per line, so a name holding a newline cannot be handed on safely: keep it.
  while IFS= read -r -d '' rec; do
    name="${rec#? }"
    case "$name" in
      *$'\n'*)
        log_warn "age: name with a newline in $root kept: $(printf '%q' "$name")"
        continue ;;
    esac
    case "$rec" in
      "T "*) printf '%s/%s\n' "$root" "$name" ;;
      "K "*) log_warn "age: cannot read all of $root/$name; kept" ;;
      "M "*) log_warn "age: $root/$name holds a mount; kept" ;;
    esac
  done < "$tmp/out"
  rm -rf "$tmp"
}

# _emit_entries ROOT POLICY < NUL-separated names relative to ROOT
# -> ROOT/name, one per line.
#
# The callers read targets one per line, so a name holding a newline cannot be
# handed on safely: printed as is, $'a\nvictim' became ROOT/a and a bare
# `victim`, a cwd-relative path for safe_rm. Such a name is kept with a
# warning, like the age policy's own.
_emit_entries() {
  local root="$1" policy="$2" name
  while IFS= read -r -d '' name; do
    [ -n "$name" ] || continue
    case "$name" in
      *$'\n'*)
        log_warn "$policy: name with a newline in $root kept: $(printf '%q' "$name")"
        continue ;;
    esac
    printf '%s/%s\n' "$root" "$name"
  done
}

# rule_targets PATH POLICY ARG -> one absolute path per line
rule_targets() {
  local path="$1" policy="$2" arg="$3"
  [ -d "$path" ] || return 0
  case "$policy" in
    # find's stderr is kept for purge and keep-newest: pipefail already failed
    # the rule when the walk failed, but with the reason discarded "N rule(s)
    # failed" was all a busybox find (no -printf) or an unreadable root said.
    purge)
      find "$path" -mindepth 1 -maxdepth 1 -printf '%P\0' \
        | _emit_entries "$path" purge
      ;;
    age)
      age_stale_entries "$path" "${arg%d}"
      ;;
    keep-newest)
      local keep="$arg"
      # NUL-separated through the ranking too: a newline-named entry still
      # takes its place by mtime, and is only dropped once it is a target.
      find "$path" -mindepth 1 -maxdepth 1 -printf '%T@ %P\0' \
        | sort -z -rn | tail -z -n "+$((keep + 1))" | cut -z -d' ' -f2- \
        | _emit_entries "$path" keep-newest
      ;;
    pw-orphan)
      pw_orphan_dirs "$path"
      ;;
    vacuum)
      # journald manages its own files; nothing to enumerate.
      return 0
      ;;
    *)
      log_err "unknown policy: $policy"
      return 1
      ;;
  esac
}

# _journal_bytes -> journald's current disk usage in bytes. Prints 0 and
# returns 1 when the size cannot be read: an unknown size is not an empty
# journal, and a caller counting freed bytes must not read it as one.
# LC_ALL=C, and the pattern accepts a comma, because a comma-decimal locale
# renders the size as "514,2M": the old dot-only pattern matched "514" and
# "2M" as two tokens, `tail -1` took "2M", and a journal hundreds of MB over
# the limit reported almost nothing to free. numfmt is locale-sensitive the
# same way, so it is pinned too.
_journal_bytes() {
  local raw bytes
  raw=$(LC_ALL=C journalctl --disk-usage 2>/dev/null \
    | grep -oE '[0-9]+([.,][0-9]+)?[KMGT]?' | tail -1)
  [ -n "$raw" ] || { echo 0; return 1; }
  bytes=$(LC_ALL=C numfmt --from=iec "${raw/,/.}" 2>/dev/null)
  [ -n "$bytes" ] || { echo 0; return 1; }
  echo "$bytes"
}

# _rule_plan PATH POLICY ARG -- the one walk of a rule.
#
# Fills the CALLER's plan_targets and plan_sizes arrays (bash locals are
# dynamically scoped) and sets RULE_ESTIMATE to their sum. vacuum has no
# targets: plan_sizes[0] is the journal's size and the estimate is what lies
# over the limit. Non-zero, with RULE_ESTIMATE 0, if the targets could not be
# enumerated: an unknown policy or a failed walk must reach the caller as a
# failure rather than as "0 bytes to free".
_rule_plan() {
  local path="$1" policy="$2" arg="$3" targets t size cur limit
  RULE_ESTIMATE=0
  if [ "$policy" = "vacuum" ]; then
    # Unknown reads as 0 here: nothing over the limit, so nothing is vacuumed.
    cur=$(_journal_bytes) || true
    limit=$(LC_ALL=C numfmt --from=iec "$arg" 2>/dev/null)
    limit="${limit:-0}"
    plan_sizes=("$cur")
    [ "$cur" -le "$limit" ] || RULE_ESTIMATE=$((cur - limit))
    return 0
  fi
  # Command substitution, not `< <(rule_targets ...)`: the walk's status has
  # to reach this function.
  targets=$(rule_targets "$path" "$policy" "$arg") || return 1
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    size=$(dir_bytes "$t")
    plan_targets+=("$t")
    plan_sizes+=("$size")
    RULE_ESTIMATE=$((RULE_ESTIMATE + size))
  done <<< "$targets"
}

# rule_estimate PATH POLICY ARG -- sets RULE_ESTIMATE, the bytes the rule
# would free. Deletes nothing. Non-zero, RULE_ESTIMATE 0, if the targets could
# not be enumerated.
rule_estimate() {
  local -a plan_targets=() plan_sizes=()
  _rule_plan "$@"
}

# rule_run PATH POLICY ARG -- plan the rule once, then apply it.
#
# Sets RULE_ESTIMATE (before) and RULE_FREED (what actually left the disk).
# A rule with nothing to free prints nothing and deletes nothing. Otherwise it
# logs "PATH POLICY frees N" and prints each action indented. Under DRY_RUN the
# actions are only announced and RULE_FREED is 0.
#
# Freed is counted per target, size before minus whatever is still there
# after, never the estimate: a target safe_rm refuses, or one rm only half
# deletes, counts only what went. The journal counts its own shrinkage. A
# vacuum skipped for lack of a sudo grant warns and frees 0 without failing
# the rule, as the grant is optional.
#
# Non-zero if the targets could not be enumerated or any target was not fully
# deleted; RULE_FREED still counts what did go.
rule_run() {
  local path="$1" policy="$2" arg="$3" i t err after rc=0
  local -a plan_targets=() plan_sizes=()
  RULE_FREED=0
  _rule_plan "$path" "$policy" "$arg" || return 1
  [ "$RULE_ESTIMATE" -gt 0 ] || return 0
  log_info "$(printf '%-40s %-12s frees %s' "${path/#$HOME/\~}" "$policy" "$(human "$RULE_ESTIMATE")")"

  if [ "$policy" = "vacuum" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "  DRY journalctl --vacuum-size=$arg"
    # Probe with the real command, never with `sudo -n true`. A sudoers grant
    # written the way it should be -- NOPASSWD for this one journalctl
    # invocation and nothing else -- does not permit `true`, so probing `true`
    # answers "no passwordless sudo" on precisely the boxes that were
    # configured correctly, and the vacuum is skipped forever. The grant is
    # also pinned to the exact --vacuum-size argument, so a rules.conf change
    # from 100M to 50M silently stops matching it; that shows up here as a
    # refusal, which is why sudo's own message is kept rather than replaced
    # with a generic one.
    elif err=$(sudo -n journalctl --vacuum-size="$arg" 2>&1 >/dev/null); then
      echo "  VACUUM $arg"
      if ! after=$(_journal_bytes); then
        log_warn "journal size after the vacuum is unknown; counted as freeing nothing"
      elif [ "$after" -lt "${plan_sizes[0]}" ]; then
        RULE_FREED=$((plan_sizes[0] - after))
      fi
    else
      log_warn "journal vacuum skipped: ${err:-sudo -n journalctl --vacuum-size=$arg failed}"
    fi
    return 0
  fi

  for i in "${!plan_targets[@]}"; do
    t="${plan_targets[$i]}"
    # `|| rc=1` on every target, not just the last: a loop's own status is its
    # final command's, so a refusal mid-rule used to read as success. The pipe
    # only indents; pipefail carries safe_rm's status through it.
    safe_rm "$t" | sed 's/^/  /' || rc=1
    [ "$DRY_RUN" = "1" ] && continue
    after=$(dir_bytes "$t")
    [ "$after" -ge "${plan_sizes[$i]}" ] || RULE_FREED=$((RULE_FREED + plan_sizes[i] - after))
  done
  return "$rc"
}
