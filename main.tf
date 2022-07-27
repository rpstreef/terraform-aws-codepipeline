locals {
  resource_name = "${var.environment}-${var.git_repo}"

  tags = {
    Environment = var.environment
    Name        = var.resource_tag_name
  }
}

# -----------------------------------------------------------------------------
# Resources: Random string
# -----------------------------------------------------------------------------
resource "random_string" "postfix" {
  count = var.codepipeline_module_enabled ? 1 : 0

  length  = 6
  numeric = false
  upper   = false
  special = false
  lower   = true
}

# -----------------------------------------------------------------------------
# Resources: CodePipeline
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "artifact_store" {
  count = var.codepipeline_module_enabled ? 1 : 0

  bucket        = "${local.resource_name}-codepipeline-artifacts-${try(one(random_string.postfix.*.result))}"
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "_" {
  count = var.codepipeline_module_enabled ? 1 : 0

  bucket = try(one(aws_s3_bucket.artifact_store.*.id), "")

  rule {
    id     = "lifecycle_rule_codepipeline_expiration"
    status = "Enabled"
    expiration {
      days = 5
    }
  }
}

resource "aws_s3_bucket_acl" "_" {
  count = var.codepipeline_module_enabled ? 1 : 0

  bucket = try(one(aws_s3_bucket.artifact_store.*.id), "")

  acl = "private"
}

module "iam_codepipeline" {
  source = "github.com/rpstreef/tf-iam?ref=v1.2"

  environment       = var.environment
  region            = var.region
  resource_tag_name = var.resource_tag_name

  iam_module_enabled = var.codepipeline_module_enabled

  assume_role_policy = file("${path.module}/policies/codepipeline-assume-role.json")
  template           = file("${path.module}/policies/codepipeline-policy.json")
  role_name          = "codepipeline-${var.git_repo}-role"
  policy_name        = "codepipeline-${var.git_repo}-policy"

  role_vars = {
    codebuild_project_arn = try(one(aws_codebuild_project._.*.arn), "")
    s3_bucket_arn         = try(one(aws_s3_bucket.artifact_store.*.arn), "")
    codestar_arn          = try(one(aws_codestarconnections_connection._.*.arn), "")
  }
}

module "iam_cloudformation" {
  source = "github.com/rpstreef/tf-iam?ref=v1.2"

  environment       = var.environment
  region            = var.region
  resource_tag_name = var.resource_tag_name

  iam_module_enabled = var.codepipeline_module_enabled

  assume_role_policy = file("${path.module}/policies/cloudformation-assume-role.json")
  template           = file("${path.module}/policies/cloudformation-policy.json")
  role_name          = "cloudformation-${var.git_repo}-role"
  policy_name        = "cloudformation-${var.git_repo}-policy"

  role_vars = {
    s3_bucket_arn         = try(one(aws_s3_bucket.artifact_store.*.arn), "")
    codepipeline_role_arn = try(module.iam_codepipeline.role_arn, "")
  }
}

# The aws_codestarconnections_connection resource is created in the state PENDING. 
# Authentication with the connection provider must be completed in the AWS Console.
resource "aws_codestarconnections_connection" "_" {
  count = var.codepipeline_module_enabled ? 1 : 0

  name          = "${local.resource_name}-cs"
  provider_type = var.git_provider_type
}

resource "aws_codepipeline" "_" {
  count = var.codepipeline_module_enabled ? 1 : 0

  name     = "${local.resource_name}-codepipeline"
  role_arn = try(module.iam_codepipeline.role_arn, "")

  artifact_store {
    location = one(aws_s3_bucket.artifact_store.*.bucket)
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source"]

      configuration = {
        ConnectionArn    = one(aws_codestarconnections_connection._.*.arn)
        FullRepositoryId = "${var.git_owner}/${var.git_repo}"
        BranchName       = var.git_branch
      }
    }
  }

  stage {
    name = "BuildDeploy"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source"]
      output_artifacts = ["build"]

      configuration = {
        ProjectName = one(aws_codebuild_project._.*.name)
      }
    }
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [stage[0].action[0].configuration]
  }
}

# -----------------------------------------------------------------------------
# Resources: CodeBuild
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "policy_codebuild" {
  count = var.codepipeline_module_enabled ? 1 : 0

  statement {
    effect = "Allow"
    resources = [
      "*"
    ]
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "iam:PassRole"
    ]
  }
  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:GetObject",
      "s3:GetObjectAcl",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:DeleteObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning"
    ]
    resources = compact([
      "${try(one(aws_s3_bucket.artifact_store.*.arn), "")}",
      "${try(one(aws_s3_bucket.artifact_store.*.arn), "")}/*",
      "${try(var.s3_deploy_bucket_arn, "")}",
      "${try(var.s3_deploy_bucket_arn, "")}"
    ])
  }
}

data "aws_iam_policy_document" "assume_role_codebuild" {
  count = var.codepipeline_module_enabled ? 1 : 0
  statement {
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codebuild" {
  count = var.codepipeline_module_enabled ? 1 : 0

  name = "${local.resource_name}"

  assume_role_policy = one(data.aws_iam_policy_document.assume_role_codebuild.*.json)

  tags = local.tags
}

resource "aws_iam_policy" "_" {
  count = var.codepipeline_module_enabled ? 1 : 0

  name = "${local.resource_name}"

  policy = one(data.aws_iam_policy_document.policy_codebuild.*.json)

  tags = local.tags
}

resource "aws_iam_policy_attachment" "_" {
  count = var.codepipeline_module_enabled ? 1 : 0

  name = "${local.resource_name}-policy-attachement"

  policy_arn = one(aws_iam_policy._.*.arn)
  roles      = [one(aws_iam_role.codebuild.*.name)]
}

resource "aws_codebuild_project" "_" {
  count = var.codepipeline_module_enabled ? 1 : 0

  name          = "${local.resource_name}-codebuild"
  description   = "${local.resource_name}_codebuild_project"
  build_timeout = var.build_timeout
  badge_enabled = var.badge_enabled
  service_role  = one(aws_iam_role.codebuild.*.arn)

  artifacts {
    type           = "CODEPIPELINE"
    namespace_type = "BUILD_ID"
    packaging      = "ZIP"
  }

  environment {
    compute_type    = var.build_compute_type
    image           = var.build_image
    type            = "LINUX_CONTAINER"
    privileged_mode = var.privileged_mode

    environment_variable {
      name  = "ARTIFACT_BUCKET"
      value = one(aws_s3_bucket.artifact_store.*.bucket)
    }

    dynamic "environment_variable" {
      for_each = var.environment_variable_map

      content {
        name  = environment_variable.value.name
        value = environment_variable.value.value
        type  = environment_variable.value.type
      }
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = var.buildspec
  }

  tags = local.tags
}
