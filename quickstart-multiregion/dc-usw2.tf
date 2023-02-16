provider "aws" {
  alias  = "usw2"
  region = "us-west-2"
}

data "aws_availability_zones" "usw2" {
  provider = aws.usw2
  state    = "available"
}

data "aws_caller_identity" "usw2" {
  provider = aws.usw2
}

locals {
  # US-WEST-2 DC Configuration
  usw2 = {
    "usw2-shared" = {
      "name" : "usw2-shared",
      "region" : "us-west-2",
      "vpc" = {
        "name" : "${var.prefix}-usw2-shared"
        "cidr" : "10.15.0.0/20",
        "private_subnets" : ["10.15.1.0/24", "10.15.2.0/24"],
        "public_subnets" : ["10.15.11.0/24", "10.15.12.0/24"],
        "routable_cidr_blocks" : ["10.15.1.0/24", "10.15.2.0/24"],
      }
      "tgw" = { #Only 1 TGW needed per region/data center.  Other VPC's can attach to it.
        "name" : "${var.prefix}-usw2-shared-tgw",
        "enable_auto_accept_shared_attachments" : true,
        "ram_allow_external_principals" : true,
      }
      "eks" = {
        "cluster_name" : "${var.prefix}-usw2-shared",
        "cluster_version" : var.eks_cluster_version,
        "ec2_ssh_key" : var.ec2_key_pair_name,
        "cluster_endpoint_private_access" : true,
        "cluster_endpoint_public_access" : true
      }
      "hcp-consul" = { #Only 1 HVN per region/dc.  
        "hvn_id"             = "${var.prefix}-hvn-usw2"
        "cloud_provider"     = var.cloud_provider
        "region"             = "us-west-2"
        "cidr_block"         = "172.25.16.0/23"
        "cluster_id"         = "${var.prefix}-cluster-usw2"
        "tier"               = "development"
        "min_consul_version" = var.min_consul_version
        "public_endpoint"    = true
        #"hvn_private_route_cidr_list" : ["10.0.0.0/10"] # Default uses [local.all_routable_cidr_blocks_usw2]
      }
    },
    "usw2-app1" = {
      "name" : "usw2-app1",
      "region" : "us-west-2",
      "vpc" = {
        "name" : "${var.prefix}-usw2-app1"
        "cidr" : "10.16.0.0/20",
        "private_subnets" : ["10.16.1.0/24", "10.16.2.0/24"],
        "public_subnets" : ["10.16.11.0/24", "10.16.12.0/24"],
        "routable_cidr_blocks" : ["10.16.0.0/20"]
      }
      "eks" = {
        "cluster_name" : "${var.prefix}-usw2-app1",
        "ec2_ssh_key" : var.ec2_key_pair_name
      }
      "ec2" = {
        "bastion" = {
          "ec2_ssh_key" : var.ec2_key_pair_name
          "target_subnets" : "public_subnets"
          "associate_public_ip_address" : true
        }
        "api" = {
          "ec2_ssh_key" : var.ec2_key_pair_name
          "target_subnets" : "private_subnets"
          "associate_public_ip_address" : false
        }
      }
    }
  }
  # Resource location lists used to build other data structures
  tgw_list_usw2 = flatten([for env, values in local.usw2 : ["${env}"] if contains(keys(values), "tgw")])
  hvn_list_usw2 = flatten([for env, values in local.usw2 : ["${env}"] if contains(keys(values), "hcp-consul")])
  vpc_list_usw2 = flatten([for env, values in local.usw2 : ["${env}"] if contains(keys(values), "vpc")])

  # Use HVN cidr block to create routes from VPC to HCP Consul.  Convert to map to support for_each
  hvn_cidrs_list_usw2 = [for env, values in local.usw2 : {
    "hvn" = {
      "cidr" = values.hcp-consul.cidr_block
      "env"  = env
    }
    } if contains(keys(values), "hcp-consul")
  ]
  hvn_cidrs_map_usw2 = { for item in local.hvn_cidrs_list_usw2 : keys(item)[0] => values(item)[0] }

  # create list of objects with routable_cidr_blocks for each vpc and tgw combo. Convert to map.
  vpc_tgw_cidr_usw2 = flatten([for env, values in local.usw2 :
    flatten([for tgw-key, tgw-val in local.tgw_list_usw2 :
      flatten([for cidr in values.vpc.routable_cidr_blocks : {
        "${env}-${tgw-val}-${cidr}" = {
          "tgw_env" = tgw-val
          "vpc_env" = env
          "cidr"    = cidr
        }
        }
      ])
    ])
  ])
  vpc_tgw_cidr_map_usw2 = { for item in local.vpc_tgw_cidr_usw2 : keys(item)[0] => values(item)[0] }

  # create list of routable_cidr_blocks for each internal VPC to add, convert to map
  vpc_routes_usw2 = flatten([for env, values in local.usw2 :
    flatten([for id, routes in local.vpc_tgw_cidr_map_usw2 : {
      "${env}-${routes.tgw_env}-${routes.cidr}" = {
        "tgw_env"    = routes.tgw_env
        "vpc_env"    = routes.vpc_env
        "target_vpc" = env
        "cidr"       = routes.cidr
      }
      } if routes.vpc_env != env
    ])
  ])
  vpc_routes_map_usw2 = { for item in local.vpc_routes_usw2 : keys(item)[0] => values(item)[0] }
  # create list of hvn and tgw to attach them.  Convert to map.
  hvn_tgw_attachments_usw2 = flatten([for hvn in local.hvn_list_usw2 :
    flatten([for tgw in local.tgw_list_usw2 : {
      "hvn-${hvn}-tgw-${tgw}" = {
        "tgw_env" = tgw
        "hvn_env" = hvn
      }
      }
    ])
  ])
  hvn_tgw_attachments_map_usw2 = { for item in local.hvn_tgw_attachments_usw2 : keys(item)[0] => values(item)[0] }

  # Create list of tgw and vpc for attachments.  Convert to map.
  tgw_vpc_attachments_usw2 = flatten([for vpc in local.vpc_list_usw2 :
    flatten([for tgw in local.tgw_list_usw2 :
      {
        "vpc-${vpc}-tgw-${tgw}" = {
          "tgw_env" = tgw
          "vpc_env" = vpc
        }
      }
    ])
  ])
  tgw_vpc_attachments_map_usw2 = { for item in local.tgw_vpc_attachments_usw2 : keys(item)[0] => values(item)[0] }

  # Concat all VPC/Env private_cidr_block lists into one distinct list of routes to add TGW.
  all_routable_cidr_blocks_usw2 = distinct(flatten([for env, values in local.usw2 :
    values.vpc.routable_cidr_blocks
  ]))

  # Create EC2 Resource map per Proj/Env
  ec2_location_usw2 = flatten([for env, values in local.usw2 : {
    "${env}" = values.ec2
    } if contains(keys(values), "ec2")
  ])
  ec2_location_map_usw2 = { for item in local.ec2_location_usw2 : keys(item)[0] => values(item)[0] }
  # Flatten map by EC2 instance and inject Proj/Env.  For_each loop can now build every instance
  ec2_usw2 = flatten([for env, values in local.ec2_location_map_usw2 :
    flatten([for ec2, attr in values : {
      "${env}-${ec2}" = {
        "ec2_ssh_key"                 = attr.ec2_ssh_key
        "target_subnets"              = attr.target_subnets
        "vpc_env"                     = env
        "hostname"                    = ec2
        "associate_public_ip_address" = attr.associate_public_ip_address
      }
    }])
  ])
  ec2_map_usw2 = { for item in local.ec2_usw2 : keys(item)[0] => values(item)[0] }

}

