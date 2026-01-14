#!/bin/bash

# Script to inject multiple test emails with different Message-IDs
# Usage: ./inject-multiple-emails.sh [port] [count] [target_email]

JMAP_PORT=${1:-8080}
COUNT=${2:-3}
TARGET_EMAIL=${3:-}

BASE_URL="http://localhost:$JMAP_PORT"
AUTH="admin:admin"

echo "Injecting $COUNT test emails using JMAP (port $JMAP_PORT)"
echo "=========================================================="
echo ""

# Get JMAP session
SESSION_RESPONSE=$(curl -s -L -u "$AUTH" "$BASE_URL/.well-known/jmap")
ADMIN_ACCOUNT_ID=$(echo "$SESSION_RESPONSE" | jq -r '.primaryAccounts["urn:ietf:params:jmap:mail"] // (.accounts | keys[0]) // "d"')
PRINCIPALS_ACCOUNT_ID=$(echo "$SESSION_RESPONSE" | jq -r '.primaryAccounts["urn:ietf:params:jmap:principals"] // "c"')
API_URL=$(echo "$SESSION_RESPONSE" | jq -r '.apiUrl // empty')
UPLOAD_URL_TEMPLATE=$(echo "$SESSION_RESPONSE" | jq -r '.uploadUrl // empty')

# Fix hostname in URLs
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
        echo "Response: $(echo "$PRINCIPAL_RESPONSE" | jq '.')"
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

# Get Inbox ID
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
    INBOX_ID=$(echo "$MAILBOX_RESPONSE" | jq -r '.methodResponses[0][1].list[0].id')
fi

echo "Inbox ID: $INBOX_ID"
echo ""

# The target Message-ID we want to find (email #2)
TARGET_MESSAGE_ID="test-message-2@mail.gmail.com"

# Upload URL
if [ -n "$UPLOAD_URL_TEMPLATE" ]; then
    UPLOAD_URL="${UPLOAD_URL_TEMPLATE//\{accountId\}/$ACCOUNT_ID}"
else
    UPLOAD_URL="$BASE_URL/jmap/upload/$ACCOUNT_ID/"
fi

# Inject multiple emails
for i in $(seq 1 $COUNT); do
    echo "[$i/$COUNT] Creating email..."

    # Use consistent Message-ID pattern for all emails
    MESSAGE_ID="<test-message-$i@mail.gmail.com>"

    # Mark email 2 as the target
    if [ $i -eq 2 ]; then
        SUBJECT="Target Email - Should be Found by Query"
    else
        SUBJECT="Test Email #$i"
    fi

    EMAIL_CONTENT=$(cat <<EOF
From: Test User <test$i@example.com>
To: Admin <admin@localhost>
Subject: $SUBJECT
Message-ID: $MESSAGE_ID
Date: Mon, 13 Jan 2025 10:0$i:00 +0000
Content-Type: text/plain; charset="UTF-8"

This is test email number $i.
Message-ID: $MESSAGE_ID

This email is part of a multi-email test to reproduce the JMAP Email/query issue.
EOF
)

    # Upload blob
    BLOB_RESPONSE=$(curl -s -u "$AUTH" \
      -H "Content-Type: message/rfc822" \
      --data-binary "$EMAIL_CONTENT" \
      "$UPLOAD_URL")

    BLOB_ID=$(echo "$BLOB_RESPONSE" | jq -r '.blobId // empty' 2>/dev/null)

    if [ -z "$BLOB_ID" ]; then
        echo "  ✗ Blob upload failed for email $i"
        continue
    fi

    # Import email
    IMPORT_REQUEST=$(cat <<EOF
{
  "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
  "methodCalls": [
    [
      "Email/import",
      {
        "accountId": "$ACCOUNT_ID",
        "emails": {
          "email-$i": {
            "blobId": "$BLOB_ID",
            "mailboxIds": {
              "$INBOX_ID": true
            }
          }
        }
      },
      "import-$i"
    ]
  ]
}
EOF
)

    IMPORT_RESPONSE=$(curl -s -u "$AUTH" \
      -H "Content-Type: application/json" \
      -d "$IMPORT_REQUEST" \
      "$API_URL")

    EMAIL_ID=$(echo "$IMPORT_RESPONSE" | jq -r '.methodResponses[0][1].created."email-'$i'".id // empty' 2>/dev/null)

    if [ -n "$EMAIL_ID" ]; then
        echo "  ✓ Email $i imported successfully (ID: $EMAIL_ID, Message-ID: $MESSAGE_ID)"
    else
        echo "  ✗ Failed to import email $i"
        echo "$IMPORT_RESPONSE" | jq '.'
    fi
done

echo ""
echo "========================================="
echo "Injected $COUNT emails total"
echo "Email #2 has the target Message-ID: $TARGET_MESSAGE_ID"
echo ""
echo "Now run: ./test-jmap-query.sh $JMAP_PORT"
