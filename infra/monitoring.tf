# CloudWatch: alarms that email you when something breaks, and a dashboard to look at.
# The first 10 alarms and 3 dashboards are free.

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alb_dimensions = { LoadBalancer = aws_lb.main.arn_suffix }
  tg_dimensions  = { LoadBalancer = aws_lb.main.arn_suffix, TargetGroup = aws_lb_target_group.frontend.arn_suffix }
  db_dimensions  = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  ecs_dimensions = {
    for name, svc in { backend = aws_ecs_service.backend, frontend = aws_ecs_service.frontend } :
    name => { ClusterName = aws_ecs_cluster.main.name, ServiceName = svc.name }
  }
}

resource "aws_cloudwatch_metric_alarm" "site_down" {
  alarm_name          = "${var.project}-site-down"
  alarm_description   = "No healthy frontend container behind the load balancer: the site is down."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = local.tg_dimensions
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "server_errors" {
  alarm_name          = "${var.project}-5xx-errors"
  alarm_description   = "The app returned more than 10 server errors (5xx) in 5 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = local.alb_dimensions
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Python errors in the backend log: turn each "Traceback" line into a metric, then alarm on it.
resource "aws_cloudwatch_log_metric_filter" "backend_exceptions" {
  name           = "${var.project}-backend-exceptions"
  log_group_name = aws_cloudwatch_log_group.app["backend"].name
  pattern        = "Traceback"

  metric_transformation {
    name      = "BackendExceptions"
    namespace = var.project
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "backend_exceptions" {
  alarm_name          = "${var.project}-backend-exceptions"
  alarm_description   = "The backend logged 5+ Python exceptions in 5 minutes. Check its log group."
  namespace           = var.project
  metric_name         = "BackendExceptions"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  for_each            = local.ecs_dimensions
  alarm_name          = "${var.project}-${each.key}-memory-high"
  alarm_description   = "The ${each.key} container has used >85% of its memory for 10 minutes; it may get killed."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = each.value
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name          = "${var.project}-db-cpu-high"
  alarm_description   = "Database CPU above 80% for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = local.db_dimensions
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "db_storage" {
  alarm_name          = "${var.project}-db-storage-low"
  alarm_description   = "Database has less than 2 GB of disk left."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = local.db_dimensions
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2 * 1024 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.project
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title = "Requests and errors", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix],
            [".", "HTTPCode_Target_4XX_Count", ".", "."],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "Response time (p50 / p95, seconds)", region = var.region, period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "p50" }],
            ["...", { stat = "p95" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title = "Container CPU / memory (%)", region = var.region, stat = "Average", period = 60
          metrics = flatten([
            for name, d in local.ecs_dimensions : [
              ["AWS/ECS", "CPUUtilization", "ClusterName", d.ClusterName, "ServiceName", d.ServiceName, { label = "${name} CPU" }],
              ["AWS/ECS", "MemoryUtilization", "ClusterName", d.ClusterName, "ServiceName", d.ServiceName, { label = "${name} memory" }],
            ]
          ])
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "Database", region = var.region, stat = "Average", period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.main.identifier, { label = "CPU %" }],
            [".", "DatabaseConnections", ".", ".", { label = "connections", yAxis = "right" }],
          ]
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "Recent backend errors"
          region = var.region
          query  = "SOURCE '${aws_cloudwatch_log_group.app["backend"].name}' | fields @timestamp, @message | filter @message like /(?i)(error|traceback|exception)/ | sort @timestamp desc | limit 50"
          view   = "table"
        }
      },
    ]
  })
}