# Create HVN and HCP Consul Cluster
module "hcp_consul_usw2" {
  providers = {
    aws = aws.usw2
  }
  source             = "../modules/hcp_consul"
  for_each           = { for k, v in local.usw2 : k => v if contains(keys(v), "hcp-consul") }
  hvn_id             = try(local.usw2[each.key].hcp-consul.hvn_id, var.hvn_id)
  cloud_provider     = try(local.usw2[each.key].hcp-consul.cloud_provider, var.cloud_provider)
  region             = local.usw2[each.key].region
  cidr_block         = try(local.usw2[each.key].hcp-consul.cidr_block, var.hvn_cidr_block)
  cluster_id         = try(local.usw2[each.key].hcp-consul.cluster_id, var.cluster_id)
  tier               = try(local.usw2[each.key].hcp-consul.tier, "development")
  min_consul_version = try(local.usw2[each.key].hcp-consul.min_consul_version, var.min_consul_version)
  public_endpoint    = true
}

# Create usw2 VPCs defined in local.usw2
module "vpc-usw2" {
  # https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest
  providers = {
    aws = aws.usw2
  }
  source                   = "terraform-aws-modules/vpc/aws"
  version                  = "~> 3.0"
  for_each                 = local.usw2
  name                     = try(local.usw2[each.key].vpc.name, "${var.prefix}-${local.region_shortname}-vpc")
  cidr                     = local.usw2[each.key].vpc.cidr
  azs                      = data.aws_availability_zones.usw2.names
  private_subnets          = local.usw2[each.key].vpc.private_subnets
  public_subnets           = local.usw2[each.key].vpc.public_subnets
  enable_nat_gateway       = true
  single_nat_gateway       = true
  enable_dns_hostnames     = true
  enable_ipv6              = false
  default_route_table_name = "${var.prefix}-${each.key}-vpc1"
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
    Name = "${var.prefix}-vpc1-default"
  }
  private_route_table_tags = {
    Name = "${var.prefix}-vpc1-private"
  }
  public_route_table_tags = {
    Name = "${var.prefix}-vpc1-public"
  }
}

