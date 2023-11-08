resource "aws_sqs_queue" "main" {
  name        = "${var.name}${var.fifo_queue == true ? ".fifo" : ""}"
  name_prefix = var.name_prefix

  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  max_message_size           = var.max_message_size
  delay_seconds              = var.delay_seconds
  receive_wait_time_seconds  = var.receive_wait_time_seconds
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.deadletter_queue.arn
    maxReceiveCount     = 3
  })
  fifo_queue                        = var.fifo_queue
  fifo_throughput_limit             = var.fifo_throughput_limit
  content_based_deduplication       = var.content_based_deduplication
  deduplication_scope               = var.deduplication_scope
  kms_master_key_id                 = var.kms_master_key_id
  kms_data_key_reuse_period_seconds = var.kms_data_key_reuse_period_seconds

  tags = var.tags
}

resource "aws_sqs_queue" "deadletter_queue" {
  name                        = "${var.name}-dead-letter-queue${var.fifo_queue == true ? ".fifo" : ""}"
  message_retention_seconds   = var.message_retention_seconds
  visibility_timeout_seconds  = var.visibility_timeout_seconds
  fifo_queue                  = var.fifo_queue
  content_based_deduplication = var.content_based_deduplication
  max_message_size            = var.max_message_size
}

data "aws_iam_policy_document" "sh_sqs_policy" {
  statement {
    sid    = "Allow SNS Access"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage"
    ]
    resources = [aws_sqs_queue.main.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.orders.arn]
    }
  }
}

data "aws_iam_policy_document" "deadletter_queue" {
  statement {
    effect    = "Allow"
    resources = [aws_sqs_queue.deadletter_queue.arn]
    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ListQueueTags",
      "sqs:ReceiveMessage",
      "sqs:SendMessage",
    ]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

resource "aws_sqs_queue_policy" "sh_sqs_policy" {
  queue_url = aws_sqs_queue.main.id
  policy    = data.aws_iam_policy_document.sh_sqs_policy.json
}

resource "aws_sqs_queue_policy" "deadletter_queue" {
  queue_url = aws_sqs_queue.deadletter_queue.id
  policy    = data.aws_iam_policy_document.deadletter_queue.json
}

resource "aws_sns_topic" "orders" {
  name = "${var.name}${var.fifo_queue == true ? ".fifo" : ""}"
  //name_prefix = var.name
  fifo_topic = true
  tags       = var.tags
}

resource "aws_sns_topic_subscription" "orders_to_process_subscription" {
  protocol             = "sqs"
  raw_message_delivery = true
  topic_arn            = aws_sns_topic.orders.arn
  endpoint             = aws_sqs_queue.main.arn
}