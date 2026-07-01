output "dns_name" {
  description = "DNS hostname of the receiver NLB"
  value       = module.receiver.dns_name
}

output "security_group_id" {
  description = "Security group ID of the receiver NLB"
  value       = module.receiver.security_group_id
}