# Create 1+ Transit gateways to connect VPCs to the HVN
module "tgw-usw2" {
  # TransitGateway: https://registry.terraform.io/modules/terraform-aws-modules/transit-gateway/aws/latest
  providers = {
    aws = aws.usw2
  }
  source  = "terraform-aws-modules/transit-gateway/aws"
  version = "2.8.2"

  for_each                              = { for k, v in local.usw2 : k => v if contains(keys(v), "tgw") }
  description                           = "${local.region_shortname} - Centrally shared Transit Gateway"
  name                                  = try(local.usw2[each.key].tgw.name, "${var.prefix}-${local.region_shortname}-vpc1-tgw")
  enable_auto_accept_shared_attachments = try(local.usw2[each.key].tgw.enable_auto_accept_shared_attachments, true) # When "true" there is no need for RAM resources if using multiple AWS accounts
  ram_allow_external_principals         = try(local.usw2[each.key].tgw.ram_allow_external_principals, true)
  amazon_side_asn                       = 64532
  tgw_default_route_table_tags = {
    name = "${local.region_shortname}-tgw-default_rt"
  }
  tags = {
    project = "${local.region_shortname}-vpc1-tgw"
  }
}

# Attach 1+ Transit Gateways to each VPC and create routes for the private subnets
module "tgw_vpc_attach_usw2" {
  source = "../modules/aws_tgw_vpc_attach"
  providers = {
    aws = aws.usw2
  }
  #for_each = local.vpc_tgw_locations_map_usw2
  for_each           = local.tgw_vpc_attachments_map_usw2
  subnet_ids         = module.vpc-usw2[each.value.vpc_env].private_subnets
  transit_gateway_id = module.tgw-usw2[each.value.tgw_env].ec2_transit_gateway_id
  vpc_id             = module.vpc-usw2[each.value.vpc_env].vpc_id
  tags = {
    project = "${local.region_shortname}-vpc-usw2-tgw"
  }
}

