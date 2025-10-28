// terraform/main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

provider "aws" {
  region = var.aws_region
}

resource "aws_s3_bucket" "iot_bucket" {
  bucket = var.bucket_name
  acl    = "private"

  versioning {
    enabled = true
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule {
    enabled = true
    prefix  = "processed/"
    transition {
      days          = 30
      storage_class = "GLACIER"
    }
  }
}

resource "aws_sns_topic" "report_topic" {
  name = "${var.bucket_name}-reports-topic"
}

resource "aws_sqs_queue" "dlq" {
  name                       = "${var.bucket_name}-dlq"
  message_retention_seconds  = 1209600
}

resource "aws_iam_role" "lambda_exec" {
  name = "${var.bucket_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.bucket_name}-lambda-policy"
  role = aws_iam_role.lambda_exec.id

  policy = data.aws_iam_policy_document.lambda_policy.json
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid = "S3Access"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]
    resources = [
      aws_s3_bucket.iot_bucket.arn,
      "${aws_s3_bucket.iot_bucket.arn}/*"
    ]
  }
  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
  statement {
    sid = "SNS"
    actions = ["sns:Publish"]
    resources = [aws_sns_topic.report_topic.arn]
  }
  statement {
    sid = "SQS"
    actions = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
  }
}

resource "aws_lambda_function" "processor" {
  filename         = "${path.module}/../lambdas/processor/processor.zip"
  function_name    = "${var.bucket_name}-processor"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "processor.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = filebase64sha256("${path.module}/../lambdas/processor/processor.zip")
  timeout          = 20
  memory_size      = 256
  environment {
    variables = {
      BUCKET = aws_s3_bucket.iot_bucket.id
      DLQ_URL = aws_sqs_queue.dlq.id
    }
  }
}

resource "aws_s3_bucket_notification" "s3notif" {
  bucket = aws_s3_bucket.iot_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "incoming/"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.iot_bucket.arn
}

resource "aws_lambda_function" "reporter" {
  filename         = "${path.module}/../lambdas/reporter/reporter.zip"
  function_name    = "${var.bucket_name}-reporter"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "reporter.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = filebase64sha256("${path.module}/../lambdas/reporter/reporter.zip")
  timeout          = 120
  memory_size      = 512
  environment {
    variables = {
      BUCKET = aws_s3_bucket.iot_bucket.id
      SNS_TOPIC_ARN = aws_sns_topic.report_topic.arn
    }
  }
}

resource "aws_cloudwatch_event_rule" "daily" {
  name                = "${var.bucket_name}-daily-report"
  schedule_expression = "cron(0 0 * * ? *)" // UTC midnight daily
}

resource "aws_cloudwatch_event_target" "daily_target" {
  rule      = aws_cloudwatch_event_rule.daily.name
  arn       = aws_lambda_function.reporter.arn
}

resource "aws_lambda_permission" "allow_events" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reporter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily.arn
}

output "bucket_name" {
  value = aws_s3_bucket.iot_bucket.bucket
}
output "sns_topic_arn" {
  value = aws_sns_topic.report_topic.arn
}

