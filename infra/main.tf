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
  proxy_ami_id           = "ami-123456"
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

  lifecycle {
    ignore_changes = [
      engine_version,
      cluster_config,
      ebs_options,
      vpc_options
    ]
  }

  tags = {
    Name = "sf-restaurant-opensearch"
  }
}

resource "aws_iam_role" "proxy" {
  name = "sf-restaurant-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Effect = "Allow"
      }
    ]
  })

  tags = {
    Name = "sf-restaurant-proxy-role"
  }
}

# IAM Instance Profile for the proxy instance
resource "aws_iam_instance_profile" "proxy" {
  name = "sf-restaurant-proxy-instance-profile"
  role = aws_iam_role.proxy.name

  tags = {
    Name = "sf-restaurant-proxy-instance-profile"
  }
}

# Attach basic Amazon SSM Manager policy for instance management (optional but useful)
resource "aws_iam_role_policy_attachment" "proxy_ssm" {
  role       = aws_iam_role.proxy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Custom policy for OpenSearch access if needed
resource "aws_iam_role_policy" "proxy_opensearch" {
  name = "proxy-opensearch-access"
  role = aws_iam_role.proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "es:*"
        ]
        Resource = [
          "${aws_opensearch_domain.main.arn}",
          "${aws_opensearch_domain.main.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_instance" "proxy" {
  ami                         = local.proxy_ami_id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.proxy.id]
  iam_instance_profile        = aws_iam_instance_profile.proxy.name
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
resource "aws_s3_bucket" "opensearch_artifacts" {
  bucket = format("%s-artifacts-%s", local.opensearch_domain_name, data.aws_caller_identity.current.account_id)

  tags = {
    Name = "sf-restaurant-opensearch-artifacts"
  }
}

# Install Python dependencies before creating ZIP
resource "null_resource" "install_dependencies" {
  triggers = {
    requirements = filemd5("${path.module}/src/requirements.txt")
    source_code  = filemd5("${path.module}/src/lambda_function.py")
    source_code  = filemd5("${path.module}/src/s3_to_opensearch_lambda.py")
  }

  provisioner "local-exec" {
    command = <<EOF
      cd ${path.module}/src
      pip install -r requirements.txt -t .
      cd ..
      zip -r lambda_with_deps.zip src/
    EOF
  }
}

# Update the archive_file to include dependencies
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_package"
  output_path = "${path.module}/lambda.zip"
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_exec" {
  name_prefix = "osm_lambda_exec_role-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Effect = "Allow"
      }
    ]
  })
}

# Attach AWS managed policy for basic Lambda logging
resource "aws_iam_role_policy_attachment" "lambda_logging" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom inline policy to allow Lambda to upload to your S3 bucket
resource "aws_iam_role_policy" "lambda_s3_policy" {
  name_prefix = "lambda-s3-upload-policy-"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ]
        Resource = [
          "${aws_s3_bucket.opensearch_artifacts.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_lambda_function" "osm_query" {
  function_name = "query-openstreetmap-lambda"
  runtime       = "python3.9"
  handler       = "lambda_function.lambda_handler"
  filename      = "${path.module}/lambda_with_deps.zip"
  role          = aws_iam_role.lambda_exec.arn
  timeout       = 300
  memory_size   = 512

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.opensearch_artifacts.bucket
    }
  }

  tags = {
    Name = "query-openstreetmap-lambda"
  }

  # ADD THIS CRITICAL BLOCK
  lifecycle {
    ignore_changes = [
      filename,
      last_modified,
      source_code_hash
    ]
  }
}

resource "aws_lambda_function" "s3_to_opensearch" {
  function_name = "s3-to-opensearch-loader"
  runtime       = "python3.9"
  handler       = "s3_to_opensearch_lambda.lambda_handler"
  filename      = "${path.module}/lambda_with_deps.zip"
  role          = aws_iam_role.lambda_exec.arn
  timeout       = 300
  memory_size   = 512

  environment {
    variables = {
      S3_BUCKET       = aws_s3_bucket.opensearch_artifacts.bucket
      OPENSEARCH_HOST = replace(aws_opensearch_domain.main.endpoint, "https://", "")
    }
  }

  tags = {
    Name = "s3-to-opensearch-loader"
  }
}

# S3 Event Notification to trigger the second Lambda
resource "aws_s3_bucket_notification" "opensearch_trigger" {
  bucket = aws_s3_bucket.opensearch_artifacts.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_to_opensearch.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# Allow S3 to invoke the second Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_to_opensearch.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.opensearch_artifacts.arn
}

# Enhanced IAM policy for both Lambdas
resource "aws_iam_role_policy" "lambda_opensearch_policy" {
  name_prefix = "lambda-opensearch-policy-"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.opensearch_artifacts.arn,
          "${aws_s3_bucket.opensearch_artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "es:*",  # OpenSearch permissions
          "opensearch:*"
        ]
        Resource = [
          "${aws_opensearch_domain.main.arn}",
          "${aws_opensearch_domain.main.arn}/*"
        ]
      }
    ]
  })
}