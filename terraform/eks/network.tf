# EKS 전용 VPC: 퍼블릭 서브넷(ALB) + 프라이빗 서브넷(노드) 3개 AZ, NAT 인스턴스 1대
# 기존 <접두사>-vpc(10.0.0.0/24)와 CIDR 이 겹치지 않도록 10.20.0.0/16 사용

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_prefix}-eks-vpc"
  cidr = "10.20.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  public_subnets  = ["10.20.0.0/24", "10.20.1.0/24", "10.20.2.0/24"]
  private_subnets = ["10.20.10.0/24", "10.20.11.0/24", "10.20.12.0/24"]

  # NAT 게이트웨이는 쓰지 않고 아래 NAT 인스턴스를 사용
  # single_nat_gateway 는 프라이빗 라우트 테이블을 1개만 만들기 위해 true 로 둠 (게이트웨이는 생성되지 않음)
  enable_nat_gateway   = false
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # ALB 가 퍼블릭/프라이빗 서브넷을 구분하는 태그
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# S3 게이트웨이 엔드포인트: 프라이빗 서브넷에서 S3 로 갈 때 NAT 를 거치지 않음 (무료)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name = "${local.name_prefix}-s3-endpoint"
  }
}

# ---------------------------------------------------------------
# NAT 인스턴스: 프라이빗 서브넷의 노드가 인터넷(이미지 pull 등)으로 나갈 때 거치는 EC2
# ---------------------------------------------------------------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-x86_64"]
  }
}

resource "aws_security_group" "nat" {
  name        = "${local.name_prefix}-nat-sg"
  description = "NAT instance"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "All traffic from inside the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-nat-sg"
  }
}

resource "aws_instance" "nat" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.nat.id]
  associate_public_ip_address = true

  # NAT 인스턴스는 자기 주소가 아닌 트래픽도 전달해야 하므로 필수
  source_dest_check = false

  # IP 포워딩 + 마스커레이드. SSH 는 열지 않음(접속 불필요)
  user_data                   = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dnf install -y iptables-services
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-nat.conf
    sysctl --system
    IFACE=$(ip route show default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -o "$IFACE" -s ${module.vpc.vpc_cidr_block} -j MASQUERADE
    service iptables save
    systemctl enable --now iptables
  EOT
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 8
    encrypted   = true
  }

  tags = {
    Name = "${local.name_prefix}-nat"
  }
}

# 프라이빗 서브넷의 기본 경로(0.0.0.0/0)를 NAT 인스턴스로 보냄
resource "aws_route" "private_nat_instance" {
  route_table_id         = module.vpc.private_route_table_ids[0]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}
