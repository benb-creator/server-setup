#!/bin/sh
# Sets up all services on one server in one go, with Ansible.
#   ./setup.sh DOMAIN [USER@]SERVER [DNS-PROVIDER-TYPE KEY=VALUE ...]
# Examples:
#   ./setup.sh example.com root@203.0.113.10                              # zone file only, you enter DNS yourself
#   ./setup.sh example.com root@203.0.113.10 CLOUDFLAREAPI apitoken=abc123
#   ./setup.sh example.com admin@server1 HETZNER_V2 api_token=abc123
# Provider types and keys: https://docs.dnscontrol.org/provider/index . Without arguments: reuse inventory.yml.
set -e
cd "$(dirname "$0")"

if [ $# -ge 2 ]; then
  domain=$1; server=${2#*@}; user=root
  case $2 in *@*) user=${2%%@*} ;; esac
  {
    echo "office:"
    echo "  hosts:"
    echo "    server1: {ansible_host: \"$server\", ansible_user: \"$user\"}"
    echo "  vars:"
    echo "    domain: \"$domain\""
    if [ -n "$3" ]; then
      echo "    dns_provider:"
      echo "      TYPE: \"$3\""
      shift 3
      for pair in "$@"; do echo "      ${pair%%=*}: \"${pair#*=}\""; done
    fi
  } > inventory.yml
  echo "Wrote inventory.yml"
elif [ ! -f inventory.yml ]; then
  sed -n '2,8p' "$0"; exit 1
fi

command -v ansible-playbook >/dev/null || { echo "Please install Ansible: pipx install ansible-core (or apt/brew install ansible)"; exit 1; }
ansible-playbook site.yml
