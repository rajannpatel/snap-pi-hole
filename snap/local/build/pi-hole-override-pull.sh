#!/bin/bash
# Safely silence the SC2016 information warnings
# since we intentionally use single quotes to prevent early evaluation of variables like $SNAP and ${i}.
#
# shellcheck disable=SC2016

set -e

craftctl default
cd "${CRAFT_PART_SRC}"

PATCHES_DIR="${CRAFT_PROJECT_DIR}/snap/local/patches"

# Apply all single-file patches. patch --forward skips any hunk that has already
# been applied, making this safe to run on a cached (previously-patched) source tree.
# patch --strip=1 strips the a/ b/ prefix from the unified diff paths.
for patch_file in "${PATCHES_DIR}"/*.patch; do
    echo "Applying patch: ${patch_file}"
    patch --forward --strip=1 --input="${patch_file}"
done

# 1. Redirect PID file paths to /etc/pihole/ (layout-mounted to $SNAP_DATA/etc/pihole/).
# Operates across all files in the tree - not suitable for a single-file patch.
# Handle /var/run/ before /run/ to avoid partial-match corruption.
grep --exclude-dir=.git -rlZ '/run/pihole-FTL.pid' . | xargs -0 -r sed -i \
  -e 's|/var/run/pihole-FTL.pid|/etc/pihole/pihole-FTL.pid|g' \
  -e 's|/run/pihole-FTL.pid|/etc/pihole/pihole-FTL.pid|g'

# 2. Strip readonly modifier from FTL_PID_FILE to prevent bash local variable
# scope collisions inside subshells. Operates across all files in the tree.
grep --exclude-dir=.git -rlZ 'readonly FTL_PID_FILE' . | xargs -0 -r sed -i 's/readonly FTL_PID_FILE/FTL_PID_FILE/g'

# 3. Neuter chown pihole:pihole commands since snap daemon runs as root and
# pihole user does not exist. Operates across all files in the tree.
grep --exclude-dir=.git -rlZ 'chown pihole:pihole' . | xargs -0 -r sed -i 's|chown pihole:pihole|true # chown pihole:pihole|g'

# 4. Force the use of snap-staged GNU coreutils.
# Upstream scripts sanitize $PATH (e.g., piholeDebug.sh sets it to /usr/bin:/bin:...),
# causing standard commands to resolve to the base core26 snap's rust-coreutils
# symlinks. This triggers AppArmor execution denials for lesser-used utils.
# First strip any existing absolute prefix (normalize to bare command name),
# then re-prefix with the absolute $SNAP path. Operates across all .sh files and pihole CLI.
find . -type f \( -name '*.sh' -o -name 'pihole' \) -exec sed -i -E \
  -e 's|/usr/bin/truncate|truncate|g' \
  -e 's|/usr/bin/timeout|timeout|g' \
  -e 's|/usr/bin/mktemp|mktemp|g' \
  -e 's|/bin/truncate|truncate|g' \
  -e 's|/bin/timeout|timeout|g' \
  -e 's|/bin/mktemp|mktemp|g' {} +
find . -type f \( -name '*.sh' -o -name 'pihole' \) -exec sed -i -E 's/(^|[ \t;|$(])(timeout|truncate|mktemp)([ \t]+)/\1"$SNAP\/usr\/bin\/\2"\3/g' {} +

# Prepend staged paths at the top of all shell scripts (line 2, right after shebang)
find . -type f \( -name '*.sh' -o -name 'pihole' \) -exec sed -i '2i export PATH="$SNAP/usr/sbin:$SNAP/usr/bin:$SNAP/sbin:$SNAP/bin:$PATH"' {} +

# Patch hardcoded PATH assignments in case they overwrite the launcher's environment
find . -type f \( -name '*.sh' -o -name 'pihole' \) -exec sed -i -E 's|PATH=(["'\''\x27]?)(/usr/)|PATH=\1$SNAP/usr/sbin:$SNAP/usr/bin:$SNAP/sbin:$SNAP/bin:\2|g' {} +

# Patch-rot guard: fail the build loudly if any expected substitution was missed.
# If upstream renames a function or rewords a string, we catch it here rather than
# silently shipping a broken snap.
if grep -nF 'service pihole-FTL' advanced/Scripts/piholeLogFlush.sh; then
  echo "ERROR: piholeLogFlush.sh still references 'service pihole-FTL' after patch" >&2
  exit 1
fi
if grep --exclude-dir=.git -rnF '/run/pihole-FTL.pid' .; then
  echo "ERROR: PID redirect missed a file" >&2
  exit 1
fi
if grep -nF 'systemctl is-active "${i}"' advanced/Scripts/piholeDebug.sh; then
  echo "ERROR: piholeDebug.sh still references systemctl is-active for FTL" >&2
  exit 1
fi
if grep -nF 'systemctl status --full --no-pager' advanced/Scripts/piholeDebug.sh; then
  echo "ERROR: piholeDebug.sh still references systemctl status for FTL" >&2
  exit 1
fi
if grep --exclude-dir=.git -rE '/(usr/)?bin/(truncate|timeout|mktemp)' . | grep -vF '$SNAP'; then
  echo "ERROR: Absolute path to /bin/truncate, /usr/bin/timeout, or /usr/bin/mktemp still exists after patching" >&2
  exit 1
fi

