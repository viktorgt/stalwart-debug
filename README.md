# Stalwart JMAP Email/query Issue Reproduction

This repository contains a reproducible test case for a JMAP Email/query issue between Stalwart v0.14.1 and v0.15.3.

## Issue Description

When using the `Email/query` JMAP method with a header filter for `Message-ID`:
- **v0.14.1**: Returns expected results (email IDs)
- **v0.15.3**: Returns empty IDs array

## Quick Start

### 1. Start both Stalwart versions

```bash
docker-compose up -d
```

This will start:
- Stalwart v0.14.1 on port 8080 (JMAP)
- Stalwart v0.15.3 on port 8081 (JMAP)

### 2. Wait for containers to be ready

```bash
docker-compose logs -f
# Wait until you see the admin credentials logged, then Ctrl+C
```

### 3. (Optional) Create a test domain and user account

```bash
chmod +x setup-account.sh

# Setup on v0.14.1 (port 8080)
./setup-account.sh 8080

# Setup on v0.15.3 (port 8081)
./setup-account.sh 8081
```

This creates:
- Domain: `example.com`
- User: `alice@example.com` with password `supersecret`

### 4. Inject multiple test emails (required to reproduce the bug)

```bash
chmod +x inject-multiple-emails.sh compare-versions.sh

# Inject into alice@example.com account
./inject-multiple-emails.sh 8080 3 alice@example.com
./inject-multiple-emails.sh 8081 3 alice@example.com
```

### 5. Compare results 

`
./test-jmap-query.sh 8080 alice@example.com
./test-jmap-query.sh 8081 alice@example.com
`