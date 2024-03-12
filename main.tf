terraform {
  cloud {
    organization = "flawedlogic"

    workspaces {
      name = "dnd-remote"
    }
  }
}

provider "aws" {
  region     = "us-east-1" # Choose the region closest to your on-premises server
  access_key = var.access_key
  secret_key = var.secret_key

  default_tags {
    tags = {
      dnd_accel_resource   = "true"
      managed_by_Terraform = "true"
    }
  }
}

### TODO Add proper "Name" tags to all appropriate resources 

#########################################
# Initinialize the AWS Enviroment       #
#########################################


#Retrieve the list of AZs in the current AWS region
data "aws_availability_zones" "available" {}
data "aws_region" "current" {}

#Define the VPC
resource "aws_vpc" "dnd" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

#Deploy the public subnets
resource "aws_subnet" "public_subnets" {
  for_each                = var.public_subnets
  vpc_id                  = aws_vpc.dnd.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value)
  availability_zone       = tolist(data.aws_availability_zones.available.names)[each.value]
  map_public_ip_on_launch = true
}

#Create route tables for public and private subnets
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.dnd.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id
  }
  tags = {
    Name      = "dnd_public_rtb"
    Terraform = "true"
  }
}

#Create route table associations
resource "aws_route_table_association" "public" {
  depends_on     = [aws_subnet.public_subnets]
  route_table_id = aws_route_table.public_route_table.id
  for_each       = aws_subnet.public_subnets
  subnet_id      = each.value.id
}

#Create Internet Gateway
resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.dnd.id
}

#Create an Application Load Balancer to route traffic from Global Accel to the EC2 instance
module "alb" {
  source = "terraform-aws-modules/alb/aws"

  name    = "dnd-alb"
  vpc_id  = aws_vpc.dnd.id
  subnets = [aws_subnet.public_subnets["public_subnet_1"].id, aws_subnet.public_subnets["public_subnet_2"].id]

  enable_deletion_protection = false

  # Security Groups for ALb
  security_group_ingress_rules = {
    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      description = "HTTP web traffic"
      cidr_ipv4   = "0.0.0.0/0"
    }
    all_https = {
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      description = "HTTPS web traffic"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "10.0.0.0/16"
    }
  }

  listeners = {
    ex-http = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "ex-target"
      }
    }
    ### TODO Redirect ALB HTTPS traffic back to HTTP
    #  ex-https = {
    #    port            = 443
    #    protocol        = "HTTPS"
    #    certificate_arn = "arn:aws:iam::123456789012:server-certificate/test_cert-123456789012"

    #    forward = {
    #      target_group_key = "ex-instance"
    #    }
  }

  target_groups = {
    ex-target = {
      name_prefix = "pref-"
      protocol    = "HTTP"
      port        = 80
      target_type = "instance"
      target_id   = aws_instance.ubuntu_server.id
    }
  }

}

#Create the Global Accel and route it to the ALB
module "global_accelerator" {
  source = "terraform-aws-modules/global-accelerator/aws"

  name = "dnd-accelerator"

  listeners = {
    listener_1 = {

      endpoint_group = {
        health_check_port             = 80
        health_check_protocol         = "HTTP"
        health_check_path             = "/"
        health_check_interval_seconds = 10
        health_check_timeout_seconds  = 5
        healthy_threshold_count       = 2
        unhealthy_threshold_count     = 2
        traffic_dial_percentage       = 100

        endpoint_configuration = [{
          endpoint_id = module.alb.arn
          weight      = 100
        }]
      }

      port_ranges = [
        {
          from_port = 80
          to_port   = 80
      }]
      protocol = "TCP"
    }
  }
}

#########################################
# Set up nginx proxy EC2 instance below #
#########################################

#Create a temp SSH key for provising the server
resource "tls_private_key" "generated" {
  algorithm = "RSA"
}

resource "aws_key_pair" "generated" {
  key_name   = "dnd_key"
  public_key = tls_private_key.generated.public_key_openssh
}

#Define security groups for access to the EC2 instance
### TODO Tighten permissions, currently allows direct access the instance bypassing the Global Accel
resource "aws_security_group" "ingress-ssh" {
  name   = "allow-all-ssh"
  vpc_id = aws_vpc.dnd.id
  ingress {
    cidr_blocks = [
      "0.0.0.0/0" ## Fix
    ]
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "dnd-web-traffic-sg" {
  name        = "dnd-web-traffic-sg"
  vpc_id      = aws_vpc.dnd.id
  description = "Web Traffic"
  ingress {
    description = "Allow Port 80"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] ## Fix
  }

  #   ingress {
  #     description = "Allow Port 443"
  #     from_port   = 443
  #     to_port     = 443
  #     protocol    = "tcp"
  #     cidr_blocks = ["0.0.0.0/0"]
  #   }

  egress {
    description = "Allow all ip and ports outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#Lookup Latest Ubuntu 20.04 AMI Image
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"]
}

#Build EC2 instance in Public Subnet
resource "aws_instance" "ubuntu_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.public_subnets["public_subnet_1"].id
  vpc_security_group_ids      = [aws_security_group.ingress-ssh.id, aws_security_group.dnd-web-traffic-sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.generated.key_name
  connection {
    user        = "ubuntu"
    private_key = tls_private_key.generated.private_key_pem
    host        = self.public_ip
  }

  ### TODO Download and configure nginx -- create a Bash script (place in GitHub repo) to config nginx and use TF vars for the IP and port in args
  provisioner "remote-exec" {
    inline = [
      "sudo rm -rf /tmp",
      "sudo git clone https://github.com/hashicorp/demo-terraform-101 /tmp",
      "sudo sh /tmp/assets/setup-web.sh",
    ]
  }

  tags = {
    Name = "DnD ngnix Proxy Server"
  }

  lifecycle {
    ignore_changes = [security_groups]
  }


}

# Add DNS record for Accelerator IPs
module "records" {
  source  = "terraform-aws-modules/route53/aws//modules/records"
  version = "~> 2.0"

  zone_name = var.zone_name

  records = [
    {
      name = "dnd"
      type = "A"
      ttl  = 360
      records = [
        module.global_accelerator.ip_sets[0].ip_addresses[0],
        module.global_accelerator.ip_sets[0].ip_addresses[1]
      ]
    },
  ]
}