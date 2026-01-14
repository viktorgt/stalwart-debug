#!/bin/bash

# Script to inject a test email with specific Message-ID using JMAP
# Usage: ./inject-test-email.sh [port] [target_email]

JMAP_PORT=${1:-8080}
TARGET_EMAIL=${2:-}

BASE_URL="http://localhost:$JMAP_PORT"
AUTH="admin:admin"

echo "Injecting test email using JMAP (port $JMAP_PORT)"
echo "=================================================="
echo ""

# Get JMAP session to find account ID
echo "Getting JMAP session..."
SESSION_RESPONSE=$(curl -s -L -u "$AUTH" "$BASE_URL/.well-known/jmap")
ADMIN_ACCOUNT_ID=$(echo "$SESSION_RESPONSE" | jq -r '.primaryAccounts["urn:ietf:params:jmap:mail"] // (.accounts | keys[0]) // "d"')
PRINCIPALS_ACCOUNT_ID=$(echo "$SESSION_RESPONSE" | jq -r '.primaryAccounts["urn:ietf:params:jmap:principals"] // "c"')
API_URL=$(echo "$SESSION_RESPONSE" | jq -r '.apiUrl // empty')
UPLOAD_URL_TEMPLATE=$(echo "$SESSION_RESPONSE" | jq -r '.uploadUrl // empty')

# Fix hostname in URLs (containers use internal hostname, we need localhost)
if [ -n "$API_URL" ]; then
    API_URL=$(echo "$API_URL" | sed "s|http://[^/]*|$BASE_URL|")
fi

if [ -n "$UPLOAD_URL_TEMPLATE" ]; then
    UPLOAD_URL_TEMPLATE=$(echo "$UPLOAD_URL_TEMPLATE" | sed "s|http://[^/]*|$BASE_URL|")
fi

if [ -z "$API_URL" ]; then
    API_URL="$BASE_URL/jmap"
fi

# Resolve account ID from email if provided
if [ -n "$TARGET_EMAIL" ]; then
    echo "Resolving account ID for: $TARGET_EMAIL"

    PRINCIPAL_QUERY=$(cat <<EOF
{
  "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:principals"],
  "methodCalls": [
    [
      "Principal/query",
      {
        "accountId": "$PRINCIPALS_ACCOUNT_ID",
        "filter": {
          "email": "$TARGET_EMAIL"
        },
        "limit": 1
      },
      "q1"
    ],
    [
      "Principal/get",
      {
        "accountId": "$PRINCIPALS_ACCOUNT_ID",
        "#ids": {
          "resultOf": "q1",
          "name": "Principal/query",
          "path": "/ids"
        }
      },
      "g1"
    ]
  ]
}
EOF
)

    PRINCIPAL_RESPONSE=$(curl -s -u "$AUTH" \
      -H "Content-Type: application/json" \
      -d "$PRINCIPAL_QUERY" \
      "$API_URL")

    ACCOUNT_ID=$(echo "$PRINCIPAL_RESPONSE" | jq -r '.methodResponses[1][1].list[0].id // empty')

    if [ -z "$ACCOUNT_ID" ]; then
        echo "✗ Failed to resolve account ID for $TARGET_EMAIL"
        exit 1
    fi

    echo "Target account: $TARGET_EMAIL"
else
    ACCOUNT_ID="$ADMIN_ACCOUNT_ID"
    echo "Target account: admin (default)"
fi

echo "Account ID: $ACCOUNT_ID"
echo "API URL: $API_URL"
echo ""

# Create the raw email content (base64 encoded for JMAP import)
EMAIL_CONTENT=$(cat <<'EOF'
From: Test User <test@example.com>
To: Admin <admin@localhost>
Subject: Test Email for JMAP Query
Message-ID: <test-message-1@mail.gmail.com>
Date: Mon, 13 Jan 2025 10:00:00 +0000
Content-Type: text/plain; charset="UTF-8"

This is a test email to reproduce the JMAP Email/query issue.
The Message-ID header is set to: test-message-1@mail.gmail.com

This email should be findable using the Email/query filter with header conditions.
EOF
)

