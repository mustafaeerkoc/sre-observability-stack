all:
  hosts:
    sre_server:
      ansible_host: ${public_ip}
      ansible_user: ubuntu
      ansible_ssh_private_key_file: ${key_path}
      ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