# Attach HCP HVN to TGW and create routes from HVN to VPCs
module "aws_hcp_tgw_attach_usw2" {
  providers = {
    aws = aws.usw2
  }
  source                        = "../modules/aws_hcp_tgw_attach"
  for_each                      = local.hvn_tgw_attachments_map_usw2
  ram_resource_share_name       = "${local.usw2[each.value.tgw_env].tgw.name}-ram"
  hvn_provider_account_id       = module.hcp_consul_usw2[each.value.hvn_env].provider_account_id
  tgw_resource_association_arn  = module.tgw-usw2[each.value.tgw_env].ec2_transit_gateway_arn
  hvn_id                        = module.hcp_consul_usw2[each.value.hvn_env].hvn_id
  transit_gateway_attachment_id = "${local.usw2[each.value.tgw_env].tgw.name}-id"
  transit_gateway_id            = module.tgw-usw2[each.value.tgw_env].ec2_transit_gateway_id
  # Define TGW private_route_cidr_list for specific routes, or use default list of all VPC routable_cidr_blocks
  hvn_route_cidr_list = try(local.usw2[each.value.hvn_env].hcp-consul.hvn_private_route_cidr_list, local.all_routable_cidr_blocks_usw2)
  hvn_link            = module.hcp_consul_usw2[each.value.hvn_env].hvn_self_link
  hvn_route_id        = var.prefix
}

# Create additional private routes between VPCs so they can see each other.
module "route_add_usw2" {
  source = "../modules/aws_route_add"
  providers = {
    aws = aws.usw2
  }
  for_each               = local.vpc_routes_map_usw2
  route_table_id         = module.vpc-usw2[each.value.target_vpc].private_route_table_ids[0]
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = module.tgw-usw2[each.value.tgw_env].ec2_transit_gateway_id
}
# Create static HVN route with local.usw2.usw2-shared.hcp-consul.cidr_block
module "route_add_hcp_usw2" {
  source = "../modules/aws_route_add"
  providers = {
    aws = aws.usw2
  }
  for_each               = local.vpc_tgw_cidr_map_usw2
  route_table_id         = module.vpc-usw2[each.value.vpc_env].private_route_table_ids[0]
  destination_cidr_block = local.hvn_cidrs_map_usw2.hvn.cidr
  transit_gateway_id     = module.tgw-usw2[each.value.tgw_env].ec2_transit_gateway_id
}

# Create EKS cluster per VPC defined in local.usw2
module "eks-usw2" {
  # https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
  providers = {
    aws = aws.usw2
  }
  source  = "terraform-aws-modules/eks/aws"
  version = "19.5.1"

  for_each                              = { for k, v in local.usw2 : k => v if contains(keys(v), "eks") }
  cluster_name                          = try(local.usw2[each.key].eks.cluster_name, local.name)
  cluster_version                       = try(local.usw2[each.key].eks.eks_cluster_version, var.eks_cluster_version)
  cluster_endpoint_private_access       = try(local.usw2[each.key].eks.cluster_endpoint_private_access, true)
  cluster_endpoint_public_access        = try(local.usw2[each.key].eks.cluster_endpoint_public_access, true)
  cluster_additional_security_group_ids = [module.sg-usw2[each.key].consul_server_securitygroup_id]
  vpc_id                                = module.vpc-usw2[each.key].vpc_id
  subnet_ids                            = module.vpc-usw2[each.key].private_subnets
  cluster_addons = {
    #coredns = {
    #  resolve_conflicts = "OVERWRITE"
    #}
    kube-proxy = {}
    vpc-cni = {
      resolve_conflicts = "OVERWRITE"
    }
  }
  create_kms_key = true
  eks_managed_node_group_defaults = {
    ami_type       = "AL2_x86_64"
    disk_size      = 50
    instance_types = ["t3.medium"]
  }
  eks_managed_node_groups = {
    # Default node group - as provided by AWS EKS
    default_node_group = {
      # By default, the module creates a launch template to ensure tags are propagated to instances, etc.,
      # so we need to disable it to use the default template provided by the AWS EKS managed node group service
      use_custom_launch_template = false
      #launch_template_name   = "default"

      # Remote access cannot be specified with a launch template
      remote_access = {
        ec2_ssh_key               = var.ec2_key_pair_name
        source_security_group_ids = [module.sg-usw2[each.key].consul_server_securitygroup_id]
      }
    }
  }
}

