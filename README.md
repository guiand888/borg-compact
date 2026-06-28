# Borg Backup Compaction

Automated Borg repository compaction with quota management and healthcheck integration

[![asciicast](https://raw.githubusercontent.com/guiand888/borg-compact/assets/borg-compact-asciinema.svg)](https://asciinema.org)

## Background

Automates compaction of Borg backup repositories running in Docker containers. Handles quota adjustments when repository size exceeds limits, integrates with UptimeKuma for monitoring, and includes dry-run capability for safe testing.

**Quota Management Note:** Borg Warehouse sets quotas via SSH command restrictions (`borg serve --storage-quota`), but `borg compact` enforces the repository's own `storage_quota` config. When actual usage exceeds this quota, the script temporarily expands it above current usage, runs compact, then restores the original quota.

## Install

1. Place `borg_compact.sh` in your target directory
2. Make it executable: `chmod +x borg_compact.sh`
3. For cron usage, you can consider using a `cron-wrapper` as needed: see [guiand888/cron-wrapper](https://github.com/guiand888/cron-wrapper)

## Usage

### Environment Variables

Required:
```bash
export UPTIMEKUMA_DOMAIN=your-domain.com
export HEALTHCHECK_ID=your-healthcheck-id
```

Optional:
```bash
export CONTAINER_NAME=borgwarehouse-borgwarehouse-1
export REPO_DIR=/home/borgwarehouse/repos
export EXTRA_QUOTA_G=10
export VERBOSE=false
```

### Run

```bash
# Normal execution
./borg_compact.sh

# Dry-run mode (lists repos and actions without making changes)
./borg_compact.sh --dry-run

# Force verbose output
VERBOSE=true ./borg_compact.sh

# Via cron
0 3 * * * /path/to/borg_compact.sh
```

## Contributing

Pull requests accepted. For major changes, please open an issue first to discuss what you would like to change.

## License

AGPLv3
