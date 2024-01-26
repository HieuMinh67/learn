locals {
  name          = "DemoPipeline"
  instance_name = "DeployInstance"
}

resource "aws_s3_bucket" "repo_as_bucket" {
  bucket_prefix = "code-pipeline-s3-repo-"
}

# Compulsory in order to keep multiple version of repo
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.repo_as_bucket.bucket
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "this" {
  bucket = aws_s3_bucket.repo_as_bucket.bucket
  key    = "SampleApp_Linux.zip"
  source = "./SampleApp_Linux.zip"
}

data "aws_iam_policy" "ec2_for_code_deploy" {
  name = "AmazonEC2RoleforAWSCodeDeploy"
}

resource "aws_iam_role" "ec2_code_deploy" {
  name = "EC2CodeDeployRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_code_deploy" {
  policy_arn = data.aws_iam_policy.ec2_for_code_deploy.arn
  role       = aws_iam_role.ec2_code_deploy.name
}

data "aws_ami" "amazon_linux" {
  owners      = ["amazon"]
  most_recent = true
}

resource "aws_instance" "deploy_instance" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"

  user_data = <<-EOF
    #!/bin/bash

    yum update -y
    yum install -y ruby aws-cli

    cd /home/ec2-user
    wget https://aws-codedeploy-us-east-2.s3.us-east-2.amazonaws.com/latest/install
    chmod +x ./install
    ./install auto
  EOF

  tags = {
    Name = local.instance_name
  }
}

data "aws_iam_policy" "code_deploy" {
  name = "AWSCodeDeployRole"
}

resource "aws_iam_role" "code_deploy_for_pipeline" {
  name = "CodeDeployRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "codedeploy.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "CodeDeploy" {
  policy_arn = data.aws_iam_policy.code_deploy.arn
  role       = aws_iam_role.code_deploy_for_pipeline.name
}

resource "aws_codedeploy_app" "this" {
  name = local.name
}

resource "aws_codedeploy_deployment_group" "this" {
  app_name              = aws_codedeploy_app.this.name
  deployment_group_name = local.name
  service_role_arn      = aws_iam_role.code_deploy_for_pipeline.arn

  ec2_tag_set {
    ec2_tag_filter {
      key   = "Name"
      type  = "KEY_AND_VALUE"
      value = local.instance_name
    }
  }
}

resource "aws_s3_bucket" "artifact_store" {
  bucket_prefix = "codepipeline-artifact-store-"
}

resource "aws_s3_bucket_versioning" "artifact_store" {
  bucket = aws_s3_bucket.artifact_store.bucket
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_codepipeline" "this" {
  name     = local.name
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifact_store.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      category         = "Source"
      name             = "Source"
      owner            = "AWS"
      provider         = "S3"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        S3Bucket    = aws_s3_bucket.repo_as_bucket.bucket
        S3ObjectKey = aws_s3_object.this.key
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      category        = "Deploy"
      name            = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeploy"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ApplicationName     = aws_codedeploy_app.this.name
        DeploymentGroupName = aws_codedeploy_deployment_group.this.deployment_group_name
      }
    }
  }
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      identifiers = ["codepipeline.amazonaws.com"]
      type        = "Service"
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codepipeline" {
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "pipeline_bucket" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObjectAcl",
      "s3:PutObject",
    ]

    resources = [
      aws_s3_bucket.repo_as_bucket.arn,
      "${aws_s3_bucket.repo_as_bucket.arn}/*"
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "codedeploy:CreateDeployment"
    ]

    resources = [
      aws_codedeploy_deployment_group.this.arn
    ]
  }
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name   = "codepipeline_policy"
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.pipeline_bucket.json
}