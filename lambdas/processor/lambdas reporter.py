# lambdas/reporter/reporter.py
import boto3
import os
import gzip
import io
import csv
import datetime
import json

s3 = boto3.client("s3")
sns = boto3.client("sns")

BUCKET = os.environ.get("BUCKET")
SNS_TOPIC = os.environ.get("SNS_TOPIC_ARN")

def list_objects_for_date(bucket, date_prefix):
    resp = s3.list_objects_v2(Bucket=bucket, Prefix=date_prefix)
    for obj in resp.get("Contents", []):
        yield obj["Key"]

def read_gz_jsonlines(bucket, key):
    obj = s3.get_object(Bucket=bucket, Key=key)
    data = obj["Body"].read()
    with gzip.GzipFile(fileobj=io.BytesIO(data)) as gz:
        for line in gz:
            if line.strip():
                yield json.loads(line)

def lambda_handler(event, context):
    # default to yesterday's UTC date
    target_date = datetime.datetime.utcnow() - datetime.timedelta(days=1)
    prefix = f"processed/{target_date.strftime('%Y/%m/%d')}/"
    rows = []
    device_stats = {}
    for key in list_objects_for_date(BUCKET, prefix):
        for rec in read_gz_jsonlines(BUCKET, key):
            dev = rec.get("device_id", "unknown")
            metrics = rec.get("metrics", {})
            temp = metrics.get("temp_c", None)
            device_stats.setdefault(dev, {"count":0, "temp_sum":0.0, "temp_max":-999})
            if temp is not None:
                device_stats[dev]["count"] += 1
                device_stats[dev]["temp_sum"] += float(temp)
                device_stats[dev]["temp_max"] = max(device_stats[dev]["temp_max"], float(temp))

    # produce CSV temp summary
    date_str = target_date.strftime("%Y-%m-%d")
    report_key = f"reports/{date_str}-device-summary.csv"
    csv_buffer = io.StringIO()
    writer = csv.writer(csv_buffer)
    writer.writerow(["device_id","count","avg_temp","max_temp"])
    for dev, stats in device_stats.items():
        avg = stats["temp_sum"]/stats["count"] if stats["count"]>0 else ""
        writer.writerow([dev, stats["count"], f"{avg:.2f}" if avg!="" else "", stats["temp_max"]])

    s3.put_object(Bucket=BUCKET, Key=report_key, Body=csv_buffer.getvalue().encode("utf-8"))
    msg = {"report_key": report_key, "bucket": BUCKET, "date": date_str}
    sns.publish(TopicArn=SNS_TOPIC, Message=json.dumps(msg), Subject=f"Daily IoT report {date_str}")
    return {"status": "ok", "report": report_key}

