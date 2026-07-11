# =============================================================================
# Module: Monitoring — CloudWatch, Prometheus remote write
# SOC 2 CC7.1/CC7.2 — Continuous monitoring and alerting
# =============================================================================

# ---------------------------------------------------------------------------
# CloudWatch Log Groups — Application & Infrastructure
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "application" {
  for_each = toset(var.log_group_names)

  name              = "/jol/${var.environment}/${each.value}"
  retention_in_days = var.log_retention_days

  kms_key_id = var.kms_key_arn

  tags = merge(var.tags, {
    Name = "${var.project}-${each.value}-${var.environment}"
  })
}

# ---------------------------------------------------------------------------
# CloudWatch Alarms — Critical infrastructure metrics
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "node_cpu_high" {
  alarm_name          = "${var.project}-${var.environment}-node-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EKS"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Node CPU utilization exceeds 85% for 15 minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "node_memory_high" {
  alarm_name          = "${var.project}-${var.environment}-node-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "MemoryUtilization"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 90
  alarm_description   = "Node memory utilization exceeds 90% for 15 minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# SNS Topic — Alert notifications
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name              = "${var.project}-${var.environment}-alerts"
  kms_master_key_id = var.kms_key_arn

  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = length(var.alert_email_addresses)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email_addresses[count.index]
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-${var.environment}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/EKS", "CPUUtilization", "ClusterName", var.cluster_name],
            ["AWS/EKS", "MemoryUtilization", "ClusterName", var.cluster_name]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
          title  = "EKS Cluster — CPU & Memory"
        }
      }
    ]
  })
}
