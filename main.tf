########################################################
# Terraform 설정 및 Provider
########################################################
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region = "ap-northeast-2"
}

########################################################
# Locals: VPC/서브넷 CIDR, RDS 스토리지 등 고정값
########################################################
locals {
  # VPC 및 서브넷 CIDR 블록 (필요 시 원하는 값으로 변경)
  vpc_cidr               = "10.0.0.0/16"
  public_subnet_cidrs    = ["10.0.1.0/24", "10.0.2.0/24"]
  private_rds_subnet_cidrs = ["10.0.5.0/24", "10.0.6.0/24"]

  # RDS 스토리지 (GB 단위)
  db_allocated_storage   = 20
}

########################################################
# 데이터 소스: 가용 영역 정보 (AZ)
########################################################
data "aws_availability_zones" "available" {
  state = "available"
}

########################################################
# 디렉토리(키 저장 폴더) 생성
########################################################
resource "null_resource" "create_keys_directory" {
  provisioner "local-exec" {
    command = "mkdir -p ${path.module}/keys"
  }
}

########################################################
# SSH 키 페어 생성
########################################################
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ssh_key.public_key_openssh
}

resource "local_file" "private_key" {
  content         = tls_private_key.ssh_key.private_key_pem
  filename        = "${path.module}/keys/${var.project_name}-key.pem"
  file_permission = "0600"
}

########################################################
# 네트워크 구성 (VPC, 서브넷, 라우팅 등)
########################################################
resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

### 퍼블릭 서브넷 (ALB, EC2 용)
resource "aws_subnet" "public" {
  count                   = length(local.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet-${count.index + 1}"
  }
}

### 프라이빗 RDS 서브넷
resource "aws_subnet" "private_rds" {
  count             = length(local.private_rds_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_rds_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-private-rds-subnet-${count.index + 1}"
  }
}

### 퍼블릭 라우팅 테이블
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

### 퍼블릭 서브넷과 라우팅 테이블 연결
resource "aws_route_table_association" "public" {
  count          = length(local.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

### 프라이빗 RDS 서브넷을 기본 라우팅 테이블에 연결
resource "aws_route_table_association" "private_rds" {
  count          = length(local.private_rds_subnet_cidrs)
  subnet_id      = aws_subnet.private_rds[count.index].id
  route_table_id = aws_vpc.main.default_route_table_id
}

########################################################
# 보안 그룹
########################################################
### ALB 보안 그룹
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  # HTTP(80) 허용 (Public)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP from anywhere"
  }

  # HTTPS(443) 허용 (Public)
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS from anywhere"
  }

  # 모든 아웃바운드 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

### 웹 서버 보안 그룹
resource "aws_security_group" "web_server" {
  name        = "${var.project_name}-web-server-sg"
  description = "Security group for web servers"
  vpc_id      = aws_vpc.main.id

  # ALB에서 오는 HTTP(80)만 허용
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Allow HTTP from ALB"
  }

  # SSH(22) 허용: allowed_ip 변수에서 받아온 IP 블록만
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ip]
    description = "Allow SSH from allowed IP range"
  }

  # 모든 아웃바운드 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${var.project_name}-web-server-sg-v2"
  }
}

### RDS 보안 그룹
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg-v2"
  description = "Security group for RDS instances"
  vpc_id      = aws_vpc.main.id

  # 웹 서버에서 오는 MySQL/MariaDB(3306)만 허용
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_server.id]
    description     = "Allow MySQL/MariaDB from web servers"
  }

  # 모든 아웃바운드 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${var.project_name}-rds-sg-v2"
  }
}

########################################################
# EC2 인스턴스 (AMI ID를 변수로 받아옴)
########################################################
resource "aws_instance" "web_server_1" {
  ami                    = var.ec2_ami_id
  instance_type          = var.ec2_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.web_server.id]
  key_name               = aws_key_pair.generated_key.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
    encrypted   = true
    tags = {
      Name = "${var.project_name}-web-server-1-volume"
    }
  }

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd
    systemctl start httpd
    systemctl enable httpd
    echo "<h1>Hello from Web Server 1</h1>" > /var/www/html/index.html
  EOF

  tags = {
    Name = "${var.project_name}-web-server-2"
  }
}

########################################################
# ALB (Application Load Balancer)
########################################################
resource "aws_lb" "main" {
  name                             = "${var.project_name}-alb-v2"
  internal                         = false
  load_balancer_type               = "application"
  security_groups                  = [aws_security_group.alb.id]
  subnets                          = [for subnet in aws_subnet.public : subnet.id]
  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.project_name}-alb-v2"
  }
}

resource "aws_lb_target_group" "main" {
  name     = "${var.project_name}-tg-v2"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-tg-v2"
  }
}

resource "aws_lb_target_group_attachment" "web_server_1" {
  target_group_arn = aws_lb_target_group.main.arn
  target_id        = aws_instance.web_server_1.id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

########################################################
# RDS (MySQL/MariaDB 등 엔진을 변수로 받음)
########################################################
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group-v2"
  subnet_ids = [for subnet in aws_subnet.private_rds : subnet.id]

  tags = {
    Name = "${var.project_name}-db-subnet-group-v2"
  }
}

resource "aws_db_instance" "main" {
  identifier              = "${var.project_name}-db-v2"
  engine                  = var.rds_engine
  engine_version          = "8.0.33"
  instance_class          = var.rds_instance_class
  allocated_storage       = local.db_allocated_storage
  max_allocated_storage   = 100
  db_name                    = "appdb"
  username                = var.rds_username
  password                = var.rds_password
  port                    = 3306
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  multi_az                = false
  publicly_accessible     = false
  skip_final_snapshot     = true
  backup_retention_period = 7
  backup_window           = "03:00-05:00"
  maintenance_window      = "Mon:00:00-Mon:03:00"

  tags = {
    Name = "${var.project_name}-db-v2"
  }
}

########################################################
# 출력값 (Outputs)
########################################################
output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.main.id
}

output "alb_dns_name" {
  description = "The DNS name of the ALB"
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  description = "The endpoint of the RDS instance"
  value       = aws_db_instance.main.endpoint
}

output "ssh_private_key_pem" {
  description = "The private key for SSH access to EC2 instances"
  value       = tls_private_key.ssh_key.private_key_pem
  sensitive   = true
}

output "web_instance_public_ip" {
  description = "The public IP address of the web instance"
  value       = aws_instance.web_server_1.public_ip
}
