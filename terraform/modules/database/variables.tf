variable "vpc_id" {
  description = "VPC ID"
  type        = string
  default     = ""
}

variable "region" {
  description = "REGION"
  type        = string
  default     = ""
}

variable "mysql_sg_id" {
  description = "MySQL Security Group"
  type        = string
  default     = ""
}

variable "azs" {
  description = "Network CIDR"
  type        = list(string)
  default     = []
}


variable "tag_header" {
  description = "Resource Name or Tag:Name Header"
  type        = string
  default     = ""
}

variable "owner" {
  description = "Resource Owner Name"
  type        = string
  default     = ""
}

variable "database" {
  description = "Resource Database Name"
  type        = string
  default     = ""
}

variable "user_name" {
  description = "Resource MySQL User Name"
  type        = string
  default     = ""
}

variable "app_user_name" {
  description = "앱 전용 MySQL 사용자 이름 (마스터 계정 대신 앱이 사용)"
  type        = string
  default     = ""
}

variable "db_subnet_ids" {
  description = "DB 서브넷 그룹과 RDS Proxy 가 사용할 프라이빗 서브넷 ID 목록"
  type        = list(string)
  default     = []
}
