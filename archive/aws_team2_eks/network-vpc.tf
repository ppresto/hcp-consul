# https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"
  name    = "${var.prefix}-${var.region}-vpc-team2"
  cidr    = "10.16.0.0/16"
  #azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  azs                      = data.aws_availability_zones.available.names
  private_subnets          = ["10.16.1.0/24", "10.16.2.0/24", "10.16.3.0/24"]
  public_subnets           = ["10.16.11.0/24", "10.16.12.0/24", "10.16.13.0/24"]
  enable_nat_gateway       = true
  single_nat_gateway       = true
  enable_dns_hostnames     = true
  enable_ipv6              = false
  default_route_table_name = "${var.prefix}-team2-default-rt"
  tags = {
    Terraform  = "true"
    Owner      = "${var.prefix}"
    transit_gw = "true"
  }
  private_subnet_tags = {
    Tier = "Private"
  }
  public_subnet_tags = {
    Tier = "Public"
  }
  default_route_table_tags = {
    Name = "${var.prefix}-team2-default-rt"
  }
  private_route_table_tags = {
    Name = "${var.prefix}-team2-private-rt"
  }
  public_route_table_tags = {
    Name = "${var.prefix}-team2-public-rt"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "vpc3" {
  subnet_ids         = module.vpc.private_subnets
  transit_gateway_id = local.transit_gateway_id
  vpc_id             = module.vpc.vpc_id
  tags = {
    project = "${var.region}-team2-tgw"
  }
}

# vpc_main_route_table_id
resource "aws_route" "privateToHcp" {
  route_table_id         = module.vpc.private_route_table_ids[0]
  destination_cidr_block = local.hvn_cidr_block
  transit_gateway_id     = local.transit_gateway_id
}
resource "aws_route" "privateToAllInt" {
  for_each               = toset(local.private_cidr_blocks)
  route_table_id         = module.vpc.private_route_table_ids[0]
  destination_cidr_block = each.key
  transit_gateway_id     = local.transit_gateway_id
}