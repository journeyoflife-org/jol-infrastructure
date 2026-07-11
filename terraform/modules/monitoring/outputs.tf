# =============================================================================
# Module: Monitoring — Outputs
# =============================================================================

output "sns_topic_arn" {
  description = "SNS topic ARN for alerts"
  value       = aws_sns_topic.alerts.arn
}

output "log_group_names" {
  description = "CloudWatch log group names"
  value       = { for k, v in aws_cloudwatch_log_group.application : k => v.name }
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}
