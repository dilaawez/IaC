locals {
  name_prefix = "${var.name}-${var.environment}"
}

data "aws_availability_zones" "available" {
  state = "available"
}

# pick the first N AZs
locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(
    {
      Name        = "${local.name_prefix}-vpc"
      Environment = var.environment
    },
    var.tags
  )
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags = merge({ Name = "${local.name_prefix}-igw" }, var.tags)
}

# Calculate subnet CIDRs: produce list of CIDRs for all subnets
# We'll create subnets in AZ-major order: AZ1 public(s), AZ1 private(s), AZ1 isolated(s),
# AZ2 public(s), AZ2 private(s), ...
# For each generated subnet we create an identifier key like az-0-public-0
locals {
  per_az_total_subnets = var.subnets_per_az.public + var.subnets_per_az.private + var.subnets_per_az.isolated

  # total number of subnets across all AZs
  total_subnets = local.per_az_total_subnets * length(local.azs)

  # We'll increment netnum from 0..(total_subnets-1)
  netnums = [for i in range(local.total_subnets) : i]

  # For each netnum compute cidr using cidrsubnet(vpc_cidr, newbits, netnum)
  # newbits = subnet_mask_bits (e.g., 8 for /24 from /16)
  subnet_cidrs = [for n in local.netnums : cidrsubnet(var.vpc_cidr, var.subnet_mask_bits, n)]
}

# Build a map of subnet meta objects { key => {cidr, az, type, index_in_az } }
locals {
  subnet_map = {
    for az_index, az in zip(range(length(local.azs)), local.azs) :
    # within each AZ, create subnets_per_az.public + private + isolated
    # We'll create keys like az0-public-0, az0-private-0, ...
    az => flatten([
      [
        for p in range(var.subnets_per_az.public) : {
          cidr = local.subnet_cidrs[ az_index * local.per_az_total_subnets + p ]
          az   = az
          type = "public"
          idx  = p
          key  = format("az%02d-public-%02d", az_index, p)
        }
      ],
      [
        for pr in range(var.subnets_per_az.private) : {
          cidr = local.subnet_cidrs[ az_index * local.per_az_total_subnets + var.subnets_per_az.public + pr ]
          az   = az
          type = "private"
          idx  = pr
          key  = format("az%02d-private-%02d", az_index, pr)
        }
      ],
      [
        for iso in range(var.subnets_per_az.isolated) : {
          cidr = local.subnet_cidrs[ az_index * local.per_az_total_subnets + var.subnets_per_az.public + var.subnets_per_az.private + iso ]
          az   = az
          type = "isolated"
          idx  = iso
          key  = format("az%02d-isolated-%02d", az_index, iso)
        }
      ]
    ])
  }
}

# Flatten map entries into one map keyed by the key field
locals {
  flattened_subnets = merge([for az, list in local.subnet_map : { for s in list : s.key => s } ]...)
}

# Create subnets
resource "aws_subnet" "this" {
  for_each = local.flattened_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  map_public_ip_on_launch = each.value.type == "public" ? true : false

  tags = merge(
    {
      Name        = "${local.name_prefix}-${each.value.key}"
      Environment = var.environment
      SubnetType  = each.value.type
    },
    var.tags
  )
}

# Create route tables and associations
resource "aws_route_table" "public" {
  count  = 1
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge({ Name = "${local.name_prefix}-rt-public" }, var.tags)
}

resource "aws_route_table_association" "public_assoc" {
  for_each = { for k, s in aws_subnet.this : k => s if s.tags["SubnetType"] == "public" }
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public[0].id
}

# NAT Gateways (one per AZ or single)
resource "aws_eip" "nat" {
  count = var.enable_nat_gateway && var.nat_gateway_per_az ? length(local.azs) : (var.enable_nat_gateway && !var.nat_gateway_per_az ? 1 : 0)
  vpc   = true
  tags = merge({ Name = "${local.name_prefix}-eip-${count.index}" }, var.tags)
}

resource "aws_nat_gateway" "nat" {
  count = length(aws_eip.nat)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = lookup({ for k, s in aws_subnet.this : k => s.id if s.tags["SubnetType"] == "public" && substr(k,0,4) == format("az%02d", count.index) }, 0, null)
  tags = merge({ Name = "${local.name_prefix}-nat-${count.index}" }, var.tags)
  depends_on = [aws_internet_gateway.igw]
}

# Private route tables routed to NATs
resource "aws_route_table" "private" {
  for_each = { for k, s in aws_subnet.this : k => s if s.tags["SubnetType"] == "private" }

  vpc_id = aws_vpc.this.id

  # find NAT index for this AZ
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = null
    nat_gateway_id = var.enable_nat_gateway ? (
      var.nat_gateway_per_az ?
        aws_nat_gateway.nat[tonumber(regex("\\d+", each.key)[0])].id :
        aws_nat_gateway.nat[0].id
    ) : null
  }

  tags = merge({ Name = "${local.name_prefix}-rt-${each.key}" }, var.tags)
}

resource "aws_route_table_association" "private_assoc" {
  for_each = { for k, rt in aws_route_table.private : k => rt }
  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = each.value.id
}

# optional VPC flow logs
resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "/aws/vpc/${aws_vpc.this.id}/flow-logs"
  retention_in_days = 30
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0
  log_destination      = "cloud-watch-logs"
  log_destination_arn  = aws_cloudwatch_log_group.flow_logs[0].arn
  traffic_type         = "ALL"
  iam_role_arn         = aws_iam_role.flowlogs.arn
  vpc_id               = aws_vpc.this.id
}

resource "aws_iam_role" "flowlogs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${local.name_prefix}-flowlogs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "flowlogs_attach" {
  count = var.enable_flow_logs ? 1 : 0
  role       = aws_iam_role.flowlogs[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# example security group
resource "aws_security_group" "default" {
  name        = "${local.name_prefix}-sg"
  description = "Shared security group"
  vpc_id      = aws_vpc.this.id
  tags = merge({ Name = "${local.name_prefix}-sg" }, var.tags)

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # example only; tighten in real use
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


// Notes on main.tf

// The module uses cidrsubnet(..., var.subnet_mask_bits, netnum) to generate sequential subnets. This ensures no hard-coded CIDRs; changing vpc_cidr, subnet_mask_bits, az_count, or subnets_per_az changes all subnets.

// NAT gateway placement: if nat_gateway_per_az is true we create one per AZ; else a single NAT is created and other private subnets route through it.

// You should tighten the sample SG ingress rule. This is a template. 

//