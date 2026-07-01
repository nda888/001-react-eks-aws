output "state_bucket_name" {
  description = "S3 bucket name used in all envs/{env}/services/*/backend.tf"
  value       = aws_s3_bucket.tfstate.bucket
}

output "state_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.tfstate.arn
}

output "next_steps" {
  description = "Bootstrap lifecycle guide (deploy and delete)"
  value       = <<-EOT
     1. Bucket "${aws_s3_bucket.tfstate.bucket}" is ready (locking via S3 native lockfile).
     2. DEV deploy (shared infra + app):
        ./an-deploy dev ecr
        ./an-deploy dev networking
        ./an-deploy dev eks
        ./an-deploy dev eks-alb
        ./an-deploy dev secrets
     3. UAT deploy (app only, shares EKS/ALB with DEV):
        ./an-deploy uat ecr
        ./an-deploy uat secrets
     4. PROD deploy (separate EKS/ALB/SSM/IAM/MongoDB):
        ./an-deploy prod networking
        ./an-deploy prod ecr
        ./an-deploy prod eks
        ./an-deploy prod eks-alb
        ./an-deploy prod secrets
     5. Delete flow:
        ./an-deploy prod-destroy all
        ./an-deploy uat-destroy all
        ./an-deploy dev-destroy all
        ./an-deploy dev-destroy bootstrap
  EOT
}
