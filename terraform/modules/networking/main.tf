data "aws_vpc" "main" {
  id = var.vpc_id
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

data "aws_subnet" "public_details" {
  for_each = toset(data.aws_subnets.public.ids)
  id       = each.value
}

locals {
  all_public_subnet_ids = tolist(data.aws_subnets.public.ids)
  edge_public_subnet_ids = length(var.edge_public_subnet_azs) == 0 ? local.all_public_subnet_ids : sort([
    for _, subnet in data.aws_subnet.public_details : subnet.id
    if contains(var.edge_public_subnet_azs, subnet.availability_zone)
  ])
  private_networking_enabled              = var.create_private_networking
  private_networking_has_matching_lengths = length(var.private_subnet_cidrs) == length(var.azs)
  private_networking_has_subnets          = length(var.private_subnet_cidrs) > 0
}

check "private_networking_inputs" {
  assert {
    condition = !local.private_networking_enabled || (
      local.private_networking_has_matching_lengths && local.private_networking_has_subnets
    )
    error_message = "When create_private_networking=true, set non-empty private_subnet_cidrs and azs with equal lengths."
  }
}

resource "aws_ec2_tag" "public_subnet_elb" {
  for_each    = toset(local.all_public_subnet_ids)
  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

resource "aws_ec2_tag" "public_subnet_cluster" {
  for_each    = var.cluster_name != "" ? toset(local.all_public_subnet_ids) : toset([])
  resource_id = each.value
  key         = "kubernetes.io/cluster/${var.cluster_name}"
  value       = "shared"
}

resource "aws_eip" "nat" {
  count  = var.create_private_networking ? 1 : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  count         = var.create_private_networking ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = tolist(data.aws_subnets.public.ids)[0]
  tags          = merge(var.tags, { Name = "${var.name}-nat-gw" })
  depends_on    = [aws_eip.nat]
}

resource "aws_subnet" "private" {
  count             = var.create_private_networking ? length(var.private_subnet_cidrs) : 0
  vpc_id            = data.aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, {
    Name                              = "${var.name}-private-${var.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_route_table" "private" {
  count  = var.create_private_networking ? 1 : 0
  vpc_id = data.aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[0].id
  }

  tags = merge(var.tags, { Name = "${var.name}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = var.create_private_networking ? length(aws_subnet.private) : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}
