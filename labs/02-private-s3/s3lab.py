#!/usr/bin/env python3
"""W2 private S3 lab helper: wraps scripts/lab.py clean_env/run_aws.

- Mutating subcommands create resources owned by this lab only.
- Presigned URLs are generated and consumed IN MEMORY only; never printed.
- Anonymous get uses --no-sign-request to prove the bucket is private.
"""
import argparse
import hashlib
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import lab  # lab.py: context(), run_aws(), LabError (clean_env inside run_aws)

BUCKET = "lab02-5329-b11323222-20260915"
KEY = "hello-b11323222.txt"


def region():
    return lab.context()["region"]


def cmd_create_bucket():
    out = lab.run_aws(["s3api", "create-bucket", "--bucket", BUCKET], region())
    print(json.dumps(out, indent=2))


def cmd_put_public_block():
    lab.run_aws(["s3api", "put-public-access-block", "--bucket", BUCKET,
                 "--public-access-block-configuration",
                 "BlockPublicAcls=true,IgnorePublicAcls=true,"
                 "BlockPublicPolicy=true,RestrictPublicBuckets=true"], region())
    print("PublicAccessBlock set: 4 x true")


def cmd_get_public_block():
    out = lab.run_aws(["s3api", "get-public-access-block", "--bucket", BUCKET], region())
    print(json.dumps(out, indent=2))


def cmd_put_object(body):
    out = lab.run_aws(["s3api", "put-object", "--bucket", BUCKET, "--key", KEY,
                       "--body", str(body)], region())
    print("PUT", KEY, "->", json.dumps(out))


def cmd_get_object(dest):
    out = lab.run_aws(["s3api", "get-object", "--bucket", BUCKET, "--key", KEY,
                       str(dest)], region())
    print("GET", KEY, "->", str(dest), "metadata:", json.dumps(out))


def _sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def cmd_compare(file1, file2):
    b1, b2 = Path(file1).read_bytes(), Path(file2).read_bytes()
    print(f"bytes_equal={b1 == b2}")
    print(f"sha256({file1})={_sha256(file1)}")
    print(f"sha256({file2})={_sha256(file2)}")


def cmd_anonymous_get(dest):
    try:
        lab.run_aws(["s3api", "get-object", "--no-sign-request",
                     "--bucket", BUCKET, "--key", KEY, str(dest)], region())
        print("ANONYMOUS GET SUCCEEDED (UNEXPECTED)")
    except lab.LabError as exc:
        print("Anonymous GET rejected (expected):", exc)


def cmd_presign_test(expires, wait):
    import boto3
    s3 = boto3.Session(profile_name="learnerlab",
                       region_name=region()).client("s3")
    url = s3.generate_presigned_url(
        "get_object", Params={"Bucket": BUCKET, "Key": KEY}, ExpiresIn=expires)
    # URL stays in memory; never printed to stdout/logs.

    def try_get(label):
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                data = r.read()
                print(f"{label}: status={r.status} bytes={len(data)}")
        except urllib.error.HTTPError as e:
            print(f"{label}: status={e.code} rejected (expected after expiry)")
        except Exception as e:
            print(f"{label}: {type(e).__name__}: {e}")

    try_get("within-expiry")
    print(f"sleeping {wait}s to let URL expire ...")
    time.sleep(wait)
    try_get("after-expiry")


def cmd_list_objects():
    out = lab.run_aws(["s3api", "list-objects", "--bucket", BUCKET], region())
    print(json.dumps(out, indent=2))


def cmd_delete_object():
    lab.run_aws(["s3api", "delete-object", "--bucket", BUCKET, "--key", KEY], region())
    print("deleted", KEY)


def cmd_delete_bucket():
    lab.run_aws(["s3api", "delete-bucket", "--bucket", BUCKET], region())
    print("deleted bucket", BUCKET)


def cmd_head_bucket():
    try:
        lab.run_aws(["s3api", "head-bucket", "--bucket", BUCKET], region())
        print("bucket EXISTS (unexpected)")
    except lab.LabError as exc:
        print("bucket absent as expected:", exc)


def main():
    p = argparse.ArgumentParser(description="W2 private S3 lab helper")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("create-bucket")
    sub.add_parser("put-public-block")
    sub.add_parser("get-public-block")
    po = sub.add_parser("put-object"); po.add_argument("--body", required=True)
    go = sub.add_parser("get-object"); go.add_argument("--to", required=True)
    cp = sub.add_parser("compare")
    cp.add_argument("--file1", required=True); cp.add_argument("--file2", required=True)
    ag = sub.add_parser("anonymous-get"); ag.add_argument("--to", required=True)
    pt = sub.add_parser("presign-test")
    pt.add_argument("--expires", type=int, default=60)
    pt.add_argument("--wait", type=int, default=65)
    sub.add_parser("list-objects")
    sub.add_parser("delete-object")
    sub.add_parser("delete-bucket")
    sub.add_parser("head-bucket")
    args = p.parse_args()
    dispatch = {
        "create-bucket": cmd_create_bucket,
        "put-public-block": cmd_put_public_block,
        "get-public-block": cmd_get_public_block,
        "put-object": lambda: cmd_put_object(args.body),
        "get-object": lambda: cmd_get_object(args.to),
        "compare": lambda: cmd_compare(args.file1, args.file2),
        "anonymous-get": lambda: cmd_anonymous_get(args.to),
        "presign-test": lambda: cmd_presign_test(args.expires, args.wait),
        "list-objects": cmd_list_objects,
        "delete-object": cmd_delete_object,
        "delete-bucket": cmd_delete_bucket,
        "head-bucket": cmd_head_bucket,
    }
    dispatch[args.cmd]()


if __name__ == "__main__":
    sys.exit(main())