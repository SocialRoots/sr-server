#!/usr/bin/env python3
"""
SocialRoots Database Backup Script

Usage:
    python db_backup.py --env /path/to/.env --db sr_notes_int
"""

import argparse
import os
import subprocess
import sys
import tarfile
from datetime import datetime
from pathlib import Path


def load_config(env_file: str) -> dict:
    """Load and validate configuration from .env file."""

    env_path = Path(env_file)
    if not env_path.exists():
        sys.exit(f"Error: .env file not found: {env_file}")

    try:
        from dotenv import load_dotenv
        load_dotenv(env_path)
    except ImportError:
        sys.exit("Error: python-dotenv required. Install with: pip install python-dotenv")

    required = ['POSTGRES_USER', 'POSTGRES_PASSWORD', 'POSTGRES_HOST', 'POSTGRES_PORT', 'BACKUP_DIR']
    missing = [key for key in required if not os.getenv(key)]

    if missing:
        sys.exit(f"Error: Missing required config: {', '.join(missing)}")

    return {
        'pg_user': os.getenv('POSTGRES_USER'),
        'pg_password': os.getenv('POSTGRES_PASSWORD'),
        'pg_host': os.getenv('POSTGRES_HOST'),
        'pg_port': os.getenv('POSTGRES_PORT'),
        'backup_dir': os.getenv('BACKUP_DIR'),
    }


def dump_database(db_name: str, config: dict) -> Path:
    """Dump a single database to SQL file."""

    date_str = datetime.now().strftime('%Y-%m-%d')
    backup_dir = Path(config['backup_dir']) / 'postgres' / date_str
    backup_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    output_file = backup_dir / f"{timestamp}_{db_name}.sql"

    cmd = [
        'pg_dump',
        '-U', config['pg_user'],
        '-h', config['pg_host'],
        '-p', config['pg_port'],
        '-w',
        '-d', db_name,
        '--exclude-table', 'logs',
        '-f', str(output_file),
    ]

    env = os.environ.copy()
    env['PGPASSWORD'] = config['pg_password']

    print(f"Dumping {db_name}...", end=' ', flush=True)

    result = subprocess.run(cmd, env=env, capture_output=True, text=True)

    if result.returncode != 0:
        sys.exit(f"FAILED\n  Error: {result.stderr}")

    print(f"OK ({output_file.stat().st_size / 1024:.1f} KB)")
    return output_file


def compress_backup(sql_file: Path) -> Path:
    """Compress SQL file to .tgz and remove original."""

    tgz_file = sql_file.with_suffix('.sql.tgz')

    print(f"Compressing to {tgz_file.name}...", end=' ', flush=True)

    with tarfile.open(tgz_file, 'w:gz') as tar:
        tar.add(sql_file, arcname=sql_file.name)

    sql_file.unlink()

    print(f"OK ({tgz_file.stat().st_size / 1024:.1f} KB)")
    return tgz_file


def cleanup_old_backups(backup_dir: str):
    """Keep last 7 daily + last 4 weekly (Sundays)."""

    postgres_dir = Path(backup_dir) / 'postgres'
    if not postgres_dir.exists():
        print("No backups to clean up")
        return

    today = datetime.now().date()

    # Get all date folders
    date_folders = []
    for folder in postgres_dir.iterdir():
        if folder.is_dir():
            try:
                folder_date = datetime.strptime(folder.name, '%Y-%m-%d').date()
                date_folders.append((folder_date, folder))
            except ValueError:
                continue

    date_folders.sort(reverse=True)  # Newest first

    keep = set()
    sunday_count = 0

    for folder_date, folder in date_folders:
        days_old = (today - folder_date).days

        # Keep last 7 days
        if days_old < 7:
            keep.add(folder)
        # Keep Sundays for 4 weeks
        elif folder_date.weekday() == 6 and sunday_count < 4:
            keep.add(folder)
            sunday_count += 1

    # Remove old folders
    removed = 0
    for folder_date, folder in date_folders:
        if folder not in keep:
            print(f"  Removing {folder.name}...", end=' ')
            import shutil
            shutil.rmtree(folder)
            print("OK")
            removed += 1

    print(f"Cleanup: kept {len(keep)}, removed {removed}")


def get_all_databases() -> list:
    """Find all database names from DB_NAME_* environment variables."""
    databases = []
    for key, value in os.environ.items():
        if key.startswith('DB_NAME_') and value:
            databases.append(value)
    return databases


def sync_to_remote(remote_name: str, backup_dir: str):
    """Sync backup directory to rclone remote."""

    # Check if rclone is installed
    result = subprocess.run(['which', 'rclone'], capture_output=True)
    if result.returncode != 0:
        sys.exit("Error: rclone not installed. Install with: sudo apt install rclone")

    # Check if remote exists
    result = subprocess.run(['rclone', 'listremotes'], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"Error: Failed to list rclone remotes: {result.stderr}")

    remotes = [r.rstrip(':') for r in result.stdout.strip().split('\n') if r]
    if remote_name not in remotes:
        sys.exit(f"Error: Remote '{remote_name}' not found. Available: {', '.join(remotes)}")

    # Sync backup directory
    remote_path = f"{remote_name}:"
    print(f"Syncing {backup_dir} to {remote_path}...", end=' ', flush=True)

    result = subprocess.run(
        ['rclone', 'sync', backup_dir, remote_path],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        sys.exit(f"FAILED\n  Error: {result.stderr}")

    print("OK")


def main():
    parser = argparse.ArgumentParser(description='SocialRoots Database Backup')
    parser.add_argument('--env', required=True, help='Path to .env file')
    parser.add_argument('--db', help='Database name to backup')
    parser.add_argument('--all', action='store_true', help='Backup all DB_NAME_* databases')
    parser.add_argument('--rclone', help='rclone remote name to sync backups to')
    parser.add_argument('--cleanup', action='store_true', help='Remove old backups (keep 7 daily + 4 weekly)')
    args = parser.parse_args()

    if not args.db and not args.all and not args.rclone and not args.cleanup:
        sys.exit("Error: Must specify --db, --all, --rclone, or --cleanup")

    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Starting")

    config = load_config(args.env)

    # Backup databases if requested
    if args.db or args.all:
        databases = get_all_databases() if args.all else [args.db]

        if not databases:
            sys.exit("Error: No databases found")

        print(f"Backing up {len(databases)} database(s)\n")

        for db_name in databases:
            sql_file = dump_database(db_name, config)
            compress_backup(sql_file)
            print()

    # Sync to remote if requested
    if args.rclone:
        sync_to_remote(args.rclone, config['backup_dir'])

    # Cleanup old backups if requested
    if args.cleanup:
        cleanup_old_backups(config['backup_dir'])

    print("Done!")
    return 0


if __name__ == '__main__':
    sys.exit(main())
