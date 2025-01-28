# Learning Ansible for Cybersecurity

Welcome to your first hands-on experience with Ansible in cybersecurity! This project will help you understand how to automate Windows domain environment setup using Ansible, a crucial skill for modern cybersecurity professionals.

## What is Ansible?

Ansible is an open-source automation tool that can help you:
- Configure systems
- Deploy software
- Orchestrate complex security tasks
- Ensure consistent security configurations across your infrastructure

In cybersecurity, Ansible is particularly valuable because it allows you to:
- Rapidly deploy and configure secure environments
- Maintain consistent security baselines
- Automate security patches and updates
- Document your infrastructure as code

## Project Overview

This project sets up a Windows domain environment, which is a common infrastructure setup you'll encounter in enterprise environments. The automation includes:

- Setting up a Domain Controller
- Joining member computers to the domain
- Creating and configuring user accounts
- Installing and configuring software (Chrome in this example)

## Project Structure

```
.
├── site.yml                 # Main playbook - The entry point
├── dc_setup.yml            # Domain Controller configuration
├── member_setup.yml        # Domain member configuration
├── inventory/
│   └── hosts              # Defines target Windows machines
├── group_vars/
│   └── all.yml            # Shared variables across playbooks
└── provision.sh           # Environment provisioning script
```

## Prerequisites

Before you begin, ensure you have:

1. **Ansible Control Node Requirements:**
   - Ansible installed (latest version recommended)
   - ansible.windows collection installed
   ```bash
   ansible-galaxy collection install ansible.windows
   ```

2. **Target Windows Systems:**
   - Windows Server (for Domain Controller)
   - Windows clients (for domain members)
   - WinRM (Windows Remote Management) configured
   - Network connectivity between all systems

3. **Basic Knowledge:**
   - Understanding of Active Directory concepts
   - Basic Windows Server administration
   - Basic networking concepts (DNS, DHCP)

## Getting Started

1. **Clone this repository:**
   ```bash
   git clone <repository-url>
   cd windowsansible
   ```

2. **Review and modify the inventory file:**
   - Open `inventory/hosts`
   - Replace example hostnames with your actual server hostnames/IPs
   ```ini
   [domain_controllers]
   dc01.example.local    # Replace with your DC hostname

   [domain_members]
   client01.example.local    # Replace with your client hostname
   ```

3. **Configure variables:**
   - Open `group_vars/all.yml`
   - Modify domain settings and credentials
   ```yaml
   domain_name: example.local
   domain_netbios_name: EXAMPLE
   domain_admin_password: P@ssw0rd123!    # Change this!
   ```

4. **Run the playbook:**
   ```bash
   ansible-playbook -i inventory/hosts site.yml
   ```

## Security Considerations

As a cybersecurity student, pay attention to these security aspects:

1. **Credential Management:**
   - NEVER store passwords in plain text in production
   - Use Ansible Vault to encrypt sensitive data:
     ```bash
     ansible-vault encrypt group_vars/all.yml
     ```

2. **WinRM Security:**
   - The inventory uses NTLM authentication
   - In production, consider using Kerberos authentication
   - Always use HTTPS for WinRM in production

3. **Least Privilege:**
   - Review the permissions granted to created users
   - Understand the security implications of domain admin rights

## Learning Objectives

By working with this project, you'll learn:

1. **Infrastructure as Code (IaC):**
   - How to define infrastructure in version-controlled code
   - Benefits of reproducible environments
   - Documentation through code

2. **Windows Security:**
   - Active Directory configuration
   - Domain security policies
   - User and group management

3. **Automation Security:**
   - Secure credential management
   - Automated security configurations
   - Consistent security baselines

## Best Practices

1. **Version Control:**
   - Always commit your changes
   - Document changes in commit messages
   - Don't commit sensitive data

2. **Testing:**
   - Test playbooks in a lab environment first
   - Use `--check` mode to preview changes:
     ```bash
     ansible-playbook -i inventory/hosts site.yml --check
     ```

3. **Documentation:**
   - Comment your code
   - Update README when making changes
   - Document security decisions

## Troubleshooting

Common issues you might encounter:

1. **WinRM Connectivity:**
   ```powershell
   # On Windows target, check WinRM configuration:
   winrm get winrm/config/Service
   ```

2. **Authentication Issues:**
   - Verify credentials in group_vars/all.yml
   - Check domain connectivity
   - Ensure DNS resolution is working

3. **Playbook Failures:**
   - Read error messages carefully
   - Check Windows Event Logs
   - Use `-vvv` for verbose output:
     ```bash
     ansible-playbook -i inventory/hosts site.yml -vvv
     ```

## Next Steps

After mastering this basic setup:

1. Explore more complex security configurations
2. Learn to integrate with security tools
3. Practice creating custom security-focused playbooks
4. Study Ansible Tower/AWX for enterprise automation

## Resources

- [Ansible Documentation](https://docs.ansible.com/)
- [Windows Remote Management](https://docs.microsoft.com/en-us/windows/win32/winrm/portal)
- [Active Directory Security Best Practices](https://docs.microsoft.com/en-us/windows-server/identity/ad-ds/plan/security-best-practices/best-practices-for-securing-active-directory)

Remember: The best way to learn is by doing. Don't be afraid to experiment in your lab environment, but always follow security best practices in production!
