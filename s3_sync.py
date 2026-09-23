#!/usr/bin/env python3


import argparse
import datetime as dt
import logging
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage
from pathlib import Path

import boto3
from botocore.exceptions import ClientError


def setup_logging():
    ts = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    logfile = f"s3_sync_{ts}.log"
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s  %(levelname)-7s %(message)s",
        handlers=[logging.FileHandler(logfile), logging.StreamHandler(sys.stdout)],
    )
    logging.info("Log file: %s", logfile)
    return logfile



def object_exists_same_size(s3, bucket, key, local_size):
    try:
        head = s3.head_object(Bucket=bucket, Key=key)
        return head["ContentLength"] == local_size
    except ClientError as e:
        if e.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
            return False
        raise  # a real error (perms, throttling) — let it surface


def build_extra_args(kms_key_id):
    if kms_key_id:
        return {"ServerSideEncryption": "aws:kms", "SSEKMSKeyId": kms_key_id}
    return {}


def sync(directory, bucket, prefix, kms_key_id):
    s3 = boto3.client("s3")
    extra_args = build_extra_args(kms_key_id)

    scanned = uploaded = skipped = 0
    failures = []

    root = Path(directory).resolve()
    if not root.is_dir():
        logging.error("Not a directory: %s", root)
        sys.exit(2)

    logging.info("Syncing %s -> s3://%s/%s", root, bucket, prefix or "")
    if kms_key_id:
        logging.info("Server-side encryption: aws:kms (%s)", kms_key_id)

    for path in root.rglob("*"):
        if not path.is_file():
            continue
        scanned += 1

        # Preserve the directory structure under the optional prefix, using
        # forward slashes for the S3 key regardless of the local OS.
        rel = path.relative_to(root).as_posix()
        key = f"{prefix.rstrip('/')}/{rel}" if prefix else rel
        size = path.stat().st_size

        try:
            if object_exists_same_size(s3, bucket, key, size):
                skipped += 1
                logging.info("skip    %s (already present)", key)
                continue

            s3.upload_file(str(path), bucket, key, ExtraArgs=extra_args)
            uploaded += 1
            logging.info("upload  %s (%d bytes)", key, size)
        except ClientError as e:
            failures.append((key, str(e)))
            logging.error("FAILED  %s -> %s", key, e)

    return {
        "scanned": scanned,
        "uploaded": uploaded,
        "skipped": skipped,
        "failed": len(failures),
        "failures": failures,
    }


# ---------------------------------------------------------------------------
# Email summary. Optional — only fires if the SMTP env vars are set, so the
# script still works fine for a quick local run without them.
# ---------------------------------------------------------------------------
def send_email_summary(result, bucket):
    required = ["SMTP_HOST", "SMTP_PORT", "SMTP_USER", "SMTP_PASS", "MAIL_FROM", "MAIL_TO"]
    if not all(os.environ.get(v) for v in required):
        logging.info("SMTP env vars not set — skipping email summary.")
        return

    status = "OK" if result["failed"] == 0 else f"{result['failed']} FAILED"
    body_lines = [
        f"S3 sync summary for bucket: {bucket}",
        "",
        f"  Files scanned : {result['scanned']}",
        f"  Uploaded      : {result['uploaded']}",
        f"  Skipped       : {result['skipped']}",
        f"  Failed        : {result['failed']}",
    ]
    if result["failures"]:
        body_lines += ["", "Failures:"]
        body_lines += [f"  - {k}: {err}" for k, err in result["failures"]]

    msg = EmailMessage()
    msg["Subject"] = f"[s3_sync] {bucket}: {status}"
    msg["From"] = os.environ["MAIL_FROM"]
    msg["To"] = os.environ["MAIL_TO"]
    msg.set_content("\n".join(body_lines))

    try:
        ctx = ssl.create_default_context()
        with smtplib.SMTP(os.environ["SMTP_HOST"], int(os.environ["SMTP_PORT"])) as server:
            server.starttls(context=ctx)
            server.login(os.environ["SMTP_USER"], os.environ["SMTP_PASS"])
            server.send_message(msg)
        logging.info("Emailed summary to %s", os.environ["MAIL_TO"])
    except Exception as e:  # don't fail the whole run just because email broke
        logging.error("Could not send email summary: %s", e)


def main():
    parser = argparse.ArgumentParser(description="Sync a local directory to S3 (skip existing).")
    parser.add_argument("--dir", required=True, help="Local directory to sync.")
    parser.add_argument("--bucket", required=True, help="Target S3 bucket, e.g. artifacts-6729.")
    parser.add_argument("--prefix", default="", help="Optional key prefix inside the bucket.")
    parser.add_argument("--kms-key-id", default=None, help="Optional KMS key ARN/ID for SSE-KMS.")
    args = parser.parse_args()

    setup_logging()
    result = sync(args.dir, args.bucket, args.prefix, args.kms_key_id)

    logging.info("---- summary ----")
    logging.info("scanned=%d uploaded=%d skipped=%d failed=%d",
                 result["scanned"], result["uploaded"], result["skipped"], result["failed"])

    send_email_summary(result, args.bucket)

    # Non-zero exit if anything failed, so CI or a cron wrapper notices.
    sys.exit(1 if result["failed"] else 0)


if __name__ == "__main__":
    main()
