# lambdas/processor/processor.py
import json
import boto3
import gzip
import io
import os
from datetime import datetime
import uuid

s3 = boto3.client("s3")
sqs = boto3.client("sqs")

BUCKET = os.environ.get("BUCKET")
DLQ_URL = os.environ.get("DLQ_URL")

def validate_record(rec):
    # expected fields: device_id, timestamp, metrics:{temp,co2,humidity}, location
    if not isinstance(rec, dict):
        return False
    if "device_id" not in rec or "metrics" not in rec:
        return False
    return True

def lambda_handler(event, context):
    # Event is S3 Put - iterate records
    for r in event.get("Records", []):
        s3_info = r.get("s3", {})
        key = s3_info.get("object", {}).get("key")
        if not key:
            continue
        try:
            obj = s3.get_object(Bucket=BUCKET, Key=key)
            payload = obj["Body"].read().decode("utf-8")
            # assume newlines or single JSON
            docs = []
            try:
                data = json.loads(payload)
                if isinstance(data, list):
                    docs = data
                else:
                    docs = [data]
            except Exception:
                # maybe newline-delimited JSON
                docs = [json.loads(line) for line in payload.splitlines() if line.strip()]
        except Exception as e:
            print("Error reading s3 object:", e)
            continue

        processed = []
        for rec in docs:
            if not validate_record(rec):
                # push to DLQ with error context
                try:
                    msg = {"error": "validation_failed", "object_key": key, "record": rec}
                    sqs.send_message(QueueUrl=DLQ_URL, MessageBody=json.dumps(msg))
                except Exception as e:
                    print("Failed send DLQ:", e)
                continue

            rec["received_at"] = datetime.utcnow().isoformat()
            # enrichment: normalized metrics
            metrics = rec.get("metrics", {})
            rec["metrics"]["temp_c"] = float(metrics.get("temp", 0))
            rec["id"] = rec.get("device_id") + "-" + str(uuid.uuid4())[:8]
            processed.append(rec)

        if processed:
            date = datetime.utcnow().strftime("%Y/%m/%d")
            dest_key = f"processed/{date}/batch-{uuid.uuid4().hex}.json.gz"
            buf = io.BytesIO()
            with gzip.GzipFile(fileobj=buf, mode="w") as gz:
                for item in processed:
                    gz.write((json.dumps(item) + "\n").encode("utf-8"))
            buf.seek(0)
            s3.put_object(Bucket=BUCKET, Key=dest_key, Body=buf.getvalue())
            print("Wrote", dest_key)
