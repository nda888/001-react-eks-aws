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
     2. Deploy flow:
        ./an-deploy dev ecr
        ./an-deploy dev networking
        ./an-deploy dev eks
        ./an-deploy dev eks-alb
        ./an-deploy dev secrets
     3. Delete bucket flow:
        ./an-deploy dev-destroy all
        ./an-deploy dev-destroy bootstrap
     4. Use "Delete this bucket now? (y/n)" only after all dev bootstrap cleanup is complete.
  EOT
}
