terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# 리전: 하이데라바드(ap-south-2) -> 시드니(ap-southeast-2)로 변경
provider "aws" {
  region = "ap-southeast-2"

  # 태그 강제: 이 provider로 만드는 모든 리소스에 자동 적용
  # Name은 리소스마다 달라야 하므로 여기에 넣지 않고 각 리소스에서 지정
  default_tags {
    tags = {
      Owner   = var.owner_tag
      Project = var.project_tag
    }
  }
}

locals {
  # 리소스 Name 태그는 "${local.name_prefix}-<리소스명>" 형식 (예: <접두사>-mysql)
  name_prefix = var.name_prefix
}

# 내 이름·소속처럼 git 에 올리지 않을 값: terraform.tfvars 또는 TF_VAR_<이름> 환경변수로 넘김 (기본값 없음)
variable "name_prefix" {
  description = "리소스 이름 접두사. 모든 리소스 Name 이 <접두사>-<리소스명> 이 됨"
  type        = string
}

variable "owner_tag" {
  description = "모든 리소스에 자동으로 붙는 Owner 태그 값"
  type        = string
}

variable "project_tag" {
  description = "모든 리소스에 자동으로 붙는 Project 태그 값"
  type        = string
}

# 상황에 따라 바꾸는 값: terraform.tfvars 또는 -var 로 덮어쓰기
variable "key_name" {
  description = "시드니 리전에 이미 만들어 둔 키 페어 이름 (기본값 없음: terraform.tfvars 에 적음)"
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "SSH(22) 접속을 허용할 IP 대역. 예: [\"203.0.113.10/32\"] (기본값 없음: 직접 정해야 함)"
  type        = list(string)
}

variable "ingress_ports" {
  description = "모든 IP에 공개할 인바운드 TCP 포트 (SSH 는 ssh_allowed_cidrs 로 따로 제한)"
  type        = list(number)
  default     = [8000]
}

variable "instances" {
  description = "만들 인스턴스 목록. 키가 Name 태그(<접두사>-<키>)가 됨"
  type = map(object({
    instance_type = optional(string, "t3.micro")
    volume_size   = optional(number, 8)
  }))
  default = {
    app = {}
  }
}

# 보안 그룹 1개에 인바운드 규칙을 모아서 사용 (기본 VPC에 생성)
resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-sg"
  description = "${local.name_prefix}-sg"

  ingress {
    description = "SSH from allowed IPs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
  }

  dynamic "ingress" {
    for_each = var.ingress_ports
    content {
      description = "tcp ${ingress.value}"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "Allow all outbound (package install, image pull)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-sg"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_instance" "this" {
  for_each = var.instances

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = each.value.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.app.id]

  # IMDSv2 필수 (SSRF 로 인스턴스 자격 증명이 탈취되는 것을 방지)
  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = each.value.volume_size
    encrypted   = true
  }

  tags = {
    Name = "${local.name_prefix}-${each.key}"
  }
}

output "public_ips" {
  value = { for k, i in aws_instance.this : k => i.public_ip }
}
