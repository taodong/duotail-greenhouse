#!/usr/bin/env bash
# Shared helper for normalizing permissions of files the manager scripts write
# into the agent's tasks/ and instructions/ directories.
#
# These two directories are root-owned (mode 550); the manager scripts run as
# root and create or replace files under them. Whenever such a file is written
# by root, restrict it to 640 (rw for the owner, r for the group, nothing for
# others) so the folder owner keeps read access while the file is not exposed
# world-wide.
#
# This file only defines a function; it is meant to be sourced.

# enforce_managed_file_perms <path>
#
# Apply mode 640 to a single file, but only when it lives under a tasks/ or
# instructions/ directory. Safe to call on any path: files outside those two
# directories, empty arguments, and missing files are ignored. chmod failures
# are tolerated so callers never abort on a best-effort permission fix.
enforce_managed_file_perms() {
    local path="$1"
    [ -n "$path" ] || return 0

    case "$path" in
        */tasks/*|*/instructions/*) ;;
        *) return 0 ;;
    esac

    [ -f "$path" ] || return 0
    chmod 640 "$path" 2>/dev/null || true
}
