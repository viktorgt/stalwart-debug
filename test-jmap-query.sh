#!/bin/bash

# JMAP Query Test Script for Stalwart
# Usage: ./test-jmap-query.sh [port] [target_email]

PORT=${1:-8080}
TARGET_EMAIL=${2:-}

BASE_URL="http://localhost:$PORT"
AUTH="admin:admin"

echo "Testing JMAP Email/query on port $PORT"
echo "======================================"
echo ""

# Get JMAP session
echo "Getting JMAP session..."
SESSION_RESPONSE=$(curl -s -L -u "$AUTH" "$BASE_URL/.well-known/jmap")
echo "$SESSION_RESPONSE" | jq '.'
echo ""

# Extract API URL and account ID
API_URL=$(echo "$SESSION_RESPONSE" | jq -r '.apiUrl // empty')
ADMIN_ACCOUNT_ID=$(echo "$SESSION_RESPONSE" | jq -r '.primaryAccounts["urn:ietf:params:jmap:mail"] // (.accounts | keys[0]) // "d"')
PRINCIPALS_ACCOUNT_ID=$(echo "$SESSION_RESPONSE" | jq -r '.primaryAccounts["urn:ietf:params:jmap:principals"] // "c"')

# Fix hostname in URL (containers use internal hostname, we need localhost)
if [ -n "$API_URL" ]; then
    API_URL=$(echo "$API_URL" | sed "s|http://[^/]*|$BASE_URL|")
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

echo "API URL: $API_URL"
echo "Account ID: $ACCOUNT_ID"
echo ""

# Step 2: Test Email/query with Message-ID header filter
echo "Testing Email/query with Message-ID header filter..."
QUERY_REQUEST=$(cat <<EOF
{
  "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
  "methodCalls": [
    [
      "Email/query",
      {
        "accountId": "$ACCOUNT_ID",
        "filter": {
          "operator": "AND",
          "conditions": [
            { "header": [ "Message-ID", "test-message-2@mail.gmail.com" ] }
          ]
        }
      },
      "f891cff9-835a-4611-b3d1-3b6faf35ad60"
    ]
  ]
}
EOF
)

echo "Request:"
echo "$QUERY_REQUEST" | jq '.'
echo ""

echo "Response:"
curl -s -u "$AUTH" \
  -H "Content-Type: application/json" \
  -d "$QUERY_REQUEST" \
  "$API_URL" | jq '.'
echo ""

# Step 3: Also test a simpler query to list all emails
echo "Testing Email/query to list all emails..."
SIMPLE_QUERY=$(cat <<EOF
{
  "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
  "methodCalls": [
    [
      "Email/query",
      {
        "accountId": "$ACCOUNT_ID"
      },
      "simple-query"
    ]
  ]
}
EOF
)

echo "Response:"
curl -s -u "$AUTH" \
  -H "Content-Type: application/json" \
  -d "$SIMPLE_QUERY" \
  "$API_URL" | jq '.'
