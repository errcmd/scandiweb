wget https://releases.hashicorp.com/terraform/1.0.9/terraform_1.0.9_linux_amd64.zip
unzip terraform_1.0.9_linux_amd64.zip
chmod +x terraform
mv terraform /usr/bin/
#~/.aws/credentials file exist and have proper values - assumption
#bucket for state exist - assumption
terraform init
terraform workspace new dev
pip3 install boto3
#ansible [core 2.11.5] is installed via pip under user (not root) - assumption
ansible-galaxy install -r requirements.yml
ansible-playbook main.yml -e envir=dev
