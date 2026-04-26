import subprocess, os, logging, sys
from datetime import datetime
from pathlib import Path
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")

# ── config ────────────────────────────────────────────────────
DATABASE_URL = os.environ["DATABASE_PUBLIC_URL"]
BACKUP_DIR   = Path.home() / "pg_backups"
TABLES       = ["contacts", "messages"]
KEEP_DAYS    = 30

PG_DUMP      = Path(r"C:\Program Files\PostgreSQL\17\bin\pg_dump.exe")

# ─────────────────────────────────────────────────────────────

BACKUP_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler(BACKUP_DIR / "backup.log", encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("pg_backup")


def run_dump(extra_flags: list[str], suffix: str) -> Path:
    stamp   = datetime.now().strftime("%Y%m%d_%H%M%S")
    outfile = BACKUP_DIR / f"sms_app_{suffix}_{stamp}.sql"
    table_flags = [flag for t in TABLES for flag in ("--table", t)]


    cmd = [str(PG_DUMP), *table_flags, *extra_flags, DATABASE_URL]

    log.info(f"Running dump → {outfile.name}")

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )

    if result.returncode != 0:
        raise RuntimeError(f"pg_dump failed:\n{result.stderr}")

    outfile.write_text(result.stdout, encoding="utf-8")
    log.info(f"✓ {outfile.name}  ({outfile.stat().st_size:,} bytes)")
    return outfile


def prune_old_backups():
    cutoff = datetime.now().timestamp() - KEEP_DAYS * 86400
    for f in BACKUP_DIR.glob("*.sql"):
        if f.stat().st_mtime < cutoff:
            f.unlink()
            log.info(f"Pruned: {f.name}")


if __name__ == "__main__":
    log.info("=== pg backup starting ===")
    try:
        run_dump(["--data-only", "--column-inserts"], "data")
        run_dump(["--schema-only"],                      "schema")
        prune_old_backups()
        log.info("=== backup complete ===")
    except Exception as e:
        log.error(f"BACKUP FAILED: {e}")
        sys.exit(1)
