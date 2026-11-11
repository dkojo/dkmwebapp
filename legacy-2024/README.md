# application-code

#Setting up the Jenkins Server

#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Update packages and install required software
sudo dnf update -y

# Install Docker and add Jenkins user to the Docker group
sudo dnf install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker jenkins
docker --version

# Install MariaDB (MySQL)
sudo dnf install -y mariadb105

# Install Terraform
sudo dnf install -y unzip
sudo wget https://releases.hashicorp.com/terraform/1.3.7/terraform_1.3.7_linux_amd64.zip
sudo unzip terraform_1.3.7_linux_amd64.zip
sudo mv terraform /usr/local/bin
terraform -v

# Install Git
sudo dnf install -y git
git --version

# Install AWS CLI
sudo curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo unzip awscliv2.zip
sudo ./aws/install
aws --version

# Install Jenkins - Documentation: https://www.jenkins.io/doc/tutorials/tutorial-for-installing-jenkins-on-AWS/
sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
sudo dnf upgrade -y
sudo dnf install -y java-17-amazon-corretto
sudo dnf install -y jenkins
sudo systemctl start jenkins
sudo systemctl enable jenkins

# Add Jenkins to the Docker group
sudo usermod -aG docker jenkins

echo "Jenkins setup completed successfully."
