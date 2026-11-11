# sed -E -f tools/redact-build-log.sed: what's left to hide in xcodebuild output before it reaches a
# job log. This repository is public, so its run logs are too. GitHub masks the workflow's secrets
# itself; these lines replace the personal details it can't know about.
# Signing identities carry the developer's name and team ID: "Apple Development: Name (ABCDE12345)".
s/((Apple|iPhone|iOS|Mac) (Development|Distribution|Developer)|Developer ID (Application|Installer)): [^"()]*(\([^)]*\))?/<signing identity>/g
# Apple account emails.
s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g
# Team names: an individual developer's team is named after them.
s/([Tt]eam:? )"[^"]*"/\1"<team>"/g
s/([Tt]eam:? )'[^']*'/\1'<team>'/g
