variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}
variable "vpc_id" {
  description = "VPC ID"
  type        = string
}
variable "subnet_ids" {
  description = "Subnet IDs for the NLB (3-AZ internal-elb tagged)"
  type        = list(string)
}

variable "instance_ids" {
  description = "EC2 instance IDs of EKS worker nodes to register as targets"
  type        = list(string)
}

variable "prometheus_port" {
  description = "Listener port for Prometheus receiver"
  type        = number
  default     = 9090
}

variable "loki_port" {
  description = "Listener port for Loki receiver"
  type        = number
  default     = 3100
}

variable "prometheus_target_port" {
  description = "Backend port for Prometheus targets"
  type        = number
  default     = 9090
}

variable "loki_target_port" {
  description = "Backend port for Loki targets"
  type        = number
  default     = 3100
}

variable "prometheus_health_path" {
  description = "Health check HTTP path for Prometheus targets"
  type        = string
  default     = "/-/healthy"
}

variable "loki_health_path" {
  description = "Health check HTTP path for Loki targets"
  type        = string
  default     = "/ready"
}

resource "aws_lb" "receiver" {
  name               = "${var.name_prefix}-alloyprom-receiver"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.subnet_ids
}

resource "aws_security_group" "receiver" {
  name   = "${var.name_prefix}-receiver-sg"
  vpc_id = var.vpc_id

  tags = { Name = "${var.name_prefix}-receiver-sg" }

  # Ingress rules are managed externally via aws_security_group_rule resources
  # (see terraform/envs/dev/services/receiver-nlb/main.tf for PROD cross-cluster rules).

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb_target_group" "prometheus" {
  name        = "${var.name_prefix}-prom-tg"
  port        = var.prometheus_target_port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    protocol = "HTTP"
    path     = var.prometheus_health_path
    port     = tostring(var.prometheus_target_port)
    matcher  = "200-399"
  }
}

resource "aws_lb_target_group" "loki" {
  name        = "${var.name_prefix}-loki-tg"
  port        = var.loki_target_port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    protocol = "HTTP"
    path     = var.loki_health_path
    port     = tostring(var.loki_target_port)
    matcher  = "200-399"
  }
}

resource "aws_lb_listener" "prometheus" {
  load_balancer_arn = aws_lb.receiver.arn
  port              = var.prometheus_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.prometheus.arn
  }
}

resource "aws_lb_listener" "loki" {
  load_balancer_arn = aws_lb.receiver.arn
  port              = var.loki_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.loki.arn
  }
}

resource "aws_lb_target_group_attachment" "prometheus" {
  count            = length(var.instance_ids)
  target_group_arn = aws_lb_target_group.prometheus.arn
  target_id        = var.instance_ids[count.index]
  port             = var.prometheus_target_port
}

resource "aws_lb_target_group_attachment" "loki" {
  count            = length(var.instance_ids)
  target_group_arn = aws_lb_target_group.loki.arn
  target_id        = var.instance_ids[count.index]
  port             = var.loki_target_port
}
