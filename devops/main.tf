terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "remit-mortgage-terraform-state"
    key            = "devops/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "remit-mortgage-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

# ------------------------------------------------------------------------------
# VPC and Networking
# ------------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "remit-mortgage-vpc-${var.environment}"
    Environment = var.environment
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name        = "remit-mortgage-public-subnet-${count.index + 1}"
    Environment = var.environment
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name        = "remit-mortgage-private-subnet-${count.index + 1}"
    Environment = var.environment
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "remit-mortgage-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway for private subnets (needed by App Runner for outbound, optionally)
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}


# ------------------------------------------------------------------------------
# Security Groups
# ------------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "remit-mortgage-app-sg"
  description = "Security group for App Runner"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "remit-mortgage-db-sg"
  description = "Security group for PostgreSQL"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}

resource "aws_security_group" "redis" {
  name        = "remit-mortgage-redis-sg"
  description = "Security group for Redis"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}

# ------------------------------------------------------------------------------
# PostgreSQL Database (RDS)
# ------------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "remit-mortgage-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "postgres" {
  identifier             = "remit-mortgage-db-${var.environment}"
  engine                 = "postgres"
  engine_version         = "15"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  skip_final_snapshot    = true
}

# ------------------------------------------------------------------------------
# Redis Cache (ElastiCache)
# ------------------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "main" {
  name       = "remit-mortgage-redis-subnet-group"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "remit-mortgage-redis-${var.environment}"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.1"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]
}

# ------------------------------------------------------------------------------
# App Runner
# ------------------------------------------------------------------------------
resource "aws_apprunner_vpc_connector" "main" {
  vpc_connector_name = "remit-mortgage-vpc-connector"
  subnets            = aws_subnet.private[*].id
  security_groups    = [aws_security_group.app.id]
}

resource "aws_apprunner_service" "app" {
  service_name = "remit-mortgage-api-${var.environment}"

  source_configuration {
    image_repository {
      image_configuration {
        port = "8080"
        runtime_environment_variables = {
          DATABASE_URL                = "postgres://${var.db_username}:${var.db_password}@${aws_db_instance.postgres.endpoint}/${aws_db_instance.postgres.db_name}"
          REDIS_URL                   = "redis://${aws_elasticache_cluster.redis.cache_nodes[0].address}:6379"
          REDIS_CLUSTER_ENABLED       = "false"
          REDIS_CLUSTER_NODES         = "${aws_elasticache_cluster.redis.cache_nodes[0].address}:6379"
          OTEL_EXPORTER_OTLP_ENDPOINT = var.otel_exporter_otlp_endpoint
          OTEL_SERVICE_NAME           = "remitmortgage-backend"
          OTEL_TRACES_SAMPLER_RATIO   = var.otel_traces_sampler_ratio
        }
      }
      image_identifier      = var.app_image
      image_repository_type = "ECR_PUBLIC"
    }
  }

  network_configuration {
    egress_configuration {
      egress_type       = "VPC"
      vpc_connector_arn = aws_apprunner_vpc_connector.main.arn
    }
  }
}
