terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region  = "us-east-2"
  profile = "cloudx"
}

locals {
  name                = "efs-testing"
  public_ipv4_address = trimspace(data.http.public_ipv4_address.response_body)

  tags = {
    Name = "efs-testing"
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "selected" {
  availability_zone = data.aws_availability_zones.available.names[0]
  vpc_id            = data.aws_vpc.default.id
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "http" "public_ipv4_address" {
  url    = "https://ipv4.icanhazip.com"
  method = "GET"
}

data "aws_ami_ids" "rhel" {
  owners = ["309956199498"]

  filter {
    name   = "name"
    values = ["RHEL-9*_HVM-*-x86_64-*-Access2-*"]
  }

  include_deprecated = false
  sort_ascending     = false
}

data "aws_ami_ids" "fedora" {
  owners = ["125523088429"]

  filter {
    name   = "name"
    values = ["Fedora-Cloud-Base-39-1.*.x86_64-hvm-*-*-*-*-*"]
  }

  include_deprecated = false
  sort_ascending     = false
}

resource "aws_key_pair" "my_key_pair" {
  key_name   = "${local.name}-key"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyoH6gU4lgEiSiwihyD0Rxk/o5xYIfA3stVDgOGM9N0"

  tags = local.tags
}

resource "aws_security_group" "efs_instance" {
  name        = "${local.name}-instance"
  description = "Allow all traffic to instance from local address"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Allow from local address"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["${local.public_ipv4_address}/32"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = local.tags
}

resource "aws_security_group" "efs_target" {
  name        = "${local.name}-efs"
  description = "Allow instance to mount EFS"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Allow from instance"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.efs_instance.id]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = local.tags
}

resource "aws_spot_instance_request" "efs_testing" {
  ami                            = data.aws_ami_ids.fedora.ids[0]
  spot_price                     = "1"
  instance_type                  = "t3a.small"
  key_name                       = aws_key_pair.my_key_pair.key_name
  vpc_security_group_ids         = [aws_security_group.efs_instance.id]
  availability_zone              = data.aws_availability_zones.available.names[0]
  subnet_id                      = data.aws_subnet.selected.id
  instance_interruption_behavior = "terminate"
  wait_for_fulfillment           = true

  user_data = <<-EOL
  #!/bin/bash -xe
  echo "max_parallel_downloads=20" >> /etc/dnf/dnf.conf
  echo "fastestmirror=True" >> /etc/dnf/dnf.conf
  dnf -y upgrade
  dnf -y install dnf-plugins-core vim
  dnf -y copr enable mhayden/efs-utils 
  dnf -y install efs-utils
  EOL

  tags = local.tags
}

output "public_ip" {
  value = local.public_ipv4_address
}

resource "aws_efs_file_system" "efs_testing" {
  availability_zone_name = data.aws_availability_zones.available.names[0]
  creation_token         = local.name
  encrypted              = true

  tags = local.tags
}

resource "aws_efs_mount_target" "efs_testing" {
  file_system_id  = aws_efs_file_system.efs_testing.id
  subnet_id       = data.aws_subnet.selected.id
  security_groups = [aws_security_group.efs_target.id]
}

output "efs_mount_target_dns_name" {
  value = aws_efs_mount_target.efs_testing.dns_name
}

output "instance_ipv4_address" {
  value = aws_spot_instance_request.efs_testing.public_ip
}
