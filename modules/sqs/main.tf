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
  kms_master_key_id                 = aws_kms_key.default[0].arn
  kms_data_key_reuse_period_seconds = var.kms_data_key_reuse_period_seconds

  tags = var.tags
}

resource "aws_sqs_queue" "deadletter_queue" {
  name                              = "${var.name}-dead-letter-queue${var.fifo_queue == true ? ".fifo" : ""}"
  message_retention_seconds         = var.message_retention_seconds
  visibility_timeout_seconds        = var.visibility_timeout_seconds
  fifo_queue                        = var.fifo_queue
  content_based_deduplication       = var.content_based_deduplication
  kms_master_key_id                 = aws_kms_key.default[0].arn
  kms_data_key_reuse_period_seconds = var.kms_data_key_reuse_period_seconds
  max_message_size                  = var.max_message_size

  tags = var.tags
}

data "aws_iam_policy_document" "sqs" {
  statement {
    sid    = "Allow SNS Access"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
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
    sid       = "Allow SQS Deadletter Queue Access"
    effect    = "Allow"
    resources = [aws_sqs_queue.deadletter_queue.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.orders.arn]
    }
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

resource "aws_sqs_queue_policy" "sqs" {
  queue_url = aws_sqs_queue.main.id
  policy    = data.aws_iam_policy_document.sqs.json
}

resource "aws_sqs_queue_policy" "deadletter_queue" {
  queue_url = aws_sqs_queue.deadletter_queue.id
  policy    = data.aws_iam_policy_document.deadletter_queue.json
}

#SNS
resource "aws_sns_topic" "orders" {
  name = "${var.name}${var.fifo_queue == true ? ".fifo" : ""}"
  //name_prefix = var.name
  display_name                = var.name
  fifo_topic                  = true
  content_based_deduplication = var.content_based_deduplication
  kms_master_key_id           = aws_kms_key.default[0].arn
  tags                        = var.tags
}

resource "aws_sns_topic_subscription" "orders_to_process_subscription" {
  protocol               = "sqs"
  raw_message_delivery   = true
  topic_arn              = aws_sns_topic.orders.arn
  endpoint               = aws_sqs_queue.main.arn
  endpoint_auto_confirms = true
}

resource "aws_sns_topic_policy" "default" {
  arn    = aws_sns_topic.orders.arn
  policy = data.aws_iam_policy_document.policy.json
}

data "aws_iam_policy_document" "policy" {
  statement {
    sid    = "default-account-permissions"
    effect = "Allow"
    principals {
      identifiers = ["*"]
      type        = "AWS"
    }
    actions = [
      "SNS:GetTopicAttributes",
      "SNS:SetTopicAttributes",
      "SNS:AddPermission",
      "SNS:RemovePermission",
      "SNS:DeleteTopic",
      "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish"
    ]
    resources = [aws_sns_topic.orders.arn]
    # condition {
    #   test     = "ArnEquals"
    #   variable = "aws:SourceArn"
    #   values   = [aws_sns_topic.orders.arn]
    #   //test     = "StringEquals"
    #   //values   = [module.this.aws_account_id]
    #   //variable = "AWS:SourceOwner"
    # }
  }
}


#kms
data "aws_caller_identity" "current" {
}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_kms_key" "default" {
  count                    = 1
  deletion_window_in_days  = var.deletion_window_in_days
  enable_key_rotation      = var.enable_key_rotation
  policy                   = data.aws_iam_policy_document.combined_key_policy.json
  tags                     = var.tags
  description              = var.description
  key_usage                = var.key_usage
  customer_master_key_spec = var.customer_master_key_spec
  multi_region             = var.multi_region
}

resource "aws_kms_alias" "default" {
  count         = 1
  name          = "alias/${var.alias}"
  target_key_id = join("", aws_kms_key.default.*.id)
  depends_on    = [aws_kms_key.default]
}

data "aws_iam_policy_document" "iam_key_policy" {
  statement {
    sid = "Enable IAM User Permissions"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "combined_key_policy" {
  source_policy_documents = concat(
    [data.aws_iam_policy_document.iam_key_policy.json]
  )
}