# Base64 encode the email (remove line breaks for proper JSON)
EMAIL_BASE64=$(echo "$EMAIL_CONTENT" | base64 -w 0)

echo "Getting Inbox mailbox ID..."
MAILBOX_REQUEST=$(cat <<EOF
{
  "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
  "methodCalls": [
    [
      "Mailbox/get",
      {
        "accountId": "$ACCOUNT_ID"
      },
      "mailbox-1"
    ]
  ]
}
EOF
)

MAILBOX_RESPONSE=$(curl -s -u "$AUTH" \
  -H "Content-Type: application/json" \
  -d "$MAILBOX_REQUEST" \
  "$API_URL")

INBOX_ID=$(echo "$MAILBOX_RESPONSE" | jq -r '.methodResponses[0][1].list[] | select(.name == "Inbox" or .role == "inbox") | .id' | head -1)

if [ -z "$INBOX_ID" ]; then
    echo "Warning: Could not find Inbox, using first mailbox..."
    INBOX_ID=$(echo "$MAILBOX_RESPONSE" | jq -r '.methodResponses[0][1].list[0].id')
fi

echo "Inbox ID: $INBOX_ID"
echo ""

echo "Uploading email content as blob..."

# Use the upload URL template and substitute the account ID
if [ -n "$UPLOAD_URL_TEMPLATE" ]; then
    UPLOAD_URL="${UPLOAD_URL_TEMPLATE//\{accountId\}/$ACCOUNT_ID}"
else
    UPLOAD_URL="$BASE_URL/jmap/upload/$ACCOUNT_ID/"
fi

echo "Upload URL: $UPLOAD_URL"

BLOB_RESPONSE=$(curl -s -u "$AUTH" \
  -H "Content-Type: message/rfc822" \
  --data-binary "$EMAIL_CONTENT" \
  "$UPLOAD_URL")

echo "Blob upload response:"
echo "$BLOB_RESPONSE" | jq '.' 2>/dev/null || echo "$BLOB_RESPONSE"
BLOB_ID=$(echo "$BLOB_RESPONSE" | jq -r '.blobId // empty' 2>/dev/null)

if [ -z "$BLOB_ID" ]; then
    echo "✗ Blob upload failed. Check the response above for errors."
    exit 1
fi

echo "Blob ID: $BLOB_ID"
echo ""

echo "Importing email via JMAP Email/import..."

# Use JMAP Email/import to add the email
IMPORT_REQUEST=$(cat <<EOF
{
  "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
  "methodCalls": [
    [
      "Email/import",
      {
        "accountId": "$ACCOUNT_ID",
        "emails": {
          "test-email-1": {
            "blobId": "$BLOB_ID",
            "mailboxIds": {
              "$INBOX_ID": true
            }
          }
        }
      },
      "import-1"
    ]
  ]
}
EOF
)

RESPONSE=$(curl -s -u "$AUTH" \
  -H "Content-Type: application/json" \
  -d "$IMPORT_REQUEST" \
  "$API_URL")

echo "$RESPONSE" | jq '.'
echo ""

# Check if import was successful
if echo "$RESPONSE" | jq -e '.methodResponses[0][0] == "Email/import"' > /dev/null; then
    if echo "$RESPONSE" | jq -e '.methodResponses[0][1].created."test-email-1"' > /dev/null; then
        echo "✓ Test email imported successfully!"
        EMAIL_ID=$(echo "$RESPONSE" | jq -r '.methodResponses[0][1].created."test-email-1".id')
        echo "Email ID: $EMAIL_ID"
    else
        echo "✗ Email import failed. Check the response above for errors."
        NOT_CREATED=$(echo "$RESPONSE" | jq '.methodResponses[0][1].notCreated')
        if [ "$NOT_CREATED" != "null" ]; then
            echo "Errors: $NOT_CREATED"
        fi
        exit 1
    fi
else
    echo "✗ Unexpected response. Check the output above."
    exit 1
fi

echo ""
echo "Now run: ./test-jmap-query.sh $JMAP_PORT"
