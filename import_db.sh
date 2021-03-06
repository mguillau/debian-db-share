#!/bin/bash
# Retrieve administrative databases for libnss-db from a primary host

# Installation on secondary host
# ------------------------------
# 1- Create password-less ssh key pair for root:
#    $ sudo ssh-keygen -N "" -f /root/.ssh/id_rsa_dbshare
# 2- Copy the content of /root/.ssh/id_rsa_dbshare.pub as a new line into
#    /home/dbshare/.ssh/authorized_keys of the primary host (assuming
#    `dbshare` is the username used to run export_db.sh on the primary host)
# 3- Provide PRIMARY_HOST, EXPORT_USER, EXPORT_DB_DIR and LOCAL_PRIVATE_SSH_KEY for
#    fetching exported databases
# 4- Adapt DBS below to choose which databases to import.
# 5- Add cron entry to execute this script as root every 5 minutes
#    $ sudo crontab -e
#    */5 * * * * /bin/bash /full/path/to/import_db.sh
# 6- Make sure that you have installed the libnss-db package and added `db`
#    as a source for the databases in /etc/nsswitch.conf

# Info to connect to primary host
PRIMARY_HOST="primary.machine.com"  # Domain name, openssh alias or IP address of primary host
EXPORT_USER="dbshare"  # Username on primary host that exports databases
EXPORT_DBDIR="/home/dbshare/dbexport"  # Directory where databases are exported on the primary host
                                       # (should match the value in export_db.sh)
LOCAL_PRIVATE_SSH_KEY="/root/.ssh/id_rsa_dbshare"  # Location of the private key

# Databases to fetch
#DBS="passwd group ethers protocols rpc services shadow netgroup"
DBS="passwd group shadow"

set -euo pipefail

# Directory where the databases should be exported for libnss-db
IMPORT_DBDIR=$(awk \
  'BEGIN { FS="=" }; {gsub(/ /,"");} /^VAR_DB=/ {print $2;}' \
  /etc/default/libnss-db)

# Programs used
MAKEDB="makedb --quiet"

# Sync data from primary host to a tempdir
TEMPDIR=$(mktemp -d)
trap "rm -rf '${TEMPDIR}'" EXIT

# Ref: https://stackoverflow.com/questions/20140743/using-file-locks-with-rsync
function rsync_wrap() {
  # Get shared lock for the duration of rsync
  LOCK="${EXPORT_DBDIR}/lock"
  exec {fd}< "${LOCK}"
  flock -w 3 -s ${fd} || {
    echo "rsync error 117: failed to lock ${EXPORT_DBDIR}" 1>&2
    return 117
  }
  # Call real rsync with original arguments
  rsync "$@"
  # Note, return is important, do not let it fall out
  return $?
}

# Build remote command, define vars and functions inside the command
remote_cmd="
  $( declare -p EXPORT_DBDIR )
  $( declare -f rsync_wrap )

  rsync_wrap "

# handle network timeouts in SSH, not in rsync,
# because rsync does not know that waiting for lock is expected
rsync \
  -qtL --chmod 0640 --chown root:root \
  --rsync-path="${remote_cmd}" \
  -e "ssh -o BatchMode=yes -o ServerAliveCountMax=3 -o ServerAliveInterval=30 -i '${LOCAL_PRIVATE_SSH_KEY}'" \
  "${EXPORT_USER}"@"${PRIMARY_HOST}":"${EXPORT_DBDIR}/*.db" "${TEMPDIR}/"


# Process databases to sync
for db in $DBS; do
  DB="${TEMPDIR}/${db}.db"
  if [ -f "$DB" ]; then
    if [[ "$db" == "shadow" ]]; then
      chgrp shadow "$DB";
    else
      chmod a+r "$DB";
    fi
    mv "$DB" "${IMPORT_DBDIR}/"
    echo "Imported ${db}: $(${MAKEDB} -u "${IMPORT_DBDIR}/${db}.db" | wc -l) entries"
  else
    echo "Skipping ${db}: was it exported?"
  fi
done
