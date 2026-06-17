output "ssm_prefix" {
  description = "SSM prefix for Mongo secret parameters"
  value       = var.ssm_prefix
}

output "mongo_rotation_role_arn" {
  description = "IRSA role ARN for Mongo app-user rotation CronJob"
  value       = aws_iam_role.mongo_rotation.arn
}

# TODO: Re-enable when kubernetes_service_account.mongo_credential_rotator is restored
# output "mongo_rotation_service_account_name" {
#   description = "Kubernetes ServiceAccount name used by the Mongo rotation CronJob"
#   value       = kubernetes_service_account.mongo_credential_rotator.metadata[0].name
# }

output "mongo_ssm_parameter_names" {
  description = "SSM parameter names consumed by External Secrets for Mongo credentials"
  value       = local.mongo_ssm_parameters
}
