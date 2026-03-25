# ScopeForge Triage

Generated: 2026-03-25T00:00:00Z
Program: demo

## Summary

- Scope items: 1
- Excluded assets: 0
- Hosts discovered: 1
- Live hosts: 1
- Live targets: 1
- URLs discovered: 1
- Interesting URLs: 1

## Top Interesting URLs

### [7] https://example.com/admin
- Host: example.com
- Status: 200
- Categories: Admin
- Reasons: Administrative surface
- Technologies: nginx
- Title: Admin

## Protected Endpoints

- [403] https://example.com/secret

## Suggested Manual Review

- Review auth, admin, API documentation, file upload, and debug surfaces first.
- Compare interesting URLs against program policy before deeper manual testing.
- Re-check exclusions if noisy environments such as staging or sandbox are still visible.

