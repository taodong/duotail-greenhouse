#!/usr/bin/env bash
# Shared helper for normalizing permissions of files the manager scripts write
# into the agent's tasks/, instructions/, and skills/ directories.
#
# These directories are root-owned (mode 2550); the manager scripts run as
# root and create or replace files under them. Whenever such a file is written
# by root, set its group to agentgroup and restrict it to 640 (rw for the owner,
# r for the group, nothing for others) so agentuser keeps read access via the
# group bit while the file is not exposed world-wide.
#
# The group fix matters because a file created by root (e.g. via mktemp + mv)
# only inherits agentgroup when the parent dir has the setgid bit; the explicit
# chgrp here guarantees the right group regardless of how the file was written.
#
# This file only defines a function; it is meant to be sourced.

# enforce_managed_file_perms <path>
#
# Apply mode 640 to a single file, but only when it lives under a tasks/,
# instructions/, or skills/ directory. Safe to call on any path: files outside
# those directories, empty arguments, and missing files are ignored. chmod
# failures are tolerated so callers never abort on a best-effort permission fix.
enforce_managed_file_perms() {
    local path="$1"
    [ -n "$path" ] || return 0

    case "$path" in
        */tasks/*|*/instructions/*|*/skills/*) ;;
        *) return 0 ;;
    esac

    [ -f "$path" ] || return 0
    chgrp agentgroup "$path" 2>/dev/null || true
    chmod 640 "$path" 2>/dev/null || true
}

# enforce_managed_dir_perms <path>
#
# Apply group ownership agentgroup and mode 2550 (r-x for owner and group,
# setgid so children inherit agentgroup, nothing for others) to a directory
# under a tasks/, instructions/, or skills/ path — matching the root-owned
# managed parent dirs so agentuser can traverse and read via the group bit.
#
# Only applied when running as root (the container case). Unlike the file
# helper, a 2550 directory removes the owner write bit, so applying it as a
# non-root dev user would lock that user out of a later overwrite; the root
# guard avoids that while keeping the file helper's best-effort tolerance.
enforce_managed_dir_perms() {
    local path="$1"
    [ -n "$path" ] || return 0

    case "$path" in
        */tasks/*|*/instructions/*|*/skills/*) ;;
        *) return 0 ;;
    esac

    [ -d "$path" ] || return 0
    [ "$(id -u)" = 0 ] || return 0
    chgrp agentgroup "$path" 2>/dev/null || true
    chmod 2550 "$path" 2>/dev/null || true
}
