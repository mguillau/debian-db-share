#!/bin/bash
# Extract administrative databases into .db files for libnss-db
#
# Installation on primary host
# ----------------------------
# 1- Create a user just for running this script, such as `dbshare`.
#    $ sudo adduser --ingroup shadow --disabled-password dbshare
# 2- Ensure this user is member of the `shadow` group. (Already done in above example)
# 3- Adapt PASSWD_REGEXP, GROUP_REGEXP and EXPORT_DBDIR below to match your wishes.
# 4- Add cron entry to execute this script as `dbshare` every 5 minutes
#    $ sudo -u dbshare crontab -e
#    */5 * * * * /bin/bash /full/path/to/export_db.sh

# Databases to generate
#DBS = passwd group ethers protocols rpc services shadow netgroup
#DBS="passwd group shadow"

# Filter lines of `passwd` to export (default: UID between 10000 and 19999)
PASSWD_REGEXP="^[^:]*:x:1[0-9][0-9][0-9][0-9]:"
# Filter lines of `group` to export (default: GID between 10000 and 19999)
GROUP_REGEXP="^[^:]*:[*x]:1[0-9][0-9][0-9][0-9]:"
# Directory where the databases are exported
EXPORT_DBDIR="${HOME}/dbexport"

#
set -euxo pipefail

# Ensure private output
mkdir -p "${EXPORT_DBDIR}"
chmod 0700 "${EXPORT_DBDIR}"

# Get exclusive lock until the end of the script. Wait up to 3 minutes
LOCK="${EXPORT_DBDIR}/lock"
exec {fd}> "${LOCK}"
flock -w 180 -x ${fd} || exit 1

# Programs used
MAKEDB="makedb --quiet"

# Export passwd data to $EXPORT_DBDIR/passwd.db
PASSWD_DB="${EXPORT_DBDIR}/passwd.db"
getent passwd | grep "${PASSWD_REGEXP}" | sort -u \
  | awk 'BEGIN { FS=":"; OFS=":"; cnt=0 } \
	  /^[ \t]*$$/ { next } \
	  /^[ \t]*#/ { next } \
	  { printf "0%u ", cnt++; print } \
	  /^[^#]/ { printf ".%s ", $1; print; \
	  printf "=%s ", $3; print }' \
  | (umask 022 && ${MAKEDB} -o "${PASSWD_DB}" -)
chmod g+r "${PASSWD_DB}"

echo "Exported ${PASSWD_DB} has $($MAKEDB -u "${PASSWD_DB}" | wc -l) entries"

# Export shadow data for those users to $EXPORT_DBDIR/shadow.db
# Warning: this is empty if run by a user which is not part of the `shadow` group
SHADOW_DB="${EXPORT_DBDIR}/shadow.db"
getent shadow | grep -f <( \
  getent passwd | grep ${PASSWD_REGEXP} | sort -u \
    | cut -d: -f1 | awk '{printf "^%s:\n", $1;}' \
) | sort -u | awk 'BEGIN { FS=":"; OFS=":"; cnt=0 } \
		 /^[ \t]*$$/ { next } \
		 /^[ \t]*#/ { next } \
		 { printf "0%u ", cnt++; print } \
		 /^[^#]/ { printf ".%s ", $1; print }' | \
	(umask 077 && ${MAKEDB} -o "${SHADOW_DB}" -)
chmod g+r "${SHADOW_DB}"

echo "Exported ${SHADOW_DB} has $(${MAKEDB} -u "${SHADOW_DB}" | wc -l) entries"

# Export group data to $EXPORT_DBDIR/group.db
GROUP_DB="${EXPORT_DBDIR}/group.db"
getent group | grep ${GROUP_REGEXP} | sort -u \
  | awk 'BEGIN { FS=":"; OFS=":"; cnt=0 } \
		 /^[ \t]*$$/ { next } \
		 /^[ \t]*#/ { next } \
		 { printf "0%u ", cnt++; print } \
		 /^[^#]/ { printf ".%s ", $1; print; \
			   printf "=%s ", $3; print }' \
  | (umask 022 && ${MAKEDB} -o "${GROUP_DB}" -)
chmod g+r "${GROUP_DB}"

echo "Exported ${GROUP_DB} has $(${MAKEDB} -u "${GROUP_DB}" | wc -l) entries"
