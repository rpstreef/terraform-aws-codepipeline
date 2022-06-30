# Terraform AWS CodePipeline

## About:

Deploys an AWS CodePipeline with a basic 2 stage deployment configuration. ``Source`` and ``BuildAndDeploy``.

This can be used for instance to deploy a static website to an S3 bucket or in cases where you do not need to use CloudFormation or CodeDeploy to make changes to infrastructure.

## How to use:

This version of the module expects GitHub as source code repository to be used. You'll need an OAuthToken (``github_token``)  that has access to the repo (``github_repo``) you want to read from.

```hcl
locals {
  s3_deployment_bucket_arn = "arn:aws:s3:::${var.domain_name}"
}

data "template_file" "buildspec" {
  template = file("${path.module}/codebuild/buildspec.yml")
}

module "codepipeline" {
  source = "github.com/rpstreef/terraform-aws-codepipeline?ref=v1.0"

  resource_tag_name = var.resource_tag_name
  namespace         = var.namespace
  region            = var.region

  github_token        = var.github_token
  github_owner        = var.github_owner
  github_repo         = var.github_repo
  poll_source_changes = var.poll_source_changes

  build_image = "aws/codebuild/standard:4.0"
  buildspec   = data.template_file.buildspec.rendered

  s3_deploy_bucket_arn = local.s3_deployment_bucket_arn

  environment_variable_map = [
    {
      name  = "DOMAIN"
      value = var.domain_name
      type  = "PLAINTEXT"
    },
    {
      name  = "CACHE"
      value = var.domain_cache_settings
      type  = "PLAINTEXT"
    }
  ]
}
```

## Changelog
### v1.2
 - Added `codepipeline_module_enabled`, to enable or disable creation of all resources in this module
 - Changed outputs to output all properties in; `codepipeline` and `codebuild` resources.
 - Updated deprecated S3 resource configurations.

### v1.1
 - Added environment variables for Codebuild build, you can add additional variables as shown in the example.

### v1.0
 - Initial release