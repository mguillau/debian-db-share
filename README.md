# debian-db-share

Simple scripts to export and import administrative databases as .db files for easy distribution of
credentials centralized in a primary host to several secondary hosts.

## Description

In a situation where you have a small number of hosts that are meant to be used by a small number of
users and where you want users to have the same password, UID and GID on all hosts, resorting to
OpenLDAP for user database sharing is an overkill and adds maintenance work for hobby sysadmins.

The two scripts in this repository provide a simple alternative for a centralized setup. It exports
(a part of) the administrative databases (currenty `passwd`, `shadow` and `group`) of a primary host,
which are then fetched by secondary hosts. This enables the users of the primary host to also
gain access to the secondary hosts with the same passwords, UID, GID and other user information.

The high-level setup is the following:
- User and group data is centralized on a primary host, where users have to do all their info and
  password changes. Ideally this host is always on and connected to the network, just as an OpenLDAP
  server.
- On the primary host, the `export_db.sh` script runs every 5 minutes to extract the database
  entries matching a range of UID and GID (by default, 10000-19999). Those entries are stored in
  `{passwd,shadow,group}.db` files that are compatible with `libnss-db`. Exporting only a UID/GID
  range prevents from exporting local system user/group information. Each host can retain
  its own local users (which may vary from one host to the next based on the distribution, the
  installed packages, etc.).
- On any secondary host, the `import_db.sh` script runs every 5 minutes to securely fetch (via
  `rsync`) the resulting .db files from the primary host, storing them where `libnss-db` expects
  them. Using .db files and `libnss-db` helps avoid having to tamper with the local databases 
  `/etc/{passwd,shadow,group}`.
- If the secondary host is properly configured for accepting entries from `libnss-db`, the users of
  the primary host now also have access to the secondary host as local users with.

## Quick comparison with the OpenLDAP solution

Why resorting to `OpenLDAP` didn't really work for me:

- `OpenLDAP` needs extra open ports, and its configuration for a secure usage via StartTLS is difficult

Instead, `debian-db-share` uses rsync to securely synchronize files via ssh key pairs.

- The formatting of entries for ldap{add,modify,...} is powerful but very unnatural

Instead, `debian-db-share` relies on regular database entries created and modified on the primary host.
Most commonly, these are local users in /etc/{passwd,shadow,group}, managed by the usual `adduser`
, `deluser`, etc. `debian-db-share` gets entry data using `getent`, so it could really be any other
backend.

- Configuring [NSS](https://wiki.debian.org/LDAP/NSS#NSS_Setup_with_libnss-ldapd),
  [PAM](https://wiki.debian.org/LDAP/PAM) and `nslcd` for LDAP is not trivial
- Configuring `nscd` for caching credentials in a reasonable manner for laptops that may remain
  disconnected for some time is also difficult

Instead, with `debian-db-share`, once the .db files are sync-ed, they become a local source for
administrative databases. No network latency at login, no cache issues for disconnected hosts. The
drawback is that there is a delay in propagating the database files: a locked user on the primary
host can still access secondary hosts indefinitely on disconnected hosts and for several minutes
even on connected hosts.

## Installation

### Primary host

- Install dependencies:

```sudo apt install openssh libnss-db```

- Create a user just for running the export script, such as `dbshare`:

```sudo adduser --ingroup shadow --disabled-password dbshare```

- Ensure this user is member of the `shadow` group. (Already done in above command)

- Adapt `PASSWD_REGEXP`, `GROUP_REGEXP` and `EXPORT_DBDIR` in `export_db.sh` to match your wishes:
  the users and groups to select and where to store the resulting .db files.

- Copy the resulting script file to a location such as `/home/dbshare/bin/export_db.sh`, readable
  by the `dbshare` user.

- Add a cron entry to execute this script as `dbshare` every 5 minutes:

```sudo -u dbshare crontab -e```

> `*/5 * * * * /bin/bash /home/dbshare/bin/export_db.sh`

You're done! Every 5 minutes, the files in `${EXPORT_DBDIR}/{passwd,shadow,group}.db` will be
updated with the latest version of the matching database entries, ready to be fetched by secondary
hosts.

### Secondary hosts

- Install dependencies:

```sudo apt install openssh libnss-db rsync```

- Create password-less ssh key pair for root:

```sudo ssh-keygen -N "" -f /root/.ssh/id_rsa_dbshare```

- Copy the content of `/root/.ssh/id_rsa_dbshare.pub` as a new line into
  `/home/dbshare/.ssh/authorized_keys` on the primary host (assuming
  `dbshare` is the username you used when configuring the primary host).

- Adapt `PRIMARY_HOST` (host name or IP), `EXPORT_USER` (`dbshare`),
  `EXPORT_DBDIR` (`/`) and `LOCAL_PRIVATE_SSH_KEY` (`/root/.ssh/id_rsa_dbshare`) in
  `import_db.sh` for fetching exported databases

- Adapt `DBS` in `import_db.sh` to choose which databases to import.

- Add a cron entry to execute this script as root every 5 minutes

```sudo crontab -e```

> */5 * * * * /bin/bash /full/path/to/import_db.sh

- Make sure that you have added `db` as a source for the passwd, group and shadow databases in
  `/etc/nsswitch.conf`

Example of `/etc/nsswitch.conf` on a secondary host:

```
# /etc/nsswitch.conf
#
# Example configuration of GNU Name Service Switch functionality.
# If you have the `glibc-doc-reference' and `info' packages installed, try:
# `info libc "Name Service Switch"' for information about this file.

passwd:         compat db systemd
group:          compat db systemd
shadow:         compat db
gshadow:        files

hosts:          files mdns4_minimal [NOTFOUND=return] dns myhostname ldap
networks:       files

protocols:      db files
services:       db files
ethers:         db files
rpc:            db files

netgroup:       nis
```

The users and groups exported from the primary host are now available on the secondary host and
refreshed every 5 minutes.

- Optionally, add creation of homedir at first login for users using `sudo pam-auth-update`

Repeat all these steps for every secondary host.

## Caveats

- I recommend to use the scripts in this repository only if you understand what they do.
- The `import_db.sh` script overwrites the {passwd,shadow,group}.db files for `libnss-db` on the
  secondary hosts, making the usage of `libnss-db` by this script exclusive. You should not use the
  `import_db.sh` script as is if you are already using `libnss-db` for any of passwd, shadow or
  group!
- Make sure that the algorithm used by crypt for password hasing on the primary host is compatible
  and available on your secondary hosts (the default of debian 11, `yescrypt`, is not available on
  Ubuntu). A safer choice is `sha512`, which you can specify in `/etc/pam.d/common-password`.
- By the design of the file-based synchronization, there is a delay to propagate updates to secondary
  hosts. Because imported users appear as local on secondary hosts, they will still be able to use
  their old passwords until the update is effective, that is when both the primary and secondary
  hosts are up, connected to the network and able to establish the ssh connection.
- The scripts are not robust to attacks by the root user of the primary host, who can potentially
  forge malicious .db files to be consumed by the root users of the secondary hosts. In other words,
  there is a risk that the root user of the primary host (or that an attacker gaining root access of
  the primary host) can gain root access to secondary hosts -- in any case he is gaining control of
  the user, shadow and group databases of the secondary hosts.
