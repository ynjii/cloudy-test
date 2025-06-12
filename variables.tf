variable "project_name" {
  type        = string
  description = "AWS 리소스 태그로 사용될 프로젝트 이름"
  default     = "shepherd_project"
}

variable "ec2_instance_type" {
  type        = string
  default     = "t2.micro"
  description = "EC2 인스턴스 타입"
}

variable "ec2_ami_id" {
  type        = string
  description = "EC2에서 사용할 AMI ID"
  default     = "ami-0891aeb92f786d7a2"
}

variable "rds_engine" {
  type        = string
  default     = "postgres"
  description = "RDS 데이터베이스 엔진"
}

variable "rds_instance_class" {
  type        = string
  default     = "db.t3.micro"
  description = "RDS 인스턴스 타입"
}

variable "rds_username" {
  type        = string
  description = "RDS 마스터 사용자 이름"
  default     = "admin"
}

variable "rds_password" {
  type        = string
  description = "RDS 마스터 비밀번호"
  sensitive   = true
}

variable "allowed_ip" {
  type        = string
  default     = "0.0.0.0/0"
  description = "접근 허용할 IP 범위"
}
