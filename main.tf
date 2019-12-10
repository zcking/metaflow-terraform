
resource "aws_iam_role" "ecs_execution_role" {
  name               = "metaflow_ecs_execution_role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "ec2.amazonaws.com",
          "ecs.amazonaws.com",
          "ecs-tasks.amazonaws.com",
          "batch.amazonaws.com"
        ]
      }
    }
  ]
}
EOF
}

# Create IAM role for ECS instances
resource "aws_iam_role" "ecs_instance_role" {
  name = var.ecs_instance_role_name

  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
    {
        "Action": "sts:AssumeRole",
        "Effect": "Allow",
        "Principal": {
        "Service": "ec2.amazonaws.com"
        }
    }
    ]
}
EOF
}


resource "aws_iam_role_policy_attachment" "ecs_instance_role" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance_role" {
  name = var.ecs_instance_role_name
  role = aws_iam_role.ecs_instance_role.name
}

# Create a S3 bucket for storing metaflow data
# otherwise stored locally in .metaflow directory
resource "aws_s3_bucket" "metaflow" {
  bucket = var.bucket_name
  acl    = "private"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "allow-ecs-instance",
      "Effect": "Allow",
      "Principal": {
        "AWS": "${aws_iam_role.ecs_instance_role.arn}"
      },
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${var.bucket_name}",
        "arn:aws:s3:::${var.bucket_name}/*"
      ]
    },
    {
      "Sid": "allow-ecs-execution",
      "Effect": "Allow",
      "Principal": {
        "AWS": "${aws_iam_role.ecs_execution_role.arn}"
      },
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${var.bucket_name}",
        "arn:aws:s3:::${var.bucket_name}/*"
      ]
    },
    {
      "Sid": "allow-batch-service",
      "Effect": "Allow",
      "Principal": {
        "AWS": "${aws_iam_role.aws_batch_service_role.arn}"
      },
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${var.bucket_name}",
        "arn:aws:s3:::${var.bucket_name}/*"
      ]
    }
  ]
}
EOF

  tags = {
    Metaflow = "true"
  }
}

resource "aws_iam_role" "aws_batch_service_role" {
  name = var.batch_service_role_name

  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
    {
        "Action": "sts:AssumeRole",
        "Effect": "Allow",
        "Principal": {
          "Service": [
            "batch.amazonaws.com",
            "s3.amazonaws.com"
          ]
        }
    }
    ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "aws_batch_service_role" {
  role       = aws_iam_role.aws_batch_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

resource "aws_security_group" "metaflow_batch" {
  name       = var.batch_security_group_name
  vpc_id     = aws_vpc.metaflow.id
  depends_on = [aws_vpc.metaflow]

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}



# Create VPC for Batch jobs to run in
resource "aws_vpc" "metaflow" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "metaflow-vpc"
  }
}

resource "aws_internet_gateway" "metaflow" {
  vpc_id = aws_vpc.metaflow.id
}

# Create a public Subnet inside that VPC
resource "aws_subnet" "metaflow_batch" {
  vpc_id                  = aws_vpc.metaflow.id
  cidr_block              = "10.0.0.0/20"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1b"

  tags = {
    Name     = var.batch_subnet_name
    Metaflow = "true"
  }
}


resource "aws_subnet" "metaflow_ecs" {
  vpc_id                  = aws_vpc.metaflow.id
  cidr_block              = "10.0.16.0/20"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"

  tags = {
    Name     = var.ecs_subnet_name
    Metaflow = "true"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.metaflow.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.metaflow.id
  }

  tags = {
    Name     = "Public Subnet"
    Metaflow = "true"
  }
}

