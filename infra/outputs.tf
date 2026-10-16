output "app_url" {
  description = "Open this in a browser."
  value       = "http://${aws_lb.main.dns_name}"
}

output "github_deploy_role_arn" {
  description = "Paste into GitHub: repo Settings -> Secrets and variables -> Actions -> Variables -> AWS_ROLE_ARN."
  value       = aws_iam_role.github_deploy.arn
}

output "app_keys_secret" {
  description = "Secrets Manager secret holding the Gemini/Anthropic/SmartSpectra keys."
  value       = aws_secretsmanager_secret.app.name
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}
