# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.x     | Yes       |

## Reporting a Vulnerability

Please do not report security issues through public GitHub issues.

Use [private vulnerability reporting](../../security/advisories/new) on this repository, with a description of the issue and steps to reproduce. You will get a reply within 7 days. Once a fix is released, the issue will be disclosed in the release notes.

wsl-maint deletes files and shuts down WSL. A rule or guard that lets it delete something it should refuse (a protected path, a named Docker volume) counts as a security issue.
