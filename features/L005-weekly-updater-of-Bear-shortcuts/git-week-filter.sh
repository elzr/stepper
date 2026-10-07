#!/bin/sh
# Git clean filter for the files this feature's weekly roll rewrites (see .gitattributes
# at the repo root): blanks week numbers and date ranges, so git compares only the
# hand-edited parts and a Monday roll leaves `git status` clean.
#
# One-time setup per clone (git ignores the attribute until the filter is defined):
#   git config filter.l005-weeks.clean features/L005-weekly-updater-of-Bear-shortcuts/git-week-filter.sh
#
# Git stores the blanked text, so a checkout or stash writes "NN"/"DAYS" back into the
# working copy; update-bear-weeks.py refills them on the next reload, wake or Monday.
exec sed -E \
  -e 's/("(week|pastWeek|nextWeek)Num": *")[0-9]+"/\1NN"/g' \
  -e 's/("(week|pastWeek|nextWeek)Days": *")[^"]*"/\1DAYS"/g' \
  -e 's/w[0-9]{1,2}([a-z]+) [0-9]{1,2}([a-z]{3})?-[0-9]{1,2}[a-z]{3}[0-9]{4}/wNN\1 DAYS/g'
