terraform {
  required_version = ">= 1.10.0" # S3 자체 잠금(use_lockfile)은 1.10 이상

  # 상태를 S3 에 저장: 로컬 파일과 달리 도중에 Terraform 이 비정상 종료해도 파일이 비워지지 않고,
  # 버전 관리가 켜져 있어 이전 상태로 되돌릴 수 있음. 버킷은 Terraform 밖에서 직접 만든 것이라
  # terraform destroy 로 지워지지 않음. backend 블록에는 변수를 쓸 수 없어서 버킷 이름은 git 에 올리지 않는
  # backend.hcl 로 넘김 (terraform init -backend-config=backend.hcl, 예시는 backend.hcl.example).
  backend "s3" {
    key          = "eks/terraform.tfstate"
    region       = "ap-southeast-2"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# 리전: 시드니(ap-southeast-2)
provider "aws" {
  region = "ap-southeast-2"

  # 태그 강제: 이 provider로 만드는 모든 리소스에 자동 적용
  default_tags {
    tags = {
      Owner   = var.owner_tag
      Project = var.project_tag
    }
  }
}

locals {
  name_prefix = var.name_prefix
}

# 내 이름·소속처럼 git 에 올리지 않을 값: terraform.tfvars 또는 TF_VAR_<이름> 환경변수로 넘김 (기본값 없음)
variable "name_prefix" {
  description = "리소스 이름 접두사. 모든 리소스 Name 이 <접두사>-<리소스명> 이 됨"
  type        = string
}

variable "owner_tag" {
  description = "모든 리소스에 자동으로 붙는 Owner 태그 값 (RDS 지표를 찾는 Alloy 설정에도 쓰임)"
  type        = string
}

variable "project_tag" {
  description = "모든 리소스에 자동으로 붙는 Project 태그 값"
  type        = string
}

# 상황에 따라 바꾸는 값: terraform.tfvars 또는 -var 로 덮어쓰기
variable "eks_api_allowed_cidrs" {
  description = "EKS API 엔드포인트 접속을 허용할 IP 대역. terraform/kubectl 을 실행하는 PC 의 IP 를 포함해야 함. 예: [\"203.0.113.10/32\"] (기본값 없음: 직접 정해야 함)"
  type        = list(string)
}

variable "enable_database" {
  description = "false 로 두면 RDS(인스턴스, 프록시, 로테이션)와 DB 초기화를 만들지 않음. 만들고 지우는 시간이 짧아지는 가벼운 모드. 이때 fastapi 는 DB 없이 뜨고 회원 API 는 500, 파일(S3) API 는 동작"
  type        = bool
  default     = true
}

variable "node_instance_types" {
  description = "워커 노드 인스턴스 타입"
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "node_desired_size" {
  type    = number
  default = 3
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name = "${local.name_prefix}-eks"

  # 노드는 프라이빗 서브넷에 배치
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # 노드가 부팅 중 인터넷(이미지·EKS API)에 나갈 수 있도록 NAT 경로가 먼저 만들어져야 함
  depends_on = [aws_route.private_nat_instance]

  # 내 PC에서 kubectl로 접속할 수 있도록 API 엔드포인트 공개 (허용한 IP 대역만)
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.eks_api_allowed_cidrs

  # 컨트롤 플레인 로그 전체 활성화 (CloudWatch)
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # 컨트롤 플레인 로그 보관 일수 (모듈 기본값은 90일)
  cloudwatch_log_group_retention_in_days = 7

  # terraform을 실행한 IAM 사용자/역할에 클러스터 관리자 권한 부여
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      name           = "${local.name_prefix}-nodes"
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }

  tags = {
    Name = "${local.name_prefix}-eks"
  }
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ap-southeast-2 --name ${module.eks.cluster_name}"
}
