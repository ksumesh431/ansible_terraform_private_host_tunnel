terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.0.4"
    }
    ansible = {
      source  = "ansible/ansible"
      version = "1.3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      CreatedBy = "Terraform"
      Purpose   = "Debugging"
    }
  }
}

variable "vpc_id" {
  description = "The VPC ID where the instances will be created"
  type        = string
  default     = "vpc-098c80afd971a30c7"
}


variable "keypair_name" {
  description = "Name of the AWS key pair"
  type        = string
  default     = "kubeadm_demo"
}

resource "tls_private_key" "private_key" {
  algorithm = "RSA"
  rsa_bits  = 4096

  provisioner "local-exec" {
    command = <<EOT
      mkdir -p ./keys
      rm -f ./keys/private-key.pem
      echo '${tls_private_key.private_key.private_key_pem}' > ./keys/private-key.pem
      chmod 600 ./keys/private-key.pem
    EOT
  }
}

resource "aws_key_pair" "key_pair" {
  key_name   = var.keypair_name
  public_key = tls_private_key.private_key.public_key_openssh

  provisioner "local-exec" {
    command = <<EOT
      mkdir -p ./keys
      rm -f ./keys/pubkey.pem
      echo '${tls_private_key.private_key.public_key_pem}' > ./keys/pubkey.pem
      chmod 600 ./keys/pubkey.pem
    EOT
  }
}


data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  owners = ["099720109477"] # Canonical's AWS account ID
}

resource "aws_instance" "jumpbox" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.micro"
  key_name                    = aws_key_pair.key_pair.key_name
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.allow_ssh.id]

  tags = {
    Name = "Jumpbox"
  }
}

resource "aws_instance" "private_instance" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.micro"
  key_name                    = aws_key_pair.key_pair.key_name
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.allow_ssh.id]

  tags = {
    Name = "PrivateInstance"
  }
}

resource "aws_security_group" "allow_ssh" {
  vpc_id = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
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
    Name = "allow_ssh"
  }
}

resource "null_resource" "ansible_pre_task" {
  provisioner "local-exec" {
    command     = file("${path.module}/files/check_ansible.sh")
    interpreter = ["/bin/bash", "-c"]
  }
}


resource "null_resource" "add_known_hosts" {
  provisioner "local-exec" {
    command = <<EOT
      set -e
      sleep 30  # Wait for instances to be fully up
      for i in {1..10}; do
        ssh-keyscan -H ${aws_instance.jumpbox.public_ip} >> ~/.ssh/known_hosts && break || sleep 5
      done
      for i in {1..10}; do
        ssh-keyscan -H ${aws_instance.private_instance.public_ip} >> ~/.ssh/known_hosts && break || sleep 5
      done
    EOT
  }

  depends_on = [null_resource.ansible_pre_task, aws_instance.jumpbox, aws_instance.private_instance]
}

resource "ansible_host" "jumpbox" {
  depends_on = [aws_instance.jumpbox, null_resource.add_known_hosts]
  name       = "jumpbox"
  groups     = ["bastions"]
  variables = {
    ansible_user                 = "ubuntu"
    ansible_host                 = aws_instance.jumpbox.public_ip
    ansible_ssh_private_key_file = "./keys/private-key.pem"
    ansible_ssh_common_args      = "-o StrictHostKeyChecking=no"
  }
}

resource "ansible_host" "private_instance" {
  depends_on = [aws_instance.private_instance, null_resource.add_known_hosts]
  name       = "private_instance"
  groups     = ["private_hosts"]
  variables = {
    ansible_user                 = "ubuntu"
    ansible_host                 = aws_instance.private_instance.private_ip
    ansible_ssh_private_key_file = "./keys/private-key.pem"
    ansible_ssh_common_args      = "-o StrictHostKeyChecking=no -o ProxyCommand=\"ssh -W %h:%p -q -i ./keys/private-key.pem ubuntu@${aws_instance.jumpbox.public_ip}\""
  }
}

resource "null_resource" "run_ansible" {
  provisioner "local-exec" {
    command = <<EOT
      set -e
      sleep 30  # Wait for instances to be fully up
      ansible-playbook -i ./files/inventory.yml ./files/playbook.yml
    EOT
  }

  depends_on = [ansible_host.jumpbox, ansible_host.private_instance]
}