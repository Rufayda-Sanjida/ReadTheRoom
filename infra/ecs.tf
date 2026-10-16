# ECS Fargate: runs the two containers without managing any servers.
#
#   frontend (public, behind the load balancer)  --http://backend.readtheroom.internal:8000-->  backend
#
# GitHub Actions pushes new images tagged :latest and tells ECS to redeploy. Terraform owns
# everything else about the services (sizes, env vars, secrets).

resource "aws_ecs_cluster" "main" {
  name = var.project

  setting {
    name  = "containerInsights"
    value = "disabled" # detailed per-container metrics cost extra; the basic CPU/memory ones are free
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

locals {
  capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
  backend_host      = "backend.${aws_service_discovery_private_dns_namespace.main.name}"
}

# Private DNS so the frontend can find the backend by name, wherever its container lands.
resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "${var.project}.internal"
  vpc  = aws_vpc.main.id
}

resource "aws_service_discovery_service" "backend" {
  name = "backend"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

resource "aws_cloudwatch_log_group" "app" {
  for_each          = toset(["backend", "frontend"])
  name              = "/ecs/${var.project}/${each.key}"
  retention_in_days = 14
}

# --- Backend ---------------------------------------------------------------------------------

resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.project}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256 # 0.25 vCPU
  memory                   = 512 # MB
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.backend.arn

  container_definitions = jsonencode([{
    name         = "backend"
    image        = "${aws_ecr_repository.app["backend"].repository_url}:latest"
    essential    = true
    portMappings = [{ containerPort = 8000 }]

    environment = [
      { name = "VIDEOS_BUCKET", value = aws_s3_bucket.videos.bucket },
      { name = "AWS_REGION", value = var.region },
      # Standard Postgres variables; the backend switches from SQLite to Postgres when it sees them.
      { name = "PGHOST", value = aws_db_instance.main.address },
      { name = "PGPORT", value = tostring(aws_db_instance.main.port) },
      { name = "PGDATABASE", value = aws_db_instance.main.db_name },
      { name = "PGUSER", value = aws_db_instance.main.username },
      { name = "PGSSLMODE", value = "require" },
    ]
    secrets = [
      { name = "PGPASSWORD", valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::" },
      { name = "GEMINI_API_KEY", valueFrom = "${aws_secretsmanager_secret.app.arn}:GEMINI_API_KEY::" },
      { name = "ANTHROPIC_API_KEY", valueFrom = "${aws_secretsmanager_secret.app.arn}:ANTHROPIC_API_KEY::" },
    ]

    healthCheck = {
      command     = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app["backend"].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "backend"
      }
    }
  }])
}

resource "aws_ecs_service" "backend" {
  name            = "${var.project}-backend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = local.capacity_provider
    weight            = 1
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.backend.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.backend.arn
  }

  # Stop retrying a deploy whose containers keep crashing, and go back to the last good one.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_ecs_cluster_capacity_providers.main]
}

# --- Frontend --------------------------------------------------------------------------------

resource "aws_ecs_task_definition" "frontend" {
  family                   = "${var.project}-frontend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 1024 # Node server-side rendering plus the SmartSpectra native SDK
  execution_role_arn       = aws_iam_role.execution.arn

  container_definitions = jsonencode([{
    name         = "frontend"
    image        = "${aws_ecr_repository.app["frontend"].repository_url}:latest"
    essential    = true
    portMappings = [{ containerPort = 3000 }]

    environment = [
      { name = "API_URL", value = "http://${local.backend_host}:8000" },
    ]
    secrets = [
      { name = "SMARTSPECTRA_API_KEY", valueFrom = "${aws_secretsmanager_secret.app.arn}:SMARTSPECTRA_API_KEY::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app["frontend"].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "frontend"
      }
    }
  }])
}

resource "aws_ecs_service" "frontend" {
  name                              = "${var.project}-frontend"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.frontend.arn
  desired_count                     = 1
  health_check_grace_period_seconds = 60

  capacity_provider_strategy {
    capacity_provider = local.capacity_provider
    weight            = 1
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.frontend.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "frontend"
    container_port   = 3000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http, aws_ecs_cluster_capacity_providers.main]
}

# --- Load balancer: the app's public address ------------------------------------------------

resource "aws_lb" "main" {
  name               = var.project
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  idle_timeout       = 120 # chat answers from the LLM and video uploads can take a while
}

resource "aws_lb_target_group" "frontend" {
  name                 = "${var.project}-frontend"
  port                 = 3000
  protocol             = "HTTP"
  target_type          = "ip" # Fargate containers are addressed by IP
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 15

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}
