wget https://releases.hashicorp.com/terraform/1.0.9/terraform_1.0.9_linux_amd64.zip
unzip terraform_1.0.9_linux_amd64.zip
chmod +x terraform
mv terraform /usr/bin/
#~/.aws/credentials file exist and have proper values - assumption
#bucket for state exist - assumption
terraform init
terraform workspace new dev