resource "aws_route_table_association" "us_east_1a_public" {
  subnet_id      = aws_subnet.metaflow_batch.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "us_east_1b_public" {
  subnet_id      = aws_subnet.metaflow_ecs.id
  route_table_id = aws_route_table.public.id
}

resource "aws_batch_compute_environment" "metaflow" {
  compute_environment_name = var.compute_env_name

  compute_resources {
    instance_role = aws_iam_instance_profile.ecs_instance_role.arn

    instance_type = [
      var.batch_instance_type,
    ]

    max_vcpus     = var.batch_max_cpu
    min_vcpus     = var.batch_min_cpu
    desired_vcpus = var.batch_min_cpu

    security_group_ids = [
      aws_security_group.metaflow_batch.id,
    ]

    subnets = [
      aws_subnet.metaflow_batch.id,
    ]

    type = "EC2"
  }

  service_role = aws_iam_role.aws_batch_service_role.arn
  type         = "MANAGED"
  depends_on   = [aws_iam_role_policy_attachment.aws_batch_service_role]
}

# Create the Batch Job Queue
resource "aws_batch_job_queue" "metaflow" {
  name                 = var.batch_queue_name
  state                = "ENABLED"
  priority             = 1
  compute_environments = [aws_batch_compute_environment.metaflow.arn]
}

# Setup Postgres RDS instance and ECS metaflow service
resource "aws_db_subnet_group" "pg_subnet_group" {
  name       = var.pg_subnet_group_name
  subnet_ids = [aws_subnet.metaflow_batch.id, aws_subnet.metaflow_ecs.id]

  tags = {
    Name     = var.pg_subnet_group_name
    Metaflow = "true"
  }
}

resource "aws_security_group" "metaflow_db" {
  name       = var.db_security_group_name
  vpc_id     = aws_vpc.metaflow.id
  depends_on = [aws_vpc.metaflow]

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.my_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "metaflow" {
  allocated_storage         = 20
  storage_type              = "gp2"
  engine                    = "postgres"
  instance_class            = var.db_instance_type
  identifier                = var.db_name
  name                      = "metaflow"
  username                  = var.db_username
  password                  = var.db_password
  db_subnet_group_name      = aws_db_subnet_group.pg_subnet_group.id
  max_allocated_storage     = 1000
  multi_az                  = true
  final_snapshot_identifier = "${var.db_name}-final-snapshot"
  vpc_security_group_ids    = [aws_security_group.metaflow_db.id]

  tags = {
    Name     = var.db_name
    Metaflow = "true"
  }
}

resource "aws_ecs_cluster" "metaflow_cluster" {
  name = var.ecs_cluster_name

  tags = {
    Name     = var.ecs_cluster_name
    Metaflow = "true"
  }
}

resource "aws_iam_role" "iam_s3_access_role" {
  name               = "metaflow_iam_role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "ec2.amazonaws.com",
          "ecs.amazonaws.com",
          "ecs-tasks.amazonaws.com",
          "batch.amazonaws.com",
          "s3.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  tags = {
    Metaflow = "true"
  }
}

resource "aws_iam_role_policy" "iam_s3_access_policy" {
  name = "metaflow_s3_access"
  role = aws_iam_role.iam_s3_access_role.name

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
        "Sid": "ListObjectsInBucket",
        "Effect": "Allow",
        "Action": ["s3:*"],
        "Resource": ["${aws_s3_bucket.metaflow.arn}", "${aws_s3_bucket.metaflow.arn}/*"]
    }
  ]
}
EOF
}

resource "aws_security_group" "metaflow_service" {
  name   = var.service_security_group_name
  vpc_id = aws_vpc.metaflow.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.my_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # all
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Metaflow = "true"
  }
}


resource "aws_iam_role_policy" "ecs_execution_policy" {
  name   = "metaflow_ecs_execution_policy"
  role   = aws_iam_role.ecs_execution_role.name
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "s3:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}


resource "aws_ecs_task_definition" "metaflow_service_task" {
  family = "metaflow_service"

  container_definitions = <<EOF
[
  {
    "name": "metaflow_service",
    "image": "netflixoss/metaflow_metadata_service",
    "essential": true,
    "portMappings": [
      {
        "containerPort": 8080,
        "hostPort": 8080
      }
    ],
    "environment": [
      {"name": "MF_METADATA_DB_HOST", "value": "${replace(aws_db_instance.metaflow.endpoint, ":5432", "")}"},
      {"name": "MF_METADATA_DB_NAME", "value": "metaflow"},
      {"name": "MF_METADATA_DB_PORT", "value": "5432"},
      {"name": "MF_METADATA_DB_PSWD", "value": "${var.db_password}"},
      {"name": "MF_METADATA_DB_USER", "value": "${var.db_username}"}
    ]
  }
]
EOF

  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE", "EC2"]
  task_role_arn            = aws_iam_role.iam_s3_access_role.arn
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  cpu                      = 512
  memory                   = 1024

  tags = {
    Metaflow = "true"
  }
}

resource "aws_ecs_service" "metaflow_service" {
  name            = "metaflow_service"
  cluster         = aws_ecs_cluster.metaflow_cluster.id
  task_definition = aws_ecs_task_definition.metaflow_service_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  depends_on      = [aws_iam_role.iam_s3_access_role]
  network_configuration {
    security_groups  = [aws_security_group.metaflow_service.id]
    assign_public_ip = true
    subnets          = [aws_subnet.metaflow_batch.id, aws_subnet.metaflow_ecs.id]
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}

