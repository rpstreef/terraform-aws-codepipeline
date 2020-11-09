locals {
  resource_name = "${var.namespace}-${var.github_repo}"
}

# -----------------------------------------------------------------------------
# Resources: Random string
# -----------------------------------------------------------------------------
resource "random_string" "postfix" {
  length  = 6
  number  = false
  upper   = false
  special = false
  lower   = true
}

# -----------------------------------------------------------------------------
# Resources: CodePipeline
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "artifact_store" {
  bucket        = "${local.resource_name}-codepipeline-artifacts-${random_string.postfix.result}"
  acl           = "private"
  force_destroy = true

  lifecycle_rule {
    enabled = true

    expiration {
      days = 5
    }
  }
}

module "iam_codepipeline" {
  source = "github.com/rpstreef/tf-iam?ref=v1.1"

  namespace         = var.namespace
  region            = var.region
  resource_tag_name = var.resource_tag_name

  assume_role_policy = file("${path.module}/policies/codepipeline-assume-role.json")
  template           = file("${path.module}/policies/codepipeline-policy.json")
  role_name          = "codepipeline-${var.github_repo}-role"
  policy_name        = "codepipeline-${var.github_repo}-policy"

  role_vars = {
    codebuild_project_arn = aws_codebuild_project._.arn
    s3_bucket_arn         = aws_s3_bucket.artifact_store.arn
  }
}

module "iam_cloudformation" {
  source = "github.com/rpstreef/tf-iam?ref=v1.1"

  namespace         = var.namespace
  region            = var.region
  resource_tag_name = var.resource_tag_name

  assume_role_policy = file("${path.module}/policies/cloudformation-assume-role.json")
  template           = file("${path.module}/policies/cloudformation-policy.json")
  role_name          = "cloudformation-${var.github_repo}-role"
  policy_name        = "cloudformation-${var.github_repo}-policy"

  role_vars = {
    s3_bucket_arn         = aws_s3_bucket.artifact_store.arn
    codepipeline_role_arn = module.iam_codepipeline.role_arn
  }
}

resource "aws_codepipeline" "_" {
  name     = "${local.resource_name}-codepipeline"
  role_arn = module.iam_codepipeline.role_arn

  artifact_store {
    location = aws_s3_bucket.artifact_store.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source"]

      configuration = {
        OAuthToken           = var.github_token
        Owner                = var.github_owner
        Repo                 = var.github_repo
        Branch               = var.github_branch
        PollForSourceChanges = var.poll_source_changes
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
        ProjectName = aws_codebuild_project._.name
      }
    }
  }

  tags = {
    Environment = var.namespace
    Name        = var.resource_tag_name
  }

  lifecycle {
    ignore_changes = [stage[0].action[0].configuration]
  }
}

# -----------------------------------------------------------------------------
# Resources: CodeBuild
# -----------------------------------------------------------------------------
module "iam_codebuild" {
  source = "github.com/rpstreef/tf-iam?ref=v1.1"

  namespace         = var.namespace
  region            = var.region
  resource_tag_name = var.resource_tag_name

  assume_role_policy = file("${path.module}/policies/codebuild-assume-role.json")
  template           = file("${path.module}/policies/codebuild-policy.json")
  role_name          = "codebuild-${var.github_repo}-role"
  policy_name        = "codebuild-${var.github_repo}-policy"

  role_vars = {
    s3_bucket_arn = aws_s3_bucket.artifact_store.arn
  }
}

resource "aws_codebuild_project" "_" {
  name          = "${local.resource_name}-codebuild"
  description   = "${local.resource_name}_codebuild_project"
  build_timeout = var.build_timeout
  badge_enabled = var.badge_enabled
  service_role  = module.iam_codebuild.role_arn

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
      value = aws_s3_bucket.artifact_store.bucket
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = var.buildspec
  }

  tags = {
    Environment = var.namespace
    Name        = var.resource_tag_name
  }
}
