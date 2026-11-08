# Turns an ADR's front matter into a line under its title, for the docs site:
# mdBook does not read front matter, and would show "status: accepted" as a
# heading above the title. Run by .github/workflows/docs.yml on its own
# checkout, before mdBook builds; the files in the repository keep their
# front matter, which the ADR format requires.
#
#     awk -f .github/scripts/adr-status.awk docs/adr/0001-engine-game-boundary.md

NR == 1 && /^---$/ { front = 1; next }
front && /^---$/ { front = 0; next }
front && /^status:/ { status = $0; sub(/^status: */, "", status); next }
front { next }
!titled && /^# / { print; print ""; if (status != "") print "**Status:** " status; titled = 1; next }
{ print }
