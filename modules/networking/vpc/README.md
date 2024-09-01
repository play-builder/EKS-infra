# VPC Module

This module creates a VPC with public and private subnets, Internet Gateway, NAT Gateways, and route tables.

## Usage

```hcl
module "vpc" {
  source = "../../modules/networking/vpc"

  name_prefix = "my-eks"
  vpc_cidr    = "10.0.0.0/16"

  tags = {
    Environment = "dev"
    ManagedBy   = "Terraform"
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| name_prefix | Prefix to be used for all resource names | `string` | n/a | yes |
| vpc_cidr | CIDR block for VPC | `string` | `"10.0.0.0/16"` | no |
| num_availability_zones | Number of availability zones to use | `number` | `2` | no |
| enable_nat_gateway | Should be true to provision NAT Gateways | `bool` | `true` | no |
| tags | A map of tags to assign to the resource | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| vpc_id | ID of the VPC |
| vpc_cidr_block | CIDR block of the VPC |
| public_subnet_ids | List of public subnet IDs |
| private_subnet_ids | List of private subnet IDs |
| nat_gateway_ids | List of NAT Gateway IDs |
| internet_gateway_id | ID of the Internet Gateway |

