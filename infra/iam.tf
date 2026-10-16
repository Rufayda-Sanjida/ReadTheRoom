# Permissions. Each role gets only what it needs.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: used by ECS itself to start containers (pull images, write logs, read secrets).
resource "aws_iam_role" "execution" {
  name               = "${var.project}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "read-secrets"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = [aws_secretsmanager_secret.app.arn, aws_db_instance.main.master_user_secret[0].secret_arn]
    }]
  })
}

# Backend task role: what the backend's own code may do (read/write videos in S3).
resource "aws_iam_role" "backend" {
  name               = "${var.project}-backend"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "backend_videos" {
  name = "videos-bucket"
  role = aws_iam_role.backend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject"]
      Resource = "${aws_s3_bucket.videos.arn}/videos/*"
    }]
  })
}

# --- API keys --------------------------------------------------------------------------------
# Created with empty values. Fill them in once from your terminal (see infra/README.md), so the
# keys never live in this repo or in Terraform state.

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.project}/app-keys"
  recovery_window_in_days = 0 # delete immediately on destroy, so re-creating with the same name works
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    GEMINI_API_KEY       = ""
    ANTHROPIC_API_KEY    = ""
    SMARTSPECTRA_API_KEY = ""
  })

  lifecycle {
    ignore_changes = [secret_string] # don't overwrite the real keys on the next apply
  }
}
