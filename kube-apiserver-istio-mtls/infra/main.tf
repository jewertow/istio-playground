terraform {
  required_providers {
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Deduce the Internet Gateway associated with the VPC.
data "aws_internet_gateway" "igw" {
  filter {
    name   = "attachment.vpc-id"
    values = [var.vpc_id]
  }
}

# Lookup the latest Amazon Linux 2 AMI.
data "aws_ami" "amazon_linux2" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["amazon"]
}

# Generate SSH key pair for bastion host.
resource "tls_private_key" "bastion" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Create an AWS key pair resource using the generated public key.
resource "aws_key_pair" "bastion" {
  key_name   = "${var.cluster_name}-bastion"
  public_key = tls_private_key.bastion.public_key_openssh
}

# Write the private key to a file (keys/bastion.pem) in the current directory.
resource "local_file" "bastion_private_key" {
  content  = tls_private_key.bastion.private_key_pem
  filename = "${path.cwd}/${var.cluster_name}/keys/bastion.pem"
  file_permission = "0600"
}

# Create a security group for the bastion host that allows SSH.
resource "aws_security_group" "bastion_sg" {
  name        = "${var.cluster_name}-bastion-sg"
  description = "Security group for bastion host allowing SSH access"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create a dedicated public subnet for the bastion host.
resource "aws_subnet" "bastion_subnet" {
  vpc_id                  = var.vpc_id
  cidr_block              = var.bastion_subnet_cidr
  availability_zone       = var.masters_availability_zones[0]
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.infra_id}-bastion-subnet"
    Cluster = var.cluster_name
  }
}

# Associate the bastion subnet with the IGW via a route table.
resource "aws_route_table" "bastion_rt" {
  vpc_id = var.vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = data.aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.infra_id}-bastion-rt"
  }
}

resource "aws_route_table_association" "bastion_rta" {
  subnet_id      = aws_subnet.bastion_subnet.id
  route_table_id = aws_route_table.bastion_rt.id
}

# Provision the bastion host instance using Amazon Linux 2 and t3.micro.
resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.amazon_linux2.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.bastion_subnet.id
  key_name               = aws_key_pair.bastion.key_name
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]

  tags = {
    Name    = "${var.cluster_name}-bastion"
    Cluster = var.cluster_name
    Infra   = var.infra_id
  }
}

# Create dedicated public subnets for master nodes
resource "aws_subnet" "masters_subnets" {
  count                   = length(var.masters_availability_zones)
  vpc_id                  = var.vpc_id
  cidr_block              = var.masters_subnet_cidrs[count.index]
  availability_zone       = var.masters_availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.infra_id}-subnet-masters-${var.masters_availability_zones[count.index]}"
    Cluster = var.cluster_name
  }
}

# Associate each master subnet with the IGW using a common route table.
resource "aws_route_table" "masters_rt" {
  vpc_id = var.vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = data.aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.infra_id}-masters-rt"
  }
}

resource "aws_route_table_association" "masters_rta" {
  count          = length(aws_subnet.masters_subnets)
  subnet_id      = aws_subnet.masters_subnets[count.index].id
  route_table_id = aws_route_table.masters_rt.id
}

# Reference the existing kube-apiserver security group provisioned by the installer.
data "aws_security_group" "apiserver_lb" {
  filter {
    name   = "group-name"
    values = ["${var.infra_id}-apiserver-lb"]
  }
}

# Revoke the public ingress rule for port 6443 (0.0.0.0/0) using a local-exec provisioner.
resource "null_resource" "remove_public_access" {
  triggers = {
    sg_id = data.aws_security_group.apiserver_lb.id
  }

  provisioner "local-exec" {
    command = "aws ec2 revoke-security-group-ingress --region ${var.region} --group-id ${data.aws_security_group.apiserver_lb.id} --protocol tcp --port 6443 --cidr 0.0.0.0/0"
  }
}

# Add a new rule to allow access on port 6443 from the bastion host's security group.
resource "aws_security_group_rule" "kube_api_allow_bastion" {
  depends_on = [null_resource.remove_public_access]

  type                     = "ingress"
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "tcp"
  security_group_id        = data.aws_security_group.apiserver_lb.id
  source_security_group_id = aws_security_group.bastion_sg.id
  description              = "Allow kube-apiserver access only from bastion host"
}
