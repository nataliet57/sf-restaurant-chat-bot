terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

provider "aws" {
  access_key                  = "test"
  secret_key                  = "test"
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    apigateway     = "http://localhost:4566"
    cloudwatch     = "http://localhost:4566"
    dynamodb       = "http://localhost:4566"
    ec2            = "http://localhost:4566"
    es             = "http://localhost:4566"
    iam            = "http://localhost:4566"
    kinesis        = "http://localhost:4566"
    lambda         = "http://localhost:4566"
    opensearch     = "http://localhost:4566"
    route53        = "http://localhost:4566"
    s3             = "http://localhost:4566"
    sns            = "http://localhost:4566"
    sqs            = "http://localhost:4566"
    sts            = "http://localhost:4566"
  }
}

locals {
  opensearch_domain_name = "sf-restaurant-opensearch"
  proxy_instance_name    = "sf-restaurant-opensearch-proxy"
  proxy_ami_id           = "ami-12345678"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "sf-restaurant-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "sf-restaurant-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "sf-restaurant-public-rt"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"

  tags = {
    Name = "sf-restaurant-public-subnet"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "sf-restaurant-private-subnet"
  }
}

resource "aws_security_group" "proxy" {
  name        = "sf-restaurant-proxy-sg"
  description = "Allow HTTP/HTTPS access to the proxy"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sf-restaurant-proxy-sg"
  }
}

resource "aws_security_group" "opensearch" {
  name        = "sf-restaurant-opensearch-sg"
  description = "Allow HTTPS access to OpenSearch"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from the internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    security_groups = [aws_security_group.proxy.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sf-restaurant-opensearch-sg"
  }
}

resource "aws_opensearch_domain" "main" {
  domain_name    = local.opensearch_domain_name
  engine_version = "OpenSearch_2.3"

  cluster_config {
    instance_type          = "t3.small.search"
    instance_count         = 1
    zone_awareness_enabled = false
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = 10
  }

  vpc_options {
    subnet_ids         = [aws_subnet.public.id]
    security_group_ids = [aws_security_group.opensearch.id]
  }

  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = {
        AWS = format("arn:aws:iam::%s:root", data.aws_caller_identity.current.account_id)
      }
      Action   = "es:*"
      Resource = format("arn:aws:es:%s:%s:domain/%s/*", data.aws_region.current.name, data.aws_caller_identity.current.account_id, local.opensearch_domain_name)
    }]
  })

  tags = {
    Name = "sf-restaurant-opensearch"
  }
}

resource "aws_instance" "proxy" {
  ami                         = local.proxy_ami_id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.proxy.id]
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = <<-EOF
              #!/bin/bash
              set -e
              yum update -y
              amazon-linux-extras install nginx1 -y || yum install -y nginx
              cat <<NGINX > /etc/nginx/conf.d/opensearch.conf
              map \$http_upgrade \$connection_upgrade {
                default upgrade;
                ''      close;
              }

              server {
                listen 80;
                server_name _;

                location / {
                  proxy_pass https://${aws_opensearch_domain.main.endpoint};
                  proxy_set_header Host ${aws_opensearch_domain.main.endpoint};
                  proxy_ssl_verify off;
                  proxy_http_version 1.1;
                  proxy_set_header Connection \$connection_upgrade;
                  proxy_set_header Upgrade \$http_upgrade;
                }
              }
              NGINX

              systemctl enable nginx
              systemctl restart nginx
              EOF

  tags = {
    Name = local.proxy_instance_name
  }
}

output "opensearch_endpoint" {
  description = "Public endpoint for the OpenSearch domain"
  value       = aws_opensearch_domain.main.endpoint
}

output "opensearch_dashboard_endpoint" {
  description = "Kibana-compatible dashboard endpoint for the OpenSearch domain"
  value       = aws_opensearch_domain.main.dashboard_endpoint
}

output "opensearch_proxy_url" {
  description = "HTTP URL of the reverse proxy exposing the OpenSearch dashboard"
  value       = format("http://%s", aws_instance.proxy.public_dns)
}
