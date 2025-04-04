variable "cluster_name" {
  description = "The name of the OpenShift cluster."
  type        = string
}

variable "infra_id" {
  description = "The infrastructure identifier for the cluster."
  type        = string
}

variable "region" {
  description = "VPC region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the cluster resources are deployed."
  type        = string
}

variable "masters_availability_zones" {
  description = "List of availability zones in which to create dedicated master subnets."
  type        = list(string)
}

variable "masters_subnet_cidrs" {
  description = "List of CIDR blocks for the dedicated master subnets. Must be the same length as masters_availability_zones."
  type        = list(string)
}

variable "bastion_subnet_cidr" {
  description = "CIDR for the bastion host"
  type        = string
}
