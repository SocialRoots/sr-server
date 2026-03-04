# SocialRoots Backup

## Requirements

```bash
pip install python-dotenv
sudo apt install rclone
```

## Configuration

Add to `.env`:
```bash
BACKUP_DIR=/path/to/backups
```

Set up rclone remote (for Google Drive):
```bash
rclone config
# Follow prompts to create a remote named 'gdrive'
```

## Usage

```bash
# Backup single database
python bin/backup/db_backup.py --env .env --db sr_notes_int

# Backup all databases
python bin/backup/db_backup.py --env .env --all

# Sync backups to Google Drive
python bin/backup/db_backup.py --env .env --rclone gdrive

# Cleanup old backups
python bin/backup/db_backup.py --env .env --cleanup

# Full daily routine
python bin/backup/db_backup.py --env .env --all --rclone gdrive --cleanup
```

## Folder Structure

```
BACKUP_DIR/
└── postgres/
    └── YYYY-MM-DD/
        └── YYYYMMDD_HHMMSS_dbname.sql.tgz
```

## Retention Policy

- **Daily**: Last 7 days
- **Weekly**: Last 4 Sundays

## Cron (Daily at 2am)

```bash
0 2 * * * /usr/bin/python3 /path/to/bin/backup/db_backup.py --env /path/to/.env --all --rclone gdrive --cleanup
```
