#!/usr/bin/env bash
set -euo pipefail

readonly source_dir=/mnt/nas/backups/asterisk
readonly lock_file=/mnt/nas/backups/.asterisk-git-backup.lock
readonly ssh_key=/etc/ssh/asterisk_backup_key
readonly known_hosts=/etc/ssh/ssh_known_hosts
readonly repository="@repository@"

if [[ ! -d "$source_dir/.git" ]]; then
  echo "Asterisk backup source is not a Git checkout: $source_dir" >&2
  exit 1
fi
if [[ ! -r "$ssh_key" ]]; then
  echo "Missing private backup key $ssh_key; provision it outside the repository." >&2
  exit 1
fi
if [[ ! -s "$known_hosts" ]] || ! ssh-keygen -F github.com -f "$known_hosts" >/dev/null; then
  echo "Missing verified github.com host key in $known_hosts." >&2
  exit 1
fi

exec 9>"$lock_file"
if ! flock -n 9; then
  echo "Another cluster node holds the shared backup lock; skipping this run."
  exit 0
fi

git -C "$source_dir" remote set-url origin "$repository"
git -C "$source_dir" add --all
if [[ -n "$(git -C "$source_dir" diff --cached --name-only)" ]]; then
  git -C "$source_dir" \
    -c user.name="Asterisk Backup" \
    -c user.email="asterisk-backup@localhost" \
    commit -m "Automated Asterisk configuration backup"
fi

export GIT_SSH_COMMAND="ssh -i $ssh_key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts"
git -C "$source_dir" push --set-upstream origin HEAD
