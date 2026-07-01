output "dns_name" {
  description = "DNS hostname of the receiver NLB"
  value       = aws_lb.receiver.dns_name
}

output "arn" {
  description = "ARN of the receiver NLB"
  value       = aws_lb.receiver.arn
}

output "security_group_id" {
  description = "Security group ID of the receiver NLB"
  value       = aws_security_group.receiver.id
}

output "prometheus_target_group_arn" {
  description = "ARN of the Prometheus target group"
  value       = aws_lb_target_group.prometheus.arn
}

output "loki_target_group_arn" {
  description = "ARN of the Loki target group"
  value       = aws_lb_target_group.loki.arn
}