module "hcp_consul_ec2_client-usw2" {
  providers = {
    aws = aws.usw2
  }
  source   = "../modules/hcp_consul_ec2_client"
  for_each = local.ec2_map_usw2

  hostname                    = local.ec2_map_usw2[each.key].hostname
  ec2_key_pair_name           = local.ec2_map_usw2[each.key].ec2_ssh_key
  region                      = local.usw2[each.value.vpc_env].region
  vpc_id                      = module.vpc-usw2[each.value.vpc_env].vpc_id
  prefix                      = var.prefix
  associate_public_ip_address = each.value.associate_public_ip_address
  subnet_id                   = each.value.target_subnets == "public_subnets" ? module.vpc-usw2[each.value.vpc_env].public_subnets[0] : module.vpc-usw2[each.value.vpc_env].private_subnets[0]
  security_group_ids          = [module.sg-usw2[each.value.vpc_env].consul_server_securitygroup_id]
  consul_datacenter           = module.hcp_consul_usw2[local.hvn_list_usw2[0]].datacenter
  consul_public_endpoint_url  = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_public_endpoint_url

  consul_ca_file              = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_ca_file
  consul_config_file          = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_config_file
  consul_root_token_secret_id = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_root_token_secret_id
}

module "sg-usw2" {
  providers = {
    aws = aws.usw2
  }
  source                = "../modules/aws_sg_consul_agents"
  for_each              = local.usw2
  region                = local.usw2[each.key].region
  security_group_create = true
  name_prefix           = "${local.usw2[each.key].name}-consul-sg"
  vpc_id                = module.vpc-usw2[each.key].vpc_id
  #vpc_cidr_block        = local.usw2[each.key].vpc.cidr
  vpc_cidr_blocks     = concat(local.all_routable_cidr_blocks_usw2, [local.usw2[local.hvn_list_usw2[0]].hcp-consul.cidr_block])
  private_cidr_blocks = local.all_routable_cidr_blocks_usw2
}

output "usw2_regions" {
  value = { for k, v in local.usw2 : k => local.usw2[k].region }
}
# VPC
output "usw2_vpc_ids" {
  value = { for env in sort(keys(local.usw2)) : env => module.vpc-usw2[env].vpc_id }
}

### EKS
output "usw2_eks_cluster_endpoints" {
  description = "Endpoint for your Kubernetes API server"
  value       = { for k, v in local.usw2 : k => module.eks-usw2[k].cluster_endpoint if contains(keys(v), "eks") }
}
output "usw2_eks_cluster_names" {
  description = "The name/id of the EKS cluster. Will block on cluster creation until the cluster is really ready"
  value       = { for k, v in local.usw2 : k => module.eks-usw2[k].cluster_name if contains(keys(v), "eks") }
}

### Transit Gateway
output "usw2_ec2_transit_gateway_arn" {
  description = "EC2 Transit Gateway Amazon Resource Name (ARN)"
  value       = { for k, v in local.usw2 : k => module.tgw-usw2[k].ec2_transit_gateway_arn if contains(keys(v), "tgw") }
}

output "usw2_ec2_transit_gateway_id" {
  description = "EC2 Transit Gateway identifier"
  value       = { for k, v in local.usw2 : k => module.tgw-usw2[k].ec2_transit_gateway_id if contains(keys(v), "tgw") }
}

output "usw2_default_hvn_routes" {
  description = "A list of every VPCs routable cidr blocks are added to HVN Route unless (hcp-consul.hvn_private_route_cidr_list) is defined"
  value       = [for hvn_route in local.all_routable_cidr_blocks_usw2 : hvn_route]
}
output "usw2_vpc-tgw-cidr_routes_added" {
  value = [for vpc_route in sort(keys(local.vpc_routes_map_usw2)) : vpc_route]
}
output "usw2_ec2_ip" {
  value = { for k, v in local.ec2_map_usw2 : k => module.hcp_consul_ec2_client-usw2[k].ec2_ip }
}
output "consul_config_file" {
  value = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_config_file
}