output "irsa_role_arn" {
  description = "IAM role ARN used by the ALB controller service account"
  value       = aws_iam_role.alb_controller.arn
}

output "helm_release_status" {
  description = "Helm release status"
  value       = helm_release.alb_controller.status
}